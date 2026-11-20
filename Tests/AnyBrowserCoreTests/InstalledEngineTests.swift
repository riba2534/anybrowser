import AnyBrowserCore
import Foundation
import Network
import XCTest

final class InstalledEngineTests: XCTestCase {
    func testSeparateProfilesOnInstalledAppleSiliconEngine() async throws {
        guard let path = ProcessInfo.processInfo.environment["ANYBROWSER_TEST_APP"] else {
            throw XCTSkip("Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test.")
        }
        let engine = try BrowserEngine.bundled(in: URL(fileURLWithPath: path))
        try await verify(engine: engine)
    }

    @MainActor
    private func verify(engine: BrowserEngine) async throws {
        XCTAssertEqual(engine.version, "148.0.7778.215")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anybrowser-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = try await LoopbackPage.start()
        defer { page.listener.cancel() }
        let store = try ProfileStore(directory: directory)
        var first = try store.makeDraft()
        first.fingerprint.platform = .macOS
        first.fingerprint.cpuCount = 8
        first.fingerprint.timeZone = "UTC"
        try store.save(first)
        var second = try store.makeDraft()
        second.fingerprint.platform = .windows
        second.fingerprint.cpuCount = 12
        second.fingerprint.timeZone = "Asia/Tokyo"
        try store.save(second)
        XCTAssertEqual([first.port, second.port], [9222, 9223])

        let runtime = BrowserRuntime(engine: engine, storage: store.directory)
        do {
            try await runtime.start(first)
            try await runtime.start(second)
            let pids = try [first, second].map { profile in
                guard case let .running(pid, port, true) = runtime.status(for: profile.id), port == profile.port else {
                    throw VerificationFailure.message("CDP 未就绪：\(runtime.status(for: profile.id))")
                }
                return pid
            }
            XCTAssertNotEqual(pids[0], pids[1])

            let restored = BrowserRuntime(engine: engine, storage: store.directory)
            await restored.refresh([first, second])
            XCTAssertEqual(restored.status(for: first.id), runtime.status(for: first.id))
            XCTAssertEqual(restored.status(for: second.id), runtime.status(for: second.id))
            XCTAssertEqual(restored.matchesRunningConfiguration(first), true)
            var changed = first
            changed.fingerprint.cpuCount = 16
            XCTAssertEqual(restored.matchesRunningConfiguration(changed), false)

            let firstPage = try await DevToolsPage.open(port: first.port, url: page.url)
            let secondPage = try await DevToolsPage.open(port: second.port, url: page.url)
            defer {
                firstPage.socket.cancel(with: .normalClosure, reason: nil)
                secondPage.socket.cancel(with: .normalClosure, reason: nil)
            }

            try await assertPage(firstPage, platform: "macOS", cores: 8, timezone: "UTC")
            try await assertPage(secondPage, platform: "Windows", cores: 12, timezone: "Asia/Tokyo")
            _ = try await firstPage.evaluate("localStorage.setItem('anybrowser-fixture', 'profile-one')")
            let secondInitial = try await secondPage.evaluate("localStorage.getItem('anybrowser-fixture')")
            XCTAssertTrue(secondInitial is NSNull)
            _ = try await secondPage.evaluate("localStorage.setItem('anybrowser-fixture', 'profile-two')")
            let firstStored = try await firstPage.evaluate("localStorage.getItem('anybrowser-fixture')")
            XCTAssertEqual(firstStored as? String, "profile-one")

            var conflict = try store.makeDraft()
            conflict.port = first.port
            do {
                try await runtime.start(conflict)
                XCTFail("A second instance unexpectedly started on an occupied port")
                try await runtime.stop(conflict.id)
            } catch {
                XCTAssertEqual(runtime.status(for: first.id), .running(pid: pids[0], port: first.port, debugReady: true))
            }

            try await runtime.stop(first.id)
            XCTAssertEqual(runtime.status(for: first.id), .stopped)
            XCTAssertEqual(runtime.status(for: second.id), .running(pid: pids[1], port: second.port, debugReady: true))
            try await runtime.start(first)
            let reopened = try await DevToolsPage.open(port: first.port, url: page.url)
            defer { reopened.socket.cancel(with: .normalClosure, reason: nil) }
            try await assertPage(reopened, platform: "macOS", cores: 8, timezone: "UTC")
            let reopenedValue = try await reopened.evaluate("localStorage.getItem('anybrowser-fixture')")
            XCTAssertEqual(reopenedValue as? String, "profile-one")

            try await runtime.stop(first.id)
            try await runtime.stop(second.id)
        } catch {
            try? await runtime.stop(first.id)
            try? await runtime.stop(second.id)
            throw error
        }
    }

    private func assertPage(_ page: DevToolsPage, platform: String, cores: Int, timezone: String) async throws {
        let observed = try await page.evaluate(
            "({platform:navigator.userAgentData.platform, cores:navigator.hardwareConcurrency, zone:Intl.DateTimeFormat().resolvedOptions().timeZone})"
        )
        let fields = try XCTUnwrap(observed as? [String: Any])
        XCTAssertEqual(fields["platform"] as? String, platform)
        XCTAssertEqual(fields["cores"] as? Int, cores)
        XCTAssertEqual(fields["zone"] as? String, timezone)
    }
}

private enum VerificationFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}

private struct LoopbackPage {
    var listener: NWListener
    var url: URL

    static func start() async throws -> LoopbackPage {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "anybrowser.smoke.loopback")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in
                let body = "<!doctype html><meta charset=utf-8><title>AnyBrowser local test</title>"
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

private final class DevToolsPage {
    let socket: URLSessionWebSocketTask
    private var nextID = 0

    private init(socket: URLSessionWebSocketTask) {
        self.socket = socket
    }

    static func open(port: Int, url: URL) async throws -> DevToolsPage {
        let local = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/json/list"))
        let (data, _) = try await URLSession.shared.data(from: local)
        let targets = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        let endpoint = try XCTUnwrap(targets.first { $0["type"] == "page" }?["webSocketDebuggerUrl"])
        let socketURL = try XCTUnwrap(URL(string: endpoint))
        guard socketURL.scheme == "ws", socketURL.host == "127.0.0.1", socketURL.port == port else {
            throw VerificationFailure.message("Unexpected session endpoint")
        }
        let task = URLSession.shared.webSocketTask(with: socketURL)
        task.resume()
        let page = DevToolsPage(socket: task)
        do {
            _ = try await page.command("Page.navigate", ["url": url.absoluteString])
            for _ in 0..<50 {
                if let location = try? await page.evaluate("document.readyState === 'complete' && location.href"),
                   (location as? String) == url.absoluteString {
                    return page
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw VerificationFailure.message("Timed out waiting for the local page")
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            throw error
        }
    }

    func evaluate(_ expression: String) async throws -> Any {
        let response = try await command("Runtime.evaluate", ["expression": expression, "returnByValue": true])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
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
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            if value["id"] as? Int == commandID {
                if let error = value["error"] {
                    throw VerificationFailure.message("DevTools \(name) failed: \(error)")
                }
                return try XCTUnwrap(value["result"] as? [String: Any])
            }
        }
    }
}
