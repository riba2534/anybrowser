import Foundation

/// A cookie in AnyBrowser's export format; `expires` is nil for session cookies.
struct BrowserCookie: Equatable {
    enum SameSite: String {
        case strict = "Strict", lax = "Lax", none = "None"
    }

    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Double?
    var httpOnly: Bool
    var secure: Bool
    var sameSite: SameSite?
}

/// Moves cookies between a running Profile and JSON files through its browser-level DevTools endpoint.
public enum CookieTransfer {
    static let maximumFileSize = 32 << 20
    /// Storage.setCookies rejects a whole batch over one malformed cookie, which is then retried one by one.
    static let batchSize = 100

    /// Every unpartitioned cookie of the Profile, in the export format.
    public static func exportCookies(from endpoint: URL) async throws -> (data: Data, count: Int) {
        let client = try DevToolsClient(endpoint: endpoint)
        defer { client.close() }
        guard let items = try await client.send("Storage.getCookies")["cookies"] as? [Any] else {
            throw ProfileError.invalid("浏览器返回的 Cookie 数据无法识别。")
        }
        let cookies = decode(items, now: Date()).cookies
        return (encode(cookies), cookies.count)
    }

    /// Adds the file's cookies to the Profile; existing cookies stay, and ones with the same name, domain
    /// and path are replaced. Entries that can't be read or that the browser refuses count as skipped.
    /// When the connection fails part way, the error says how many cookies were already set.
    public static func importCookies(_ data: Data, into endpoint: URL) async throws -> (imported: Int, skipped: Int) {
        let file = try decode(data, now: Date())
        guard !file.cookies.isEmpty else { return (0, file.skipped) }
        let client = try DevToolsClient(endpoint: endpoint)
        defer { client.close() }
        var stored = 0
        var refused = 0
        do {
            for start in stride(from: 0, to: file.cookies.count, by: batchSize) {
                let batch = file.cookies[start..<min(start + batchSize, file.cookies.count)].map(parameters)
                do {
                    _ = try await client.send("Storage.setCookies", ["cookies": batch])
                    stored += batch.count
                } catch is DevToolsCommandError {
                    for cookie in batch {
                        do {
                            _ = try await client.send("Storage.setCookies", ["cookies": [cookie]])
                            stored += 1
                        } catch is DevToolsCommandError {
                            refused += 1
                        }
                    }
                }
            }
        } catch where stored > 0 {
            // Earlier batches are already in the Profile, so retrying the whole file would set them again.
            throw ProfileError.invalid("导入中断：已导入 \(stored) 条 Cookie，其余未导入。\(error.localizedDescription)")
        }
        return (stored, file.skipped + refused)
    }

    /// Writes an export that only the current user can read, replacing any existing file.
    public static func writeFile(_ data: Data, to url: URL) throws {
        try PrivateFile.write(data, to: url, failure: "无法写入 Cookie 文件，请换一个位置。")
    }

    /// Reads a cookie file, refusing anything but a regular file of reasonable size.
    public static func readFile(_ url: URL) throws -> Data {
        let data = try PrivateFile.read(url, limit: maximumFileSize, failure: "无法读取 Cookie 文件。",
                                        notAFile: "请选择一个 Cookie 文件。")
        guard data.count <= maximumFileSize else {
            throw ProfileError.invalid("Cookie 文件超过 32 MB，无法导入。")
        }
        return data
    }

