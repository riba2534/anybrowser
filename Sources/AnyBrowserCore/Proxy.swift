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

    /// Parses `host:port` (HTTP) or `scheme://host:port`, optionally with `user:password@` before the
    /// host for HTTP and HTTPS proxies. An empty address means no proxy (nil).
    public static func parse(_ text: String) throws -> ProxyEndpoint? {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        let invalid = ProfileError.invalid(
            "代理须为主机:端口，或以 http://、https://、socks5:// 开头；HTTP 和 HTTPS 代理可带账号密码，例如 http://用户名:密码@主机:端口。")
        guard address.utf8.count <= 512 else { throw invalid }

        let uri = address.contains("://") ? address : "http://\(address)"
        guard let separator = uri.range(of: "://") else { throw invalid }
        var authority = uri[separator.upperBound...]
        var credentials: (username: String, password: String)?
        // The last @ ends the credentials: an @ inside them has to be written as %40.
        if let at = authority.lastIndex(of: "@") {
            guard uri[..<separator.lowerBound].lowercased() != "socks5" else {
                throw ProfileError.invalid("内核不支持 SOCKS5 代理的账号密码，请改用 HTTP 代理，或去掉用户名和密码。")
            }
            credentials = try Self.credentials(authority[..<at])
            authority = authority[authority.index(after: at)...]
        }

        let location = "\(uri[..<separator.lowerBound])://\(authority)"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:/[]")
        guard location.unicodeScalars.allSatisfy(allowed.contains),
              let parts = URLComponents(string: location), let scheme = parts.scheme?.lowercased(),
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
        return ProxyEndpoint(scheme: scheme, host: host, port: port,
                             username: credentials?.username, password: credentials?.password)
    }

    /// `user:password`, each percent-decoded. Only unreserved characters, sub-delimiters and percent
    /// escapes may appear as typed (RFC 3986 userinfo).
    private static func credentials(_ userInfo: Substring) throws -> (username: String, password: String) {
        let typed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=:%")
        let parts = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, userInfo.unicodeScalars.allSatisfy(typed.contains),
              let username = parts[0].removingPercentEncoding, let password = parts[1].removingPercentEncoding,
              !username.isEmpty, !password.isEmpty,
              // HTTP Basic authentication ends the user name at the first colon.
              !username.contains(":"),
              !(username + password).unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProfileError.invalid(
                "代理的用户名和密码都不能为空，写成 http://用户名:密码@主机:端口；其中的 @、/、# 等特殊字符请用百分号编码，例如 @ 写成 %40。")
        }
        return (username, password)
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

    /// Matches a fingerprint's time zone and language to this exit, keeping what it does not know.
    public func apply(to fingerprint: inout FingerprintSettings) {
        if !timeZone.isEmpty { fingerprint.timeZone = timeZone }
        if let language = languages.first { fingerprint.language = language }
    }
}
