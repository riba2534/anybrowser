import Foundation
import Network
import Security

/// Settings of the local automation API, stored as JSON under the `automation` setting.
public struct AutomationConfiguration: Codable, Equatable, Sendable {
    public static let defaultPort = 50330

    public var enabled: Bool
    public var port: Int
    public var token: String

    public init(enabled: Bool = false, port: Int = AutomationConfiguration.defaultPort, token: String) {
        self.enabled = enabled
        self.port = port
        self.token = token
    }

    /// 32 random bytes as lowercase hex.
    public static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ProfileError.invalid("无法生成访问令牌。")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func validated() throws -> AutomationConfiguration {
        guard (1024...65535).contains(port) else {
            throw ProfileError.invalid("自动化接口端口须为 1024–65535。")
        }
        guard token.utf8.count == 64, token.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw ProfileError.invalid("访问令牌无效，请重新生成。")
        }
        return self
    }
}

extension ProfileStore {
    static let automationKey = "automation"

    /// The saved automation settings. Missing or unreadable settings are replaced by disabled
    /// defaults with a new token, so the token stays the same across launches.
    public func automationConfiguration() throws -> AutomationConfiguration {
        if let saved = try setting(AutomationConfiguration.self, forKey: Self.automationKey),
           let valid = try? saved.validated() {
            return valid
        }
        let fresh = AutomationConfiguration(token: try AutomationConfiguration.newToken())
        try saveSetting(fresh, forKey: Self.automationKey)
        return fresh
    }

    public func saveAutomationConfiguration(_ configuration: AutomationConfiguration) throws {
        try saveSetting(try configuration.validated(), forKey: Self.automationKey)
    }
}

/// What the automation API reads and controls. Only authenticated requests reach it.
@MainActor
public protocol AutomationBackend: AnyObject {
    /// Saved Profiles; the API never sees unsaved edits.
    var profiles: [BrowserProfile] { get }
    func state(for id: UUID) -> BrowserRunState
    func isBusy(_ id: UUID) -> Bool
    func start(_ profile: BrowserProfile) async throws
    func stop(_ id: UUID) async throws
    func devToolsEndpoint(for id: UUID) async -> URL?
}

/// Serves the automation API on 127.0.0.1 with one request per connection. Network callbacks run
/// on a private queue; the Host, Origin and token checks happen there, so rejected requests never
/// reach the main actor.
public final class AutomationServer: @unchecked Sendable {
    public let port: Int
    private let queue = DispatchQueue(label: "AnyBrowser.AutomationServer")
    private weak var backend: AutomationBackend?
    private let onFailure: @MainActor @Sendable (String) -> Void
    // Everything below is only touched on `queue`.
    private var token: [UInt8]
    private var listener: NWListener?
    private var pendingStart: CheckedContinuation<Int, Error>?
    private var boundPort = 0
    private var exchanges: [ObjectIdentifier: Exchange] = [:]

    /// `onFailure` reports a listener that fails after it started listening.
    public init(port: Int, token: String, backend: AutomationBackend,
                onFailure: @escaping @MainActor @Sendable (String) -> Void = { _ in }) {
        self.port = port
        self.token = Array(token.utf8)
        self.backend = backend
        self.onFailure = onFailure
    }

    deinit { listener?.cancel() }

