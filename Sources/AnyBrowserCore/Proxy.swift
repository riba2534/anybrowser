import Darwin
import Foundation

/// A Profile's proxy, parsed from the address typed in the editor.
public struct ProxyEndpoint: Equatable, Sendable {
    /// http, https or socks5.
    public var scheme: String
    /// Lowercased host name, IPv4 address or bracketed IPv6 address.
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?

    public init(scheme: String, host: String, port: Int, username: String? = nil, password: String? = nil) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    /// The value of `--proxy-server`: never contains credentials.
    public var server: String { "\(scheme)://\(host):\(port)" }

    public var hasCredentials: Bool { username != nil }

    /// Parses `host:port` (HTTP) or `scheme://host:port`. An empty address means no proxy (nil).
    public static func parse(_ text: String) throws -> ProxyEndpoint? {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        let invalid = ProfileError.invalid("代理须为主机:端口，或使用 http://、https://、socks5://，无需填写用户名和密码。")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:/[]")
        guard address.utf8.count <= 512, address.unicodeScalars.allSatisfy(allowed.contains) else { throw invalid }

        let uri = address.contains("://") ? address : "http://\(address)"
        guard let parts = URLComponents(string: uri), let scheme = parts.scheme?.lowercased(),
              ["http", "https", "socks5"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              let port = parts.port, (1...65535).contains(port),
              parts.path.isEmpty || parts.path == "/" else { throw invalid }
        if host.hasPrefix("[") {
            var ip = in6_addr()
            let literal = String(host.dropFirst().dropLast())
            guard host.hasSuffix("]"), inet_pton(AF_INET6, literal, &ip) == 1 else { throw invalid }
        } else {
            let name = host.hasSuffix(".") ? String(host.dropLast()) : host
            guard name.utf8.count <= 253, name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-"
                    && !$0.contains(":") && !$0.contains("[") && !$0.contains("]")
            }), !name.isEmpty else { throw invalid }
        }
        return ProxyEndpoint(scheme: scheme, host: host, port: port)
    }
}

/// Where a Profile's traffic leaves for the internet, as reported by an IP lookup service.
public struct ProxyExit: Codable, Equatable, Sendable {
    public var ip: String
    /// ISO 3166-1 alpha-2, uppercased; empty when unknown.
    public var countryCode: String
    public var region: String
    public var city: String
    /// IANA time zone; empty when unknown.
    public var timeZone: String
    /// BCP 47 language tags, most common first; may be empty.
    public var languages: [String]

    public init(ip: String, countryCode: String = "", region: String = "", city: String = "",
                timeZone: String = "", languages: [String] = []) {
        self.ip = ip
        self.countryCode = countryCode
        self.region = region
        self.city = city
        self.timeZone = timeZone
        self.languages = languages
    }
}
