@testable import AnyBrowserCore
import Darwin
import Foundation
import Network
import Testing

// Shared by the test suites. Debug ports 9222/9223 belong to InstalledEngineTests.

/// The packaged AnyBrowser.app the engine suites run against; they are skipped without it.
let testAppPath = ProcessInfo.processInfo.environment["ANYBROWSER_TEST_APP"]

/// Engine suites add `ANYBROWSER_TEST_PORT_OFFSET` to their fixed debug ports, so several
/// worktrees can run them at the same time without fighting over 9222 and friends.
func testPort(_ port: Int) -> Int { port + testPortOffset }

/// Without an explicit offset, unit runs from several worktrees at once would start their fake
/// engines on the same ports, so each process shifts them by its own multiple of 100. Engine runs
/// keep the documented ports unless the offset is set.
let testPortOffset: Int = {
    let environment = ProcessInfo.processInfo.environment
    if let offset = environment["ANYBROWSER_TEST_PORT_OFFSET"].flatMap(Int.init) { return offset }
    return environment["ANYBROWSER_TEST_APP"] == nil ? Int(getpid() % 100 + 1) * 100 : 0
}()

func testEngine() throws -> BrowserEngine {
    try BrowserEngine.bundled(in: URL(fileURLWithPath: try #require(testAppPath)))
}

/// A new empty directory for one test, at its canonical path, which the runtime and the
/// extension directory checks compare against.
func scratchDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("anybrowser-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return try #require(ProcessInspection.canonicalURL(url, isDirectory: true))
}

/// The path of the package's executable `name`, built next to the test bundle; nil when it is not built.
func builtProduct(_ name: String) -> String? {
    let candidate = Bundle(for: ProductMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent(name).path
    return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
}

private final class ProductMarker {}

func permissions(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
}

/// The inode of `url` itself rather than of what a link points to.
func inode(_ url: URL) throws -> UInt64 {
    var details = stat()
    try #require(lstat(url.path, &details) == 0)
    return details.st_ino
}

extension NWListener {
    /// Starts listening on `queue` and returns the port once ready. A listener that fails is cancelled.
    func startAndWait(on queue: DispatchQueue) async throws -> UInt16 {
        if newConnectionHandler == nil { newConnectionHandler = { $0.cancel() } }
        return try await withCheckedThrowingContinuation { continuation in
            stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.stateUpdateHandler = nil
                    if let port = self.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        self.cancel()
                        continuation.resume(throwing: VerificationFailure.message("The test listener has no port"))
                    }
                case .failed(let error):
                    self.stateUpdateHandler = nil
                    self.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            start(queue: queue)
        }
    }
}

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

    static func start(title: String = "AnyBrowser local test", content: String = "") async throws -> LoopbackPage {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "anybrowser.smoke.loopback")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in
                let body = "<!doctype html><meta charset=utf-8><title>\(title)</title>\(content)"
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port = try await listener.startAndWait(on: queue)
        return LoopbackPage(listener: listener, url: try #require(URL(string: "http://127.0.0.1:\(port)/")))
    }
}

/// A loopback server that counts requests per path. `/asset.js` may be cached for a day;
/// `/slow` answers after `delay`.
final class CountingServer: @unchecked Sendable {
    let listener: NWListener
    let base: URL
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    private init(listener: NWListener, base: URL) {
        self.listener = listener
        self.base = base
    }

    static func start(delay: TimeInterval = 0) async throws -> CountingServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "anybrowser.test.counting")
        var server: CountingServer?
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                server?.count(path)
                let (headers, body): (String, String) = switch path {
                case "/asset.js": ("Content-Type: text/javascript\r\nCache-Control: public, max-age=86400", "window.loaded = 1;")
                case "/favicon.ico": ("Content-Type: text/plain", "")
                default: ("Content-Type: text/html\r\nCache-Control: no-store", "<!doctype html><title>AnyBrowser test \(path)</title>")
                }
                let response = Data("HTTP/1.1 200 OK\r\n\(headers)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                queue.asyncAfter(deadline: .now() + (path == "/slow" ? delay : 0)) {
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        let port = try await listener.startAndWait(on: queue)
        let created = CountingServer(listener: listener, base: try #require(URL(string: "http://127.0.0.1:\(port)/")))
        server = created
        return created
    }

    private func count(_ path: String) {
        lock.lock()
        counts[path, default: 0] += 1
        lock.unlock()
    }

    func requests(_ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[path] ?? 0
    }

    func url(_ path: String) -> String { base.absoluteString + path.dropFirst() }
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

    /// Polls the port's target list until `condition` holds for it, and returns that list.
    @discardableResult
    static func waitForTargets(port: Int, timeout: TimeInterval = 10,
                               until condition: ([[String: Any]]) -> Bool) async throws -> [[String: Any]] {
        let list = try #require(URL(string: "http://127.0.0.1:\(port)/json/list"))
        let deadline = Date().addingTimeInterval(timeout)
        var targets: [[String: Any]] = []
        while Date() < deadline {
            if let (data, _) = try? await URLSession.shared.data(from: list),
               let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                targets = value
                if condition(targets) { return targets }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let seen = targets.map { "\($0["type"] ?? "") \($0["url"] ?? "")" }
        throw VerificationFailure.message("DevTools targets did not settle: \(seen)")
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