    /// Starts listening and returns the bound port; throws when the port cannot be used.
    public func start() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.listen(continuation) }
        }
    }

    /// Stops listening and drops open connections. Returns once the port is released.
    public func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let listener = self.listener else { return continuation.resume() }
                self.listener = nil
                self.pendingStart?.resume(throwing: ProfileError.invalid("自动化接口已停止。"))
                self.pendingStart = nil
                self.dropConnections()
                // The handler keeps the listener alive until the socket is closed.
                listener.stateUpdateHandler = { state in
                    guard case .cancelled = state else { return }
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                }
                listener.cancel()
            }
        }
    }

    /// Replaces the token without dropping the listener; later requests use the new one.
    public func update(token: String) {
        queue.sync { self.token = Array(token.utf8) }
    }

    private func listen(_ continuation: CheckedContinuation<Int, Error>) {
        guard listener == nil else {
            return continuation.resume(throwing: ProfileError.invalid("自动化接口已在运行。"))
        }
        guard (0...65535).contains(port), let port = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return continuation.resume(throwing: ProfileError.invalid("自动化接口端口须为 1024–65535。"))
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.requiredInterfaceType = .loopback
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            return continuation.resume(throwing: ProfileError.invalid(message(for: error)))
        }
        self.listener = listener
        pendingStart = continuation
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.boundPort = Int(listener.port?.rawValue ?? 0)
                self.pendingStart?.resume(returning: self.boundPort)
                self.pendingStart = nil
            case .failed(let error), .waiting(let error):
                // Waiting would retry in the background; a taken port should be reported instead.
                self.listener = nil
                listener.cancel()
                self.dropConnections()
                let text = self.message(for: error)
                if let pending = self.pendingStart {
                    self.pendingStart = nil
                    pending.resume(throwing: ProfileError.invalid(text))
                } else {
                    Task { @MainActor in self.onFailure(text) }
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    private func dropConnections() {
        for exchange in exchanges.values { exchange.connection.cancel() }
        exchanges = [:]
    }

    private func message(for error: Error) -> String {
        if case .posix(.EADDRINUSE) = error as? NWError {
            return "端口 \(port) 已被占用，请换一个端口。"
        }
        return "无法监听 127.0.0.1:\(port)：\(error.localizedDescription)"
    }

    private func accept(_ connection: NWConnection) {
        // Scripts on this Mac need only a few connections at once.
        guard exchanges.count < 64 else { return connection.cancel() }
        let exchange = Exchange(connection: connection)
        let key = ObjectIdentifier(exchange)
        exchanges[key] = exchange
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed:
                connection.cancel()
            case .cancelled:
                self?.exchanges[key] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Slow clients get 10 seconds to send their request; a browser start may take longer to answer.
        queue.asyncAfter(deadline: .now() + 10) {
            if !exchange.received { connection.cancel() }
        }
        receive(exchange)
    }

    private func receive(_ exchange: Exchange) {
        exchange.connection.receive(minimumIncompleteLength: 1, maximumLength: AutomationHTTP.limit + 1) {
            [weak self] data, _, isComplete, error in
            guard let self, !exchange.received else { return }
            if let data { exchange.buffer.append(data) }
            switch AutomationHTTP.parse(exchange.buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    exchange.connection.cancel()
                } else {
                    self.receive(exchange)
                }
            case .reject(let response):
                self.respond(response, to: exchange)
            case .request(let request):
                if let rejection = AutomationHTTP.authorize(request, port: self.boundPort, token: self.token) {
                    return self.respond(rejection, to: exchange)
                }
                exchange.received = true
                Task { @MainActor in
                    let response: AutomationHTTP.Response
                    if let backend = self.backend {
                        response = await AutomationHTTP.route(request, backend: backend)
                    } else {
                        response = .error(503, "unavailable", "AnyBrowser 正在退出。")
                    }
                    self.queue.async { self.respond(response, to: exchange) }
                }
            }
        }
    }

    private func respond(_ response: AutomationHTTP.Response, to exchange: Exchange) {
        exchange.received = true
        let connection = exchange.connection
        connection.send(content: response.encoded(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.drain(connection) })
    }

    /// Reads until the client closes, so an early answer such as 413 is not lost to a reset.
    private func drain(_ connection: NWConnection) {
        queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
        func next() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, isComplete, error in
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    next()
                }
            }
        }
        next()
    }

    private final class Exchange: @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()
        /// Set once a whole request is read; ends the read timeout.
        var received = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }
}

/// HTTP/1.1 parsing, the access checks and the routes of the automation API.
enum AutomationHTTP {
    /// Request line, headers and body together.
    static let limit = 65_536

    struct Request: Equatable, Sendable {
        var method: String
        var target: String
        /// Lowercased name → values in arrival order.
        var headers: [String: [String]]
    }

    struct Response: Equatable, Sendable {
        var status: Int
        var body: Data
        var headers: [String] = []

        static func json<Value: Encodable>(_ status: Int, _ value: Value, headers: [String] = []) -> Response {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return Response(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8), headers: headers)
        }

