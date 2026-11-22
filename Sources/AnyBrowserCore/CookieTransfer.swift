import Foundation

/// A cookie as AnyBrowser moves it; `expires` is nil for session cookies.
struct BrowserCookie: Equatable {
    enum SameSite: String {
        case strict = "Strict", lax = "Lax", none = "None"

        /// The value chrome.cookies, and so Cookie-Editor and EditThisCookie, use.
        var extensionValue: String {
            switch self {
            case .strict: return "strict"
            case .lax: return "lax"
            case .none: return "no_restriction"
            }
        }
    }

    /// The top-level site a partitioned (CHIPS) cookie belongs to.
    struct PartitionKey: Hashable {
        var topLevelSite: String
        var hasCrossSiteAncestor: Bool
    }

    /// What the browser keys a cookie by: setting one with the same key replaces it.
    struct Key: Hashable {
        var name: String
        var domain: String
        var path: String
        var partitionKey: PartitionKey?
    }

    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Double?
    var httpOnly: Bool
    var secure: Bool
    var sameSite: SameSite?
    var partitionKey: PartitionKey? = nil

    var key: Key { Key(name: name, domain: domain, path: path, partitionKey: partitionKey) }
}

/// Moves cookies between a running Profile and files through its browser-level DevTools endpoint.
public enum CookieTransfer {
    /// The JSON written by an export. Imports read either, and more.
    public enum Format: String, CaseIterable, Sendable {
        /// What Cookie-Editor and EditThisCookie export and import: `expirationDate`, `hostOnly`,
        /// `session` and chrome.cookies' lowercase `sameSite` values.
        case cookieEditor
        /// What DevTools, Puppeteer and Playwright use: `expires` (-1 for a session cookie) and
        /// capitalized `sameSite` values.
        case devTools
    }

    public struct Export: Sendable {
        public var data: Data
        public var count: Int
        /// Cookies the browser holds that cannot be moved, such as ones partitioned by an opaque origin.
        public var skipped: Int

        public var summary: String {
            "已导出 \(count) 条 Cookie。" + (skipped > 0 ? "另有 \(skipped) 条分区 Cookie 无法迁移，未导出。" : "")
        }
    }

    public struct ImportResult: Equatable, Sendable {
        /// Cookies from the file the browser kept.
        public var imported: Int
        /// Entries that could not be read, that the browser refused, or that a later entry with the
        /// same name, domain and path replaced.
        public var skipped: Int
        /// Cookies the browser accepted and then dropped to stay within its per-site and overall limits.
        public var evicted: Int
        /// Cookies the Profile had before the import that the browser dropped for the same reason.
        public var displaced: Int

        public init(imported: Int, skipped: Int, evicted: Int = 0, displaced: Int = 0) {
            self.imported = imported
            self.skipped = skipped
            self.evicted = evicted
            self.displaced = displaced
        }

        public var summary: String {
            var text = "已导入 \(imported) 条 Cookie，跳过 \(skipped) 条。"
            if evicted > 0 { text += "另有 \(evicted) 条超出浏览器的 Cookie 数量上限，未能保留。" }
            if displaced > 0 { text += "原有的 \(displaced) 条 Cookie 因数量上限被浏览器清除。" }
            return text
        }
    }

    static let maximumFileSize = 32 << 20
    /// Storage.setCookies rejects a whole batch over one malformed cookie, which is then retried one by one.
    static let batchSize = 100

    /// Every cookie of the Profile, partitioned ones included.
    public static func exportCookies(from endpoint: URL, format: Format = .cookieEditor) async throws -> Export {
        let client = try DevToolsClient(endpoint: endpoint)
        defer { client.close() }
        let items = try await browserCookies(client)
        let cookies = decode(items, now: Date()).cookies
        return Export(data: encode(cookies, as: format), count: cookies.count, skipped: items.count - cookies.count)
    }

