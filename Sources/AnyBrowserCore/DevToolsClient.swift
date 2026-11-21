import Foundation

/// An error the browser returned for a DevTools command.
public struct DevToolsCommandError: LocalizedError {
    public let method: String
    public let code: Int
    public let message: String

    public var errorDescription: String? { "浏览器未能完成 \(method)：\(message)" }
}

/// A minimal client for the browser-level DevTools WebSocket of a Profile on this Mac.
public actor DevToolsClient {
    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<[String: Any], Error>
        let timer: Task<Void, Never>
    }

    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let timeout: TimeInterval
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var receiver: Task<Void, Never>?
    private var failure: Error?

    /// Only `ws://127.0.0.1:<port>/devtools/browser/<id>` is accepted.
    public static func accepts(_ endpoint: URL) -> Bool {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme == "ws", parts.host == "127.0.0.1", let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return false }
        return parts.percentEncodedPath.range(of: "^/devtools/browser/[A-Za-z0-9-]+$", options: .regularExpression) != nil
    }

    public init(endpoint: URL, timeout: TimeInterval = 10) throws {
        guard Self.accepts(endpoint) else {
            throw ProfileError.invalid("只能连接本机浏览器的调试地址。")
        }
        let configuration = URLSessionConfiguration.loopback
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
        socket = session.webSocketTask(with: endpoint)
        // Storage.getCookies returns every cookie of the Profile in one message.
        socket.maximumMessageSize = 64 << 20
        self.timeout = timeout
        socket.resume()
    }

    deinit {
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    /// Sends a command and waits for its result. CDP errors throw `DevToolsCommandError`.
    /// Pass a `sessionId` from `Target.attachToTarget` for page-scoped domains such as `Storage.clearDataForOrigin`.
    public func send(_ method: String, _ params: [String: Any] = [:],
                     sessionId: String? = nil) async throws -> [String: Any] {
        if let failure { throw failure }
        nextID += 1
        let id = nextID
        var command: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionId { command["sessionId"] = sessionId }
        guard JSONSerialization.isValidJSONObject(command) else {
            throw ProfileError.invalid("调试命令 \(method) 的参数无效。")
        }
        let message = String(decoding: try JSONSerialization.data(withJSONObject: command), as: UTF8.self)
        if receiver == nil {
            receiver = Task { await self.receive() }
        }
        // Registered before sending so that a fast reply always finds its command.
        return try await withCheckedThrowingContinuation { continuation in
            let timer = Task { [timeout] in
                guard (try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))) != nil else { return }
                self.finish(id, .failure(ProfileError.invalid("浏览器调试接口没有响应，请稍后重试。")))
            }
            pending[id] = Pending(method: method, continuation: continuation, timer: timer)
            socket.send(.string(message)) { error in
                guard error != nil else { return }
                Task { await self.finish(id, .failure(Self.disconnected)) }
            }
        }
    }

    /// Closes the connection; commands still waiting fail.
    public nonisolated func close() {
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private static var disconnected: Error { ProfileError.invalid("与浏览器的调试连接已断开。") }

    private func receive() async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                failure = Self.disconnected
                for id in Array(pending.keys) { finish(id, .failure(Self.disconnected)) }
                return
            }
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            // Events carry no id; replies to commands that already timed out find nothing.
            guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = reply["id"] as? Int, let entry = pending[id] else { continue }
            if let error = reply["error"] as? [String: Any] {
                finish(id, .failure(DevToolsCommandError(method: entry.method, code: error["code"] as? Int ?? 0,
                                                         message: error["message"] as? String ?? "未知错误")))
            } else {
                finish(id, .success(reply["result"] as? [String: Any] ?? [:]))
            }
        }
    }

    private func finish(_ id: Int, _ result: Result<[String: Any], Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        entry.continuation.resume(with: result)
    }
}