        static func error(_ status: Int, _ code: String, _ message: String, headers: [String] = []) -> Response {
            json(status, ["error": ["code": code, "message": message]], headers: headers)
        }

        func encoded() -> Data {
            let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                           405: "Method Not Allowed", 409: "Conflict", 413: "Content Too Large",
                           500: "Internal Server Error", 503: "Service Unavailable"]
            let lines = ["HTTP/1.1 \(status) \(reasons[status] ?? "Error")",
                         "Content-Type: application/json; charset=utf-8",
                         "Content-Length: \(body.count)",
                         "Cache-Control: no-store",
                         "X-Content-Type-Options: nosniff",
                         "Connection: close"] + headers
            return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
        }
    }

    enum Parse: Equatable, Sendable {
        case incomplete
        case request(Request)
        case reject(Response)
    }

    static let tooLarge = Response.error(413, "payload_too_large", "请求头和请求体合计不能超过 64 KB。")
    static let badRequest = Response.error(400, "bad_request", "无法解析的 HTTP 请求。")

    static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > limit ? .reject(tooLarge) : .incomplete
        }
        let headLength = end.upperBound - data.startIndex
        guard headLength <= limit else { return .reject(tooLarge) }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .reject(badRequest)
        }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, !start[0].isEmpty, start[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              start[1].hasPrefix("/"), start[1].unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }),
              start[2] == "HTTP/1.1" || start[2] == "HTTP/1.0" else {
            return .reject(badRequest)
        }
        var headers: [String: [String]] = [:]
        for line in lines {
            // Names must be tokens, which also rules out obsolete folded lines.
            guard let colon = line.firstIndex(of: ":"), line.startIndex < colon,
                  line[..<colon].unicodeScalars.allSatisfy(isTokenCharacter) else {
                return .reject(badRequest)
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard !value.unicodeScalars.contains(where: { $0 != "\t" && CharacterSet.controlCharacters.contains($0) }) else {
                return .reject(badRequest)
            }
            headers[line[..<colon].lowercased(), default: []].append(value)
        }
        // Chunked bodies are not supported, and a body length must be unambiguous.
        guard headers["transfer-encoding"] == nil else { return .reject(badRequest) }
        var bodyLength = 0
        if let lengths = headers["content-length"] {
            guard lengths.count == 1, let value = lengths.first, (1...18).contains(value.count),
                  value.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(value) else {
                return .reject(badRequest)
            }
            bodyLength = length
        }
        guard bodyLength <= limit - headLength else { return .reject(tooLarge) }
        guard data.count >= headLength + bodyLength else { return .incomplete }
        return .request(Request(method: String(start[0]), target: String(start[1]), headers: headers))
    }

    private static func isTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar))
    }

    /// Host blocks DNS rebinding, Origin blocks requests sent by web pages, and the token
    /// authenticates the caller. Returns the rejection, or nil when the request may proceed.
    static func authorize(_ request: Request, port: Int, token: [UInt8]) -> Response? {
        let hosts = request.headers["host"] ?? []
        guard hosts.count == 1, ["127.0.0.1:\(port)", "localhost:\(port)"].contains(hosts[0].lowercased()) else {
            return .error(403, "forbidden_host", "只接受 Host 为 127.0.0.1:\(port) 或 localhost:\(port) 的请求。")
        }
        guard request.headers["origin"] == nil else {
            return .error(403, "forbidden_origin", "不接受网页发起的请求。")
        }
        let credentials = request.headers["authorization"] ?? []
        guard credentials.count == 1, let presented = bearer(credentials[0]), constantTimeEqual(presented, token) else {
            return .error(401, "unauthorized", "缺少访问令牌或令牌错误。", headers: ["WWW-Authenticate: Bearer"])
        }
        return nil
    }

    private static func bearer(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return Array(parts[1].utf8)
    }

    /// Compares every byte regardless of where the first mismatch is.
    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count, !rhs.isEmpty else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    struct ProfileObject: Encodable {
        var id: UUID
        var name: String
        var group: String
        var port: Int
        var status: String
        var debugReady: Bool
    }

    struct DebugAddress: Encodable {
        var http: String
        var webSocket: String
    }

    private struct Started: Encodable {
        var profile: ProfileObject
        var debug: DebugAddress
    }

    static let notFound = Response.error(404, "not_found", "没有这个接口或 Profile。")
    static let busy = Response.error(409, "busy", "该 Profile 正在执行另一个操作，请稍后重试。")

    @MainActor
    static func route(_ request: Request, backend: AutomationBackend) async -> Response {
        let path = request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, parts[0].isEmpty, parts[1] == "api", parts[2] == "v1", parts[3] == "profiles" else {
            return notFound
        }
        let action = parts.count == 6 ? parts[5] : nil
        switch (parts.count, action) {
        case (4, _):
            guard request.method == "GET" else { return methodNotAllowed("GET") }
            return .json(200, ["profiles": backend.profiles.map { object($0, backend: backend) }])
        case (5, _):
            guard request.method == "GET" else { return methodNotAllowed("GET") }
            guard let profile = lookup(parts[4], backend: backend) else { return notFound }
            return .json(200, ["profile": object(profile, backend: backend)])
        case (6, "start"):
            guard request.method == "POST" else { return methodNotAllowed("POST") }
            guard let profile = lookup(parts[4], backend: backend) else { return notFound }
            return await start(profile, backend: backend)
        case (6, "stop"):
            guard request.method == "POST" else { return methodNotAllowed("POST") }
            guard let profile = lookup(parts[4], backend: backend) else { return notFound }
            return await stop(profile, backend: backend)
        default:
            return notFound
        }
    }

    private static func methodNotAllowed(_ allowed: String) -> Response {
        .error(405, "method_not_allowed", "此接口只支持 \(allowed)。", headers: ["Allow: \(allowed)"])
    }

    @MainActor
    private static func lookup(_ id: String, backend: AutomationBackend) -> BrowserProfile? {
        guard let id = UUID(uuidString: id) else { return nil }
        return backend.profiles.first { $0.id == id }
    }

    @MainActor
    static func object(_ profile: BrowserProfile, backend: AutomationBackend) -> ProfileObject {
        let state = backend.state(for: profile.id)
        var object = ProfileObject(id: profile.id, name: profile.name, group: profile.group, port: profile.port,
                                   status: "stopped", debugReady: false)
        switch state {
        case .stopped: object.status = "stopped"
        case .starting: object.status = "starting"
        case .stopping: object.status = "stopping"
        case .failed: object.status = "failed"
        case let .running(_, port, ready):
            // A running browser keeps the port it was started with until it restarts.
            object.status = "running"
            object.port = port
            object.debugReady = ready
        }
        return object
    }

    @MainActor
    private static func start(_ profile: BrowserProfile, backend: AutomationBackend) async -> Response {
        let id = profile.id
        guard !backend.isBusy(id) else { return busy }
        var endpoint: URL?
        if case .running = backend.state(for: id) {
            endpoint = await backend.devToolsEndpoint(for: id)
        }
        if endpoint == nil {
            guard !backend.isBusy(id) else { return busy }
            do {
                try await backend.start(profile)
            } catch {
                return .error(500, "start_failed", error.localizedDescription)
            }
            endpoint = await backend.devToolsEndpoint(for: id)
        }
        guard let endpoint, let address = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = address.host, let port = address.port else {
            return .error(500, "start_failed", "浏览器已启动，但无法确认调试地址。")
        }
        let current = backend.profiles.first { $0.id == id } ?? profile
        return .json(200, Started(profile: object(current, backend: backend),
                                  debug: DebugAddress(http: "http://\(host):\(port)", webSocket: endpoint.absoluteString)))
    }

    @MainActor
    private static func stop(_ profile: BrowserProfile, backend: AutomationBackend) async -> Response {
        guard !backend.isBusy(profile.id) else { return busy }
        do {
            try await backend.stop(profile.id)
        } catch {
            return .error(500, "stop_failed", error.localizedDescription)
        }
        let current = backend.profiles.first { $0.id == profile.id } ?? profile
        return .json(200, ["profile": object(current, backend: backend)])
    }
}