    /// Adds the file's cookies to the Profile; existing cookies stay, and ones with the same name, domain,
    /// path and partition are replaced. Entries that can't be read or that the browser refuses count as
    /// skipped. Afterwards the Profile's cookies are read back: Chromium keeps at most 180 per site and
    /// about 3,300 in all, and silently drops the least recently used beyond that.
    /// When the connection fails part way, the error says how many cookies were already set.
    public static func importCookies(_ data: Data, into endpoint: URL) async throws -> ImportResult {
        let file = try decode(data, now: Date())
        // The browser would end up with the last of several entries for one cookie.
        var latest: [BrowserCookie.Key: Int] = [:]
        for (index, cookie) in file.cookies.enumerated() { latest[cookie.key] = index }
        let cookies = file.cookies.enumerated().filter { latest[$0.element.key] == $0.offset }.map(\.element)
        let replaced = file.cookies.count - cookies.count
        guard !cookies.isEmpty else { return ImportResult(imported: 0, skipped: file.skipped) }

        let client = try DevToolsClient(endpoint: endpoint)
        defer { client.close() }
        let before = Set(decode(try await browserCookies(client), now: Date()).cookies.map(\.key))
        var stored: [BrowserCookie.Key] = []
        var refused = 0
        do {
            for start in stride(from: 0, to: cookies.count, by: batchSize) {
                let batch = Array(cookies[start..<min(start + batchSize, cookies.count)])
                do {
                    _ = try await client.send("Storage.setCookies", ["cookies": batch.map(parameters)])
                    stored += batch.map(\.key)
                } catch is DevToolsCommandError {
                    for cookie in batch {
                        do {
                            _ = try await client.send("Storage.setCookies", ["cookies": [parameters(cookie)]])
                            stored.append(cookie.key)
                        } catch is DevToolsCommandError {
                            refused += 1
                        }
                    }
                }
            }
        } catch where !stored.isEmpty {
            // Earlier batches are already in the Profile, so retrying the whole file would set them again.
            throw ProfileError.invalid("导入中断：已导入 \(stored.count) 条 Cookie，其余未导入。\(error.localizedDescription)")
        }

        let after: Set<BrowserCookie.Key>
        do {
            after = Set(decode(try await browserCookies(client), now: Date()).cookies.map(\.key))
        } catch {
            throw ProfileError.invalid("已导入 \(stored.count) 条 Cookie，但无法确认浏览器实际保留了多少。\(error.localizedDescription)")
        }
        // Totals before and after can't be compared: imported cookies replace existing ones.
        let kept = KeyIndex(after)
        let evicted = stored.filter { !kept.contains(sent: $0) }.count
        let imported = KeyIndex(cookies.map(\.key))
        let displaced = before.subtracting(after).filter { !imported.contains(stored: $0) }.count
        return ImportResult(imported: stored.count - evicted, skipped: file.skipped + replaced + refused,
                            evicted: evicted, displaced: displaced)
    }

    /// Cookie keys looked up the way the browser matches them. Chromium keeps a partition by its site,
    /// the scheme and registrable domain, so one set for https://shop.example.com reads back as
    /// https://example.com: a partition matches the same site or one of its subdomains.
    struct KeyIndex {
        private var keys: [String: [BrowserCookie.Key]] = [:]

        init<Keys: Sequence>(_ keys: Keys) where Keys.Element == BrowserCookie.Key {
            for key in keys { self.keys[Self.slot(key), default: []].append(key) }
        }

        /// Whether a key held here could be what the browser made of `sent`.
        func contains(sent: BrowserCookie.Key) -> Bool {
            keys[Self.slot(sent)]?.contains { Self.matches(sent: sent, stored: $0) } == true
        }

        /// Whether a key held here, as sent, could have become `stored`.
        func contains(stored: BrowserCookie.Key) -> Bool {
            keys[Self.slot(stored)]?.contains { Self.matches(sent: $0, stored: stored) } == true
        }

        private static func slot(_ key: BrowserCookie.Key) -> String { "\(key.name)\u{0}\(key.domain)\u{0}\(key.path)" }

        static func matches(sent: BrowserCookie.Key, stored: BrowserCookie.Key) -> Bool {
            guard sent.name == stored.name, sent.domain == stored.domain, sent.path == stored.path else { return false }
            switch (sent.partitionKey, stored.partitionKey) {
            case (nil, nil):
                return true
            case let (sent?, stored?):
                guard sent.hasCrossSiteAncestor == stored.hasCrossSiteAncestor,
                      let from = URLComponents(string: sent.topLevelSite), let to = URLComponents(string: stored.topLevelSite),
                      from.scheme == to.scheme, let host = from.host?.lowercased(), let site = to.host?.lowercased() else { return false }
                return host == site || host.hasSuffix("." + site)
            default:
                return false
            }
        }
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

    private static func browserCookies(_ client: DevToolsClient) async throws -> [Any] {
        guard let items = try await client.send("Storage.getCookies")["cookies"] as? [Any] else {
            throw ProfileError.invalid("浏览器返回的 Cookie 数据无法识别。")
        }
        return items
    }

