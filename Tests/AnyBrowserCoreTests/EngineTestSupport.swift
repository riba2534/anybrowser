import AnyBrowserCore
import Foundation
import Network
import Testing

// Shared by the installed-engine suites. Ports 9222/9223 belong to InstalledEngineTests.

/// A local Passkey Box server, a strict WebAuthn test site (passkey-box/e2e/rp) and an account.
struct PasskeyFlow {
    var app: String
    var account: PasskeyBoxAccount
    var rp: String

    static var current: PasskeyFlow? {
        let environment = ProcessInfo.processInfo.environment
        guard let app = environment["ANYBROWSER_TEST_APP"],
              let server = environment["ANYBROWSER_TEST_PASSKEY_SERVER"],
              let username = environment["ANYBROWSER_TEST_PASSKEY_USERNAME"],
              let password = environment["ANYBROWSER_TEST_PASSKEY_PASSWORD"],
              let rp = environment["ANYBROWSER_TEST_PASSKEY_RP"] else { return nil }
        return PasskeyFlow(app: app, account: PasskeyBoxAccount(serverURL: server, username: username, password: password), rp: rp)
    }
}

enum VerificationFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}

struct LoopbackPage {
    var listener: NWListener
    var url: URL

    static func start(title: String = "AnyBrowser local test") async throws -> LoopbackPage {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "anybrowser.smoke.loopback")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in
                let body = "<!doctype html><meta charset=utf-8><title>\(title)</title>"
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port?.rawValue, let url = URL(string: "http://127.0.0.1:\(port)/") {
                        continuation.resume(returning: LoopbackPage(listener: listener, url: url))
                    } else {
                        listener.cancel()
                        continuation.resume(throwing: VerificationFailure.message("Loopback page has no port"))
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    listener.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }
}

final class DevToolsPage {
    let socket: URLSessionWebSocketTask
    private var nextID = 0

    private init(socket: URLSessionWebSocketTask) {
        self.socket = socket
    }

    static func open(port: Int, url: URL) async throws -> DevToolsPage {
        let local = try #require(URL(string: "http://127.0.0.1:\(port)/json/list"))
        let (data, _) = try await URLSession.shared.data(from: local)
        let targets = try #require(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        let endpoint = try #require(targets.first { $0["type"] == "page" }?["webSocketDebuggerUrl"])
        let socketURL = try #require(URL(string: endpoint))
        guard socketURL.scheme == "ws", socketURL.host == "127.0.0.1", socketURL.port == port else {
            throw VerificationFailure.message("Unexpected session endpoint")
        }
        let task = URLSession.shared.webSocketTask(with: socketURL)
        task.resume()
        let page = DevToolsPage(socket: task)
        do {
            try await page.navigate(to: url)
            return page
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            throw error
        }
    }

    static func pageCount(port: Int) async throws -> Int {
        let list = try #require(URL(string: "http://127.0.0.1:\(port)/json/list"))
        let (data, _) = try await URLSession.shared.data(from: list)
        let targets = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return targets.filter { $0["type"] as? String == "page" }.count
    }

    /// The test site's #result once it is no longer idle or pending.
    func siteResult() async throws -> String {
        for _ in 0..<150 {
            let value = try await evaluate("document.querySelector('#result')?.textContent ?? ''") as? String ?? ""
            if !value.isEmpty, value != "idle", !value.hasPrefix("pending:") { return value }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VerificationFailure.message("测试网站没有返回结果")
    }

    func navigate(to url: URL) async throws {
        _ = try await command("Page.navigate", ["url": url.absoluteString])
        for _ in 0..<50 {
            if let location = try? await evaluate("document.readyState === 'complete' && location.href"),
               (location as? String) == url.absoluteString {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VerificationFailure.message("Timed out waiting for the local page")
    }

    func evaluate(_ expression: String, awaitPromise: Bool = false, userGesture: Bool = false) async throws -> Any {
        let response = try await command("Runtime.evaluate", [
            "expression": expression, "returnByValue": true, "awaitPromise": awaitPromise, "userGesture": userGesture,
        ])
        let result = try #require(response["result"] as? [String: Any])
        return result["value"] ?? NSNull()
    }

    private func command(_ name: String, _ parameters: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        let commandID = nextID
        let request = try JSONSerialization.data(withJSONObject: ["id": commandID, "method": name, "params": parameters])
        try await socket.send(.string(String(decoding: request, as: UTF8.self)))
        let timeout = Task { [socket] in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }

        while true {
            let message = try await socket.receive()
            let bytes: Data
            switch message {
            case .string(let string): bytes = Data(string.utf8)
            case .data(let data): bytes = data
            @unknown default: throw VerificationFailure.message("Unknown DevTools message")
            }
            let value = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            if value["id"] as? Int == commandID {
                if let error = value["error"] {
                    throw VerificationFailure.message("DevTools \(name) failed: \(error)")
                }
                return try #require(value["result"] as? [String: Any])
            }
        }
    }
}
