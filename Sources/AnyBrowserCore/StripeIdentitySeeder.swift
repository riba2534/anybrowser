import Foundation

/// Plants this Profile's device id on the merchant hosts it is about to open.
///
/// Stripe's `__stripe_mid` lives on the merchant's own domain and is the client-side cache of the
/// server-side device. Without one, the first report carries `NA` and the server hands out a fresh
/// device only after the page has started loading; with one, the identity is settled before the
/// first request. The bare UUIDv4 is accepted and completed by the server with a checksum, so the
/// value written here is what later reports keep.
///
/// Runs after the debug endpoint is up and before the first navigation. Nothing is written when the
/// jar already holds an acceptable pair, so a restart stays the same device; `m.stripe.com`'s `m`
/// is deliberately not planted, the server issues it.
public enum StripeIdentitySeeder {
    public static let maximumHosts = 20
    private static let midLifetime: TimeInterval = 365 * 24 * 60 * 60
    private static let sidLifetime: TimeInterval = 30 * 60

    /// Start-page hosts, lowercased and deduplicated, HTTP(S) only, each with its scheme.
    static func targets(from startURLs: [String]) -> [(host: String, secure: Bool)] {
        var seen: Set<String> = []
        var result: [(host: String, secure: Bool)] = []
        for line in startURLs {
            guard let url = URL(string: line.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host?.lowercased(), !host.isEmpty else { continue }
            guard seen.insert(host).inserted else { continue }
            result.append((host, scheme == "https"))
            if result.count >= maximumHosts { break }
        }
        return result
    }

    /// Just the hosts, in the same order.
    public static func hosts(from startURLs: [String]) -> [String] {
        targets(from: startURLs).map(\.host)
    }

    /// An existing value is kept when its shape is one the server accepts: 36 characters, optionally
    /// followed by the 6-character checksum. Anything else would only make the client and the server
    /// disagree, and the client prefers whatever is in the jar.
    static func acceptable(_ value: String?) -> Bool {
        value.map(DeviceIdentity.isValid) ?? false
    }

    /// Seeds every host and returns warnings; failures never stop the launch.
    public static func seed(_ profile: BrowserProfile, startURLs: [String], client: DevToolsClient) async -> [String] {
        let targets = targets(from: startURLs)
        guard !targets.isEmpty else { return [] }
        let identity = DeviceIdentity.effective(profile)
        var warnings: [String] = []
        var cookies: [[String: Any]] = []
        do {
            cookies = try await client.send("Storage.getCookies")["cookies"] as? [[String: Any]] ?? []
        } catch {
            return ["未能读取 Cookie，设备标识等页面自己建立（\(error.localizedDescription)）。"]
        }
        let now = Date().timeIntervalSince1970
        var planned: [(host: String, secure: Bool, name: String, value: String, expires: TimeInterval)] = []
        for target in targets {
            let host = target.host
            let own = cookies.filter { cookie in
                (cookie["domain"] as? String)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host
            }
            let mid = own.first { $0["name"] as? String == "__stripe_mid" }?["value"] as? String
            let sid = own.first { $0["name"] as? String == "__stripe_sid" }?["value"] as? String
            if !acceptable(mid) {
                planned.append((host, target.secure, "__stripe_mid", identity, now + midLifetime))
            }
            if !acceptable(sid) {
                planned.append((host, target.secure, "__stripe_sid", DeviceIdentity.mint(), now + sidLifetime))
            }
        }
        guard !planned.isEmpty else { return [] }
        let parameters: [[String: Any]] = planned.map { item in
            // A leading dot makes it the merchant's whole domain; a bare IP takes no dot.
            let bare = item.host.range(of: #"^[0-9.]+$|^\[.*\]$"#, options: .regularExpression) != nil
            return [
                "name": item.name,
                "value": item.value,
                "domain": bare ? item.host : "." + item.host,
                "path": "/",
                "secure": item.secure,
                "httpOnly": false,
                "sameSite": "Strict",
                "expires": item.expires,
            ]
        }
        do {
            _ = try await client.send("Storage.setCookies", ["cookies": parameters])
        } catch {
            warnings.append("未能写入设备 Cookie（\(error.localizedDescription)），首访将等待服务端签发。")
            return warnings
        }
        // The browser only uses a planted cookie once it has been read back into the jar.
        do {
            let written = try await client.send("Storage.getCookies")["cookies"] as? [[String: Any]] ?? []
            for host in Set(planned.map(\.host)) where !written.contains(where: { cookie in
                (cookie["name"] as? String) == "__stripe_mid"
                    && (cookie["domain"] as? String)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host
            }) {
                warnings.append("设备 Cookie 未能在 \(host) 生效，首访将等待服务端签发。")
            }
        } catch {
            warnings.append("未能回读设备 Cookie（\(error.localizedDescription)）。")
        }
        return warnings
    }
}