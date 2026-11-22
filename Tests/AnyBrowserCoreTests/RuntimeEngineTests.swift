@testable import AnyBrowserCore
import Foundation
import Network
import Testing

/// A loopback server that counts requests per path. `/asset.js` may be cached for a day;
/// `/slow` answers after `delay`.
private final class CountingServer: @unchecked Sendable {
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
        let queue = DispatchQueue(label: "anybrowser.runtime.counting")
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
                default: ("Content-Type: text/html\r\nCache-Control: no-store", "<!doctype html><title>AnyBrowser runtime \(path)</title>")
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

// Debug ports 9320–9324 belong to this suite.
@Suite(.serialized)
@MainActor
struct RuntimeEngineTests {
    private func prepare(_ label: String) throws -> (BrowserRuntime, URL) {
        let root = try scratchDirectory(label)
        return (BrowserRuntime(engine: try testEngine(), storage: root.appendingPathComponent("Storage", isDirectory: true)), root)
    }

    @Test(
        "The tab -AppleLanguages opens is replaced by the start pages, which are not engine arguments",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test.")
    )
    func placeholderBecomesStartPage() async throws {
        let (runtime, root) = try prepare("runtime-placeholder")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await CountingServer.start()
        defer { server.listener.cancel() }
        runtime.additionalArguments = ["-AppleLanguages", "(de-DE)"]
        var profile = BrowserProfile(name: "Placeholder Probe", port: testPort(9320), fingerprint: FingerprintSettings(seed: 9320), proxy: "")
        profile.launch.startURLs = [server.url("/one"), server.url("/two")]
        let outcome = try await runtime.start(profile)
        do {
            #expect(outcome.warnings == [])
            guard case let .running(pid, _, true) = runtime.status(for: profile.id) else {
                throw VerificationFailure.message("Not running: \(runtime.status(for: profile.id))")
            }
            let arguments = try #require(ProcessInspection.arguments(pid))
            #expect(!arguments.contains(server.url("/one")))
            #expect(arguments.contains("(de-DE)"))
            #expect(arguments.contains("--window-name=Placeholder Probe"))
            let opened = try await DevToolsPage.waitForTargets(port: profile.port) { targets in
                let urls = targets.filter { $0["type"] as? String == "page" }.compactMap { $0["url"] as? String }
                return Set(urls) == [server.url("/one"), server.url("/two")]
            }
            #expect(!opened.contains(where: BrowserRuntime.isPlaceholder))
            #expect(server.requests("/one") == 1)
            try await runtime.stop(profile.id)
        } catch {
            try? await runtime.stop(profile.id, force: true)
            throw error
        }
    }

    @Test(
        "Without start pages the -AppleLanguages tab shows the new tab page",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test.")
    )
    func placeholderBecomesNewTab() async throws {
        let (runtime, root) = try prepare("runtime-newtab")
        defer { try? FileManager.default.removeItem(at: root) }
        runtime.additionalArguments = ["-AppleLanguages", "(de-DE)", "(fr-FR)"]
        let profile = BrowserProfile(name: "New tab", port: testPort(9321), fingerprint: FingerprintSettings(seed: 9321), proxy: "")
        let outcome = try await runtime.start(profile)
        do {
            #expect(outcome.warnings == [])
            try await DevToolsPage.waitForTargets(port: profile.port) { targets in
                targets.filter { $0["type"] as? String == "page" }.compactMap { $0["url"] as? String } == ["chrome://newtab/"]
            }
            try await runtime.stop(profile.id)
        } catch {
            try? await runtime.stop(profile.id, force: true)
            throw error
        }
    }

    @Test(
        "With -AppleLanguages as a plist array each start page opens once, in the new tab page and beside it",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test.")
    )
    func plistLanguagesOpenNoExtraTab() async throws {
        let (runtime, root) = try prepare("runtime-plist-languages")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await CountingServer.start()
        defer { server.listener.cancel() }
        // Chromium drops the value as an invalid URL and opens its new tab page as usual.
        runtime.additionalArguments = ["-AppleLanguages", "<array><string>de-DE</string></array>"]
        var profile = BrowserProfile(name: "Languages", port: testPort(9320), fingerprint: FingerprintSettings(seed: 9320), proxy: "")
        profile.launch.startURLs = [server.url("/one"), server.url("/two")]
        let plain = BrowserProfile(name: "Languages, no pages", port: testPort(9321), fingerprint: FingerprintSettings(seed: 9321),
                                   proxy: "")
        do {
            let outcome = try await runtime.start(profile)
            #expect(outcome.warnings == [])
            try await runtime.start(plain)
            let opened = try await DevToolsPage.waitForTargets(port: profile.port) { targets in
                let urls = targets.filter { $0["type"] as? String == "page" }.compactMap { $0["url"] as? String }
                return Set(urls) == [server.url("/one"), server.url("/two")]
            }
            #expect(opened.filter { $0["type"] as? String == "page" }.count == 2)
            #expect(server.requests("/one") == 1 && server.requests("/two") == 1)
            try await DevToolsPage.waitForTargets(port: plain.port) { targets in
                targets.filter { $0["type"] as? String == "page" }.compactMap { $0["url"] as? String } == ["chrome://newtab/"]
            }
            try await runtime.stop(profile.id)
            try await runtime.stop(plain.id)
        } catch {
            try? await runtime.stop(profile.id, force: true)
            try? await runtime.stop(plain.id, force: true)
            throw error
        }
    }

