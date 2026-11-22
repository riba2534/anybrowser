import Darwin
import Foundation
import Network

/// Checks that a Profile's proxy accepts connections, and asks an IP lookup service where traffic
/// through it leaves for the internet.
public enum ProxyProbe {
    /// Tried in order until one answers: free lookups are limited per exit IP, and a shared exit
    /// often has used up one of them.
    public static let lookupServices = [
        URL(string: "https://ipinfo.io/json")!, URL(string: "https://ipapi.co/json/")!,
        URL(string: "https://ipwho.is/")!, URL(string: "https://get.geojs.io/v1/ip/geo.json")!,
    ]

    /// Headers any script could send, so the services learn nothing about this app or Mac: by default
    /// URLSession names the app and its version, the macOS build and the system languages.
    static let neutralHeaders = [
        "User-Agent": "curl/8.7.1", "Accept": "application/json", "Accept-Language": "en-US,en;q=0.9",
    ]

    /// Whether a TCP connection to the proxy itself opens. Nothing beyond the proxy is contacted.
    public static func reachable(_ endpoint: ProxyEndpoint, timeout: TimeInterval = 1.5) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: endpoint.port)) else { return false }
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(bare(endpoint.host)), port: port, using: parameters)
        let queue = DispatchQueue(label: "anybrowser.proxy.reachable")
        let once = Once()
        return await withCheckedContinuation { continuation in
            let finish = { (open: Bool) in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: open)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                // A refused or unroutable connection waits for the network to change; treat it as closed.
                case .waiting, .failed, .cancelled: finish(false)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
            connection.start(queue: queue)
        }
    }

    /// The warning shown when a Profile starts with a proxy that does not accept connections;
    /// nil when it does or when there is no proxy.
    public static func preflight(_ proxy: String, timeout: TimeInterval = 1.5) async -> String? {
        guard let endpoint = try? ProxyEndpoint.parse(proxy), await !reachable(endpoint, timeout: timeout) else {
            return nil
        }
        return "代理 \(endpoint.server) 无法连接，浏览器将无法联网。请确认代理已启动。"
    }

    /// Looks up the exit through `endpoint`, trying each service in turn. Without a proxy the request
    /// uses the system network settings, as the browser does.
    ///
    /// With a `maxAge`, an exit found through the same proxy address within that many seconds is
    /// returned without asking again, which spares the services' rate limits during a batch. A
    /// rotating proxy changes its exit between connections, so callers keep the age short.
    public static func lookupExit(through endpoint: ProxyEndpoint?, services: [URL] = ProxyProbe.lookupServices,
                                  timeout: TimeInterval = 8, maxAge: TimeInterval = 0,
                                  configuration: URLSessionConfiguration = .ephemeral) async throws -> ProxyExit {
        if maxAge > 0, let cached = cachedExit(for: endpoint, maxAge: maxAge) { return cached }
        let session = URLSession(configuration: try sessionConfiguration(configuration, through: endpoint, timeout: timeout))
        defer { session.finishTasksAndInvalidate() }
        var reasons: [String] = []
        for service in services {
            do {
                let exit = try await lookup(service, through: endpoint, in: session)
                exitCache.store(exit, for: endpoint)
                return exit
            } catch let failure as LookupFailure {
                if !reasons.contains(failure.reason) { reasons.append(failure.reason) }
            }
        }
        throw ProfileError.invalid("无法查询出口 IP：\(reasons.isEmpty ? "没有可用的查询服务" : reasons.joined(separator: "；"))。")
    }

    /// The exit the latest successful lookup through this proxy address found, when it is at most
    /// `maxAge` seconds old. Addresses are compared normalized, credentials included, since a
    /// provider can route each user name differently.
    public static func cachedExit(for endpoint: ProxyEndpoint?, maxAge: TimeInterval, now: Date = Date()) -> ProxyExit? {
        exitCache.exit(for: endpoint, maxAge: maxAge, now: now)
    }

    /// Forgets every cached exit, for instance after the network changed.
    public static func forgetCachedExits() {
        exitCache.clear()
    }

    private static let exitCache = ExitCache()

    private final class ExitCache: @unchecked Sendable {
        private let lock = NSLock()
        private var exits: [String: (exit: ProxyExit, foundAt: Date)] = [:]

        func store(_ exit: ProxyExit, for endpoint: ProxyEndpoint?, at date: Date = Date()) {
            lock.lock()
            defer { lock.unlock() }
            exits[endpoint?.url ?? ""] = (exit, date)
        }

        func exit(for endpoint: ProxyEndpoint?, maxAge: TimeInterval, now: Date) -> ProxyExit? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = exits[endpoint?.url ?? ""], now.timeIntervalSince(entry.foundAt) <= maxAge,
                  entry.foundAt <= now else { return nil }
            return entry.exit
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            exits = [:]
        }
    }

    static func sessionConfiguration(_ base: URLSessionConfiguration, through endpoint: ProxyEndpoint?,
                                     timeout: TimeInterval) throws -> URLSessionConfiguration {
        let configuration = base.copy() as? URLSessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        guard let endpoint else { return configuration }
        let host = bare(endpoint.host)
        switch endpoint.scheme {
        case "socks5" where !endpoint.hasCredentials:
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: endpoint.port,
            ]
        case "http" where !endpoint.hasCredentials:
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: endpoint.port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: endpoint.port,
            ]
        default:
            // The proxy dictionary can neither sign in (URLSession never surfaces a 407 from it) nor
            // speak TLS to the proxy; a proxy configuration does both.
            guard #available(macOS 14, *) else {
                throw ProfileError.invalid(endpoint.scheme == "https"
                    ? "此系统版本无法检测 HTTPS 代理，需要 macOS 14 或更高版本。"
                    : "此系统版本无法检测带账号密码的代理，需要 macOS 14 或更高版本。")
            }
            guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: endpoint.port)) else {
                throw ProfileError.invalid("代理端口无效。")
            }
            let server = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
            let proxy = endpoint.scheme == "socks5" ? ProxyConfiguration(socksv5Proxy: server)
                : ProxyConfiguration(httpCONNECTProxy: server, tlsOptions: endpoint.scheme == "https" ? NWProtocolTLS.Options() : nil)
            if let username = endpoint.username, let password = endpoint.password {
                proxy.applyCredential(username: username, password: password)
            }
            configuration.proxyConfigurations = [proxy]
        }
        return configuration
    }

    private struct LookupFailure: Error {
        let reason: String
    }

    private static func lookup(_ service: URL, through endpoint: ProxyEndpoint?,
                               in session: URLSession) async throws -> ProxyExit {
        let name = service.host ?? service.absoluteString
        var request = URLRequest(url: service)
        for (name, value) in neutralHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: RedirectRefusal())
        } catch {
            let failure = error as NSError
            if failure.domain == NSPOSIXErrorDomain && failure.code == Int(EAUTH) {
                throw LookupFailure(reason: endpoint?.hasCredentials == true
                    ? "代理拒绝了用户名或密码" : "代理要求登录，请在代理地址里填写用户名和密码")
            }
            if (error as? URLError)?.code == .timedOut {
                throw LookupFailure(reason: "\(name) 请求超时")
            }
            throw LookupFailure(reason: "\(name) \(error.localizedDescription)")
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            break
        case 407:
            throw LookupFailure(reason: "代理要求登录，请在代理地址里填写用户名和密码")
        case let status:
            throw LookupFailure(reason: "\(name) 返回 \(status.map(String.init) ?? "未知") 状态")
        }
        guard data.count <= 65_536, let exit = try? exit(from: data) else {
            throw LookupFailure(reason: "\(name) 返回的数据无法识别")
        }
        return exit
    }

    /// Reads any service's JSON: ipinfo.io (`country`, `timezone`), ipapi.co (`country_code`,
    /// `timezone`, `languages`), ipwho.is (`country_code`, `timezone.id`) or geojs.io (`country_code`,
    /// `timezone`). Values the profile could not use are left empty.
    static func exit(from data: Data) throws -> ProxyExit {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProfileError.invalid("出口信息不是 JSON 对象。")
        }
        // ipapi.co sets `error`, ipwho.is clears `success`.
        if let error = body["error"], (error as? Bool) != false {
            throw ProfileError.invalid("出口查询服务返回错误。")
        }
        if let success = body["success"], (success as? Bool) != true {
            throw ProfileError.invalid("出口查询服务返回错误。")
        }
        let text = { (key: String) -> String in
            String((body[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120) ?? "")
        }
        let ip = text("ip")
        var address = in6_addr()
        guard inet_pton(AF_INET, ip, &address) == 1 || inet_pton(AF_INET6, ip, &address) == 1 else {
            throw ProfileError.invalid("出口信息缺少 IP 地址。")
        }
        var country = text("country_code").isEmpty ? text("country") : text("country_code")
        country = country.uppercased()
        if country.count != 2 || !country.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) {
            country = ""
        }
        var timeZone = text("timezone")
        if timeZone.isEmpty, let zone = (body["timezone"] as? [String: Any])?["id"] as? String {
            timeZone = zone.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !FingerprintSettings.isTimeZone(timeZone) { timeZone = "" }
        var languages = text("languages").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter(FingerprintSettings.isLanguageTag)
        if languages.isEmpty { languages = commonLanguages[country] ?? [] }
        return ProxyExit(ip: ip, countryCode: country, region: text("region"), city: text("city"),
                         timeZone: timeZone, languages: languages)
    }

    /// The languages a browser in the country most often asks for, used when the service omits them.
    static let commonLanguages: [String: [String]] = [
        "CN": ["zh-CN"], "TW": ["zh-TW"], "HK": ["zh-HK", "en-HK"], "MO": ["zh-MO"],
        "SG": ["en-SG", "zh-SG"], "JP": ["ja-JP"], "KR": ["ko-KR"], "US": ["en-US"], "GB": ["en-GB"],
        "CA": ["en-CA", "fr-CA"], "AU": ["en-AU"], "NZ": ["en-NZ"], "IE": ["en-IE"], "DE": ["de-DE"],
        "AT": ["de-AT"], "CH": ["de-CH", "fr-CH"], "FR": ["fr-FR"], "BE": ["nl-BE", "fr-BE"], "ES": ["es-ES"],
        "PT": ["pt-PT"], "IT": ["it-IT"], "NL": ["nl-NL"], "SE": ["sv-SE"], "NO": ["nb-NO"], "DK": ["da-DK"],
        "FI": ["fi-FI"], "PL": ["pl-PL"], "CZ": ["cs-CZ"], "RU": ["ru-RU"], "UA": ["uk-UA"], "TR": ["tr-TR"],
        "IL": ["he-IL"], "AE": ["ar-AE", "en-AE"], "SA": ["ar-SA"], "IN": ["en-IN", "hi-IN"],
        "TH": ["th-TH"], "VN": ["vi-VN"], "ID": ["id-ID"], "MY": ["ms-MY", "en-MY"], "PH": ["en-PH"],
        "BR": ["pt-BR"], "MX": ["es-MX"], "AR": ["es-AR"], "CL": ["es-CL"], "CO": ["es-CO"], "ZA": ["en-ZA"],
    ]

    /// A host as the network stack takes it: IPv6 literals without brackets.
    private static func bare(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