    /// Parses AnyBrowser and CDP exports as well as Cookie-Editor and EditThisCookie exports.
    static func decode(_ data: Data, now: Date) throws -> (cookies: [BrowserCookie], skipped: Int) {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw ProfileError.invalid("无法识别 Cookie 文件，请选择 JSON 数组格式的导出。")
        }
        return decode(items, now: now)
    }

    static func decode(_ items: [Any], now: Date) -> (cookies: [BrowserCookie], skipped: Int) {
        let cookies = items.compactMap { ($0 as? [String: Any]).flatMap { cookie($0, now: now) } }
        return (cookies, items.count - cookies.count)
    }

    static func cookie(_ item: [String: Any], now: Date) -> BrowserCookie? {
        guard let name = item["name"] as? String, !name.isEmpty, var domain = item["domain"] as? String,
              let value = field(item, "value", or: ""), var path = field(item, "path", or: "/"),
              let httpOnly = field(item, "httpOnly", or: false), let secure = field(item, "secure", or: false),
              let session = field(item, "session", or: false), let sameSiteName = field(item, "sameSite", or: "unspecified"),
              let hostOnly = field(item, "hostOnly", or: Bool?.none),
              let expirationDate = field(item, "expirationDate", or: Double?.none),
              let cdpExpires = field(item, "expires", or: Double?.none),
              // The format has no partition key, and a partitioned cookie must not come back unpartitioned.
              item["partitionKey"] == nil || item["partitionKey"] is NSNull,
              field(item, "partitionKeyOpaque", or: false) == false else { return nil }

        // A domain with a leading dot also matches subdomains; one without is host-only.
        switch hostOnly {
        case true?: domain = String(domain.drop { $0 == "." })
        case false? where !domain.hasPrefix("."): domain = "." + domain
        default: break
        }
        guard domain.contains(where: { $0 != "." }) else { return nil }
        if path.isEmpty { path = "/" }

        var expires: Double?
        if !session, let date = expirationDate ?? cdpExpires, date >= 0 {
            // The browser accepts expired cookies without storing them, which would inflate the imported count.
            guard date.isFinite, date > now.timeIntervalSince1970 else { return nil }
            expires = date
        }

        let sameSite: BrowserCookie.SameSite?
        switch sameSiteName.lowercased() {
        case "unspecified": sameSite = nil
        case "strict": sameSite = .strict
        case "lax": sameSite = .lax
        case "none", "no_restriction": sameSite = BrowserCookie.SameSite.none
        default: return nil
        }
        // Likewise for SameSite=None without Secure.
        guard sameSite != BrowserCookie.SameSite.none || secure else { return nil }
        return BrowserCookie(name: name, value: value, domain: domain, path: path, expires: expires,
                             httpOnly: httpOnly, secure: secure, sameSite: sameSite)
    }

    /// A JSON array with a fixed field order, one cookie per object, sorted by site.
    static func encode(_ cookies: [BrowserCookie]) -> Data {
        let site = { (cookie: BrowserCookie) in String(cookie.domain.drop { $0 == "." }) }
        let objects = cookies.sorted {
            (site($0), $0.domain, $0.path, $0.name) < (site($1), $1.domain, $1.path, $1.name)
        }.map { cookie in
            var fields = [
                ("name", quoted(cookie.name)), ("value", quoted(cookie.value)), ("domain", quoted(cookie.domain)),
                ("path", quoted(cookie.path)), ("expires", cookie.expires.map { String(format: "%.0f", $0.rounded(.down)) } ?? "-1"),
                ("httpOnly", String(cookie.httpOnly)), ("secure", String(cookie.secure)),
            ]
            if let sameSite = cookie.sameSite { fields.append(("sameSite", quoted(sameSite.rawValue))) }
            return "  {\n" + fields.map { "    \"\($0.0)\": \($0.1)" }.joined(separator: ",\n") + "\n  }"
        }
        return Data((objects.isEmpty ? "[]\n" : "[\n" + objects.joined(separator: ",\n") + "\n]\n").utf8)
    }

    /// The Storage.setCookies parameter for a cookie; without `expires` the browser keeps a session cookie.
    static func parameters(_ cookie: BrowserCookie) -> [String: Any] {
        var result: [String: Any] = ["name": cookie.name, "value": cookie.value, "domain": cookie.domain,
                                     "path": cookie.path, "httpOnly": cookie.httpOnly, "secure": cookie.secure]
        if let expires = cookie.expires { result["expires"] = expires }
        if let sameSite = cookie.sameSite { result["sameSite"] = sameSite.rawValue }
        return result
    }

    /// An optional field: `fallback` when missing or null, nil when it holds another type.
    private static func field<T>(_ item: [String: Any], _ key: String, or fallback: T) -> T? {
        guard let value = item[key], !(value is NSNull) else { return fallback }
        return value as? T
    }

    private static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