    /// Parses JSON arrays of cookies (AnyBrowser, DevTools, Cookie-Editor and EditThisCookie exports),
    /// objects holding them under `cookies` (Playwright storage state, J2Team), and Netscape cookies.txt.
    static func decode(_ data: Data, now: Date) throws -> (cookies: [BrowserCookie], skipped: Int) {
        let unrecognized = ProfileError.invalid(
            "无法识别 Cookie 文件，请选择 JSON 格式（Cookie-Editor、EditThisCookie、Playwright）或 Netscape cookies.txt 格式的导出。")
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let items = json as? [Any] { return decode(items, now: now) }
            if let items = (json as? [String: Any])?["cookies"] as? [Any] { return decode(items, now: now) }
            throw unrecognized
        }
        guard let text = String(data: data, encoding: .utf8), let items = netscapeItems(text) else { throw unrecognized }
        return decode(items, now: now)
    }

    static func decode(_ items: [Any], now: Date) -> (cookies: [BrowserCookie], skipped: Int) {
        let cookies = items.compactMap { ($0 as? [String: Any]).flatMap { cookie($0, now: now) } }
        return (cookies, items.count - cookies.count)
    }

    /// The lines of a Netscape cookies.txt (curl, wget, yt-dlp, Cookie-Editor) as JSON-style entries,
    /// or nil when the text is not one. Each line holds seven tab-separated fields: domain, whether
    /// subdomains match, path, secure, expiry (0 for a session cookie), name and value. A
    /// `#HttpOnly_` prefix marks an HttpOnly cookie; other lines starting with # are comments.
    /// A line with too few fields becomes an entry that fails to parse, so it counts as skipped.
    static func netscapeItems(_ text: String) -> [Any]? {
        var items: [Any] = []
        var recognized = text.hasPrefix("# Netscape HTTP Cookie File") || text.hasPrefix("# HTTP Cookie File")
        for raw in text.components(separatedBy: "\n") {
            var line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let httpOnly = line.hasPrefix("#HttpOnly_")
            if httpOnly {
                line.removeFirst("#HttpOnly_".count)
            } else if line.hasPrefix("#") {
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7, let expiry = Double(fields[4]),
                  ["TRUE", "FALSE"].contains(fields[1].uppercased()), ["TRUE", "FALSE"].contains(fields[3].uppercased()) else {
                items.append(line)
                continue
            }
            recognized = true
            items.append([
                "domain": fields[0], "hostOnly": fields[1].uppercased() == "FALSE", "path": fields[2],
                "secure": fields[3].uppercased() == "TRUE", "expirationDate": expiry, "name": fields[5],
                // A value may itself hold tabs.
                "value": fields[6...].joined(separator: "\t"), "httpOnly": httpOnly,
            ] as [String: Any])
        }
        return recognized ? items : nil
    }

    static func cookie(_ item: [String: Any], now: Date) -> BrowserCookie? {
        guard let name = item["name"] as? String, !name.isEmpty, var domain = item["domain"] as? String,
              let value = field(item, "value", or: ""), var path = field(item, "path", or: "/"),
              let httpOnly = field(item, "httpOnly", or: false), let secure = field(item, "secure", or: false),
              let session = field(item, "session", or: false), let sameSiteName = field(item, "sameSite", or: "unspecified"),
              let hostOnly = field(item, "hostOnly", or: Bool?.none),
              let expirationDate = field(item, "expirationDate", or: Double?.none),
              let cdpExpires = field(item, "expires", or: Double?.none),
              let partitionKey = partition(item["partitionKey"]),
              // A cookie partitioned by an opaque origin cannot be set again anywhere.
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
        // DevTools writes -1 and cookies.txt writes 0 for a session cookie; no real cookie expires in 1970.
        if !session, let date = expirationDate ?? cdpExpires, date > 0 {
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
        // Likewise for SameSite=None or a partition without Secure.
        guard sameSite != BrowserCookie.SameSite.none || secure, partitionKey == nil || secure else { return nil }
        return BrowserCookie(name: name, value: value, domain: domain, path: path, expires: expires,
                             httpOnly: httpOnly, secure: secure, sameSite: sameSite, partitionKey: partitionKey)
    }

    /// A `partitionKey` field: absent or null for an unpartitioned cookie, an object with
    /// `topLevelSite` (DevTools since Chrome 125, chrome.cookies) or just the site (older DevTools).
    /// The outer optional is nil when the field cannot be read.
    private static func partition(_ value: Any?) -> BrowserCookie.PartitionKey?? {
        let site: Any?
        var crossSite = false
        switch value {
        case nil, is NSNull:
            return .some(nil)
        case let text as String:
            site = text
        case let object as [String: Any]:
            site = object["topLevelSite"]
            switch object["hasCrossSiteAncestor"] {
            case nil, is NSNull: break
            case let flag as Bool: crossSite = flag
            default: return nil
            }
        default:
            return nil
        }
        // A scheme and a host, as Chromium serializes a site.
        guard let site = site as? String, let parts = URLComponents(string: site),
              ["https", "http"].contains(parts.scheme), let host = parts.host, !host.isEmpty,
              parts.path.isEmpty, parts.user == nil, parts.query == nil, parts.fragment == nil else { return nil }
        return .some(BrowserCookie.PartitionKey(topLevelSite: site, hasCrossSiteAncestor: crossSite))
    }

    /// A JSON array with a fixed field order, one cookie per object, sorted by site.
    static func encode(_ cookies: [BrowserCookie], as format: Format) -> Data {
        let site = { (cookie: BrowserCookie) in String(cookie.domain.drop { $0 == "." }) }
        let partition = { (cookie: BrowserCookie) in cookie.partitionKey?.topLevelSite ?? "" }
        let objects = cookies.sorted {
            (site($0), $0.domain, $0.path, $0.name, partition($0)) < (site($1), $1.domain, $1.path, $1.name, partition($1))
        }.map { cookie in
            let fields = format == .devTools ? devToolsFields(cookie) : extensionFields(cookie)
            return "  {\n" + fields.map { "    \"\($0.0)\": \($0.1)" }.joined(separator: ",\n") + "\n  }"
        }
        return Data((objects.isEmpty ? "[]\n" : "[\n" + objects.joined(separator: ",\n") + "\n]\n").utf8)
    }

    private static func devToolsFields(_ cookie: BrowserCookie) -> [(String, String)] {
        var fields = [
            ("name", quoted(cookie.name)), ("value", quoted(cookie.value)), ("domain", quoted(cookie.domain)),
            ("path", quoted(cookie.path)), ("expires", cookie.expires.map(seconds) ?? "-1"),
            ("httpOnly", String(cookie.httpOnly)), ("secure", String(cookie.secure)),
        ]
        if let sameSite = cookie.sameSite { fields.append(("sameSite", quoted(sameSite.rawValue))) }
        if let key = cookie.partitionKey { fields.append(("partitionKey", partitionObject(key))) }
        return fields
    }

    /// The fields of a chrome.cookies Cookie in the order Cookie-Editor writes them. `storeId` is null
    /// so the cookie goes to whichever store the importing browser uses.
    private static func extensionFields(_ cookie: BrowserCookie) -> [(String, String)] {
        var fields = [("domain", quoted(cookie.domain))]
        if let expires = cookie.expires { fields.append(("expirationDate", seconds(expires))) }
        fields += [("hostOnly", String(!cookie.domain.hasPrefix("."))), ("httpOnly", String(cookie.httpOnly)),
                   ("name", quoted(cookie.name))]
        if let key = cookie.partitionKey { fields.append(("partitionKey", partitionObject(key))) }
        fields += [
            ("path", quoted(cookie.path)), ("sameSite", quoted(cookie.sameSite?.extensionValue ?? "unspecified")),
            ("secure", String(cookie.secure)), ("session", String(cookie.expires == nil)), ("storeId", "null"),
            ("value", quoted(cookie.value)),
        ]
        return fields
    }

    private static func seconds(_ date: Double) -> String { String(format: "%.0f", date.rounded(.down)) }

    private static func partitionObject(_ key: BrowserCookie.PartitionKey) -> String {
        "{\"hasCrossSiteAncestor\": \(key.hasCrossSiteAncestor), \"topLevelSite\": \(quoted(key.topLevelSite))}"
    }

    /// The Storage.setCookies parameter for a cookie; without `expires` the browser keeps a session cookie.
    static func parameters(_ cookie: BrowserCookie) -> [String: Any] {
        var result: [String: Any] = ["name": cookie.name, "value": cookie.value, "domain": cookie.domain,
                                     "path": cookie.path, "httpOnly": cookie.httpOnly, "secure": cookie.secure]
        if let expires = cookie.expires { result["expires"] = expires }
        if let sameSite = cookie.sameSite { result["sameSite"] = sameSite.rawValue }
        if let key = cookie.partitionKey {
            result["partitionKey"] = ["topLevelSite": key.topLevelSite, "hasCrossSiteAncestor": key.hasCrossSiteAncestor]
        }
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