    @Test(
        "Clearing a running Profile removes domain-wide and partitioned cookies and the HTTP cache",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test.")
    )
    func runningClearIsComplete() async throws {
        let (runtime, root) = try prepare("runtime-clear")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await CountingServer.start()
        defer { server.listener.cancel() }
        var profile = BrowserProfile(name: "Clear", port: testPort(9322), fingerprint: FingerprintSettings(seed: 9322), proxy: "")
        profile.launch.startURLs = [server.url("/page")]
        try await runtime.start(profile)
        do {
            let endpoint = try #require(await runtime.devToolsEndpoint(for: profile.id))
            let browser = try DevToolsClient(endpoint: endpoint)
            defer { browser.close() }
            func cookie(_ name: String, _ domain: String, _ extra: [String: Any] = [:]) -> [String: Any] {
                ["name": name, "value": "1", "domain": domain, "path": "/", "secure": true].merging(extra) { $1 }
            }
            _ = try await browser.send("Storage.setCookies", ["cookies": [
                cookie("dom", ".stripe.com"),
                cookie("m", ".m.stripe.com", ["httpOnly": true]),
                cookie("hostm", "m.stripe.com"),
                cookie("lsid", ".link.com"),
                cookie("chips", ".stripe.com", ["sameSite": "None",
                                                "partitionKey": ["topLevelSite": "https://shop.example", "hasCrossSiteAncestor": true]]),
                cookie("__stripe_mid", ".shop.example"),
                cookie("keep", ".example.com"),
            ]])
            // The start page loads a script the HTTP cache may keep for a day.
            let page = try await DevToolsPage.open(port: profile.port, url: try #require(URL(string: server.url("/page"))))
            defer { page.socket.cancel(with: .normalClosure, reason: nil) }
            for _ in 0..<2 {
                _ = try await page.evaluate("fetch('/asset.js').then(r => r.text())", awaitPromise: true)
            }
            #expect(server.requests("/asset.js") == 1)

            try await runtime.clearSiteData(for: profile.id)
            let left = try await browser.send("Storage.getCookies")["cookies"] as? [[String: Any]] ?? []
            #expect(left.compactMap { $0["name"] as? String } == ["keep"])
            _ = try await page.evaluate("fetch('/asset.js').then(r => r.text())", awaitPromise: true)
            #expect(server.requests("/asset.js") == 2)
            try await runtime.stop(profile.id)
        } catch {
            try? await runtime.stop(profile.id, force: true)
            throw error
        }
    }

    @Test(
        "A start page still loading when the budget runs out keeps loading without a warning",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test.")
    )
    func slowStartPage() async throws {
        let (runtime, root) = try prepare("runtime-slow")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await CountingServer.start(delay: 3)
        defer { server.listener.cancel() }
        runtime.startPageBudget = 1
        var profile = BrowserProfile(name: "Slow", port: testPort(9323), fingerprint: FingerprintSettings(seed: 9323), proxy: "")
        profile.launch.startURLs = [server.url("/slow"), server.url("/two")]
        let began = Date()
        let outcome = try await runtime.start(profile)
        do {
            #expect(outcome.warnings == [])
            #expect(Date().timeIntervalSince(began) < 3)
            try await DevToolsPage.waitForTargets(port: profile.port) { targets in
                targets.contains { $0["url"] as? String == server.url("/slow") && $0["title"] as? String == "AnyBrowser runtime /slow" }
                    && targets.contains { $0["url"] as? String == server.url("/two") }
            }
            try await runtime.stop(profile.id)
        } catch {
            try? await runtime.stop(profile.id, force: true)
            throw error
        }
    }

    @Test(
        "A browser restarted from its settings page is adopted again and can be stopped",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test.")
    )
    func restartFromSettings() async throws {
        let (runtime, root) = try prepare("runtime-restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = BrowserProfile(name: "Restart", port: testPort(9324), fingerprint: FingerprintSettings(seed: 9324), proxy: "")
        try await runtime.start(profile)
        var relaunched: Int32?
        do {
            guard case let .running(first, _, true) = runtime.status(for: profile.id) else {
                throw VerificationFailure.message("Not running: \(runtime.status(for: profile.id))")
            }
            let settings = try #require(URL(string: "chrome://settings/"))
            let page = try await DevToolsPage.open(port: profile.port, url: settings)
            // The settings page's own restart, as after changing the UI language; chrome://restart does the same.
            _ = try? await page.evaluate("setTimeout(() => chrome.send('restart'), 100); true")
            page.socket.cancel(with: .normalClosure, reason: nil)
            for _ in 0..<100 {
                await runtime.refresh([profile])
                if case let .running(pid, _, true) = runtime.status(for: profile.id), pid != first {
                    relaunched = pid
                    break
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            let pid = try #require(relaunched)
            // Chromium rebuilds the arguments, so the browser no longer runs the saved configuration.
            #expect(ProcessInspection.arguments(pid)?.last == "--restart")
            #expect(runtime.matchesRunningConfiguration(profile) == false)
            try await runtime.stop(profile.id)
            #expect(runtime.status(for: profile.id) == .stopped)
            #expect(ProcessStamp.read(pid) == nil)
        } catch {
            try? await runtime.stop(profile.id, force: true)
            // A relaunched browser that was not adopted still holds this test's data directory.
            let directory = runtime.dataDirectory(for: profile.id)
            let lock = try? FileManager.default.destinationOfSymbolicLink(atPath: directory.appendingPathComponent("SingletonLock").path)
            if let holder = relaunched ?? lock.flatMap({ $0.split(separator: "-").last.flatMap { Int32($0) } }),
               ProcessInspection.arguments(holder)?.contains("--user-data-dir=\(directory.path)") == true {
                kill(holder, SIGKILL)
            }
            throw error
        }
    }
}
