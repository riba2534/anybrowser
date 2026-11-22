@testable import AnyBrowserCore
import Foundation
import Network
import Testing

// Debug ports 9330 and 9331 belong to this suite.
@Suite(.serialized)
struct RelayEngineTests {
    @Test(
        "Every browser context reaches the web through a relay to a proxy that requires sign-in",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the relay test.")
    )
    @MainActor
    func signsInForEveryContext() async throws {
        let sites = try await RelaySites.start()
        defer { sites.stop() }
        let upstream = try UpstreamHTTPStub(credentials: "relay-user:relay-pass", route: sites.route)
        defer { upstream.stop() }
        let relay = try ProxyRelay(upstream: try #require(try ProxyEndpoint.parse("http://relay-user:relay-pass@127.0.0.1:\(upstream.port)")))
        try await relay.start()
        defer { relay.stop() }
        // A second relay with the wrong password, for a context of its own.
        let rejected = try ProxyRelay(upstream: try #require(try ProxyEndpoint.parse("http://relay-user:wrong@127.0.0.1:\(upstream.port)")))
        try await rejected.start()
        defer { rejected.stop() }

        try await withBrowser(proxy: try #require(relay.server), port: testPort(9330)) { port, endpoint in
            try await BrowserContexts.expectWorking(port: port, endpoint: endpoint, label: "http")
            #expect(!upstream.requests.isEmpty)
            #expect(upstream.requests.allSatisfy { $0.authorization == upstream.signIn }, "\(upstream.requests.map(\.target))")
            #expect(upstream.requests.contains { $0.method == "GET" && $0.target == "http://page.anybrowser.test/context-http" })
            #expect(upstream.requests.contains { $0.method == "CONNECT" && $0.target == "ws.anybrowser.test:80" })

            // A context with its own proxy (what Playwright's newContext({proxy}) does) shows why it
            // failed instead of a sign-in dialog that could only reach the relay, and tunnels fail at once.
            let client = try DevToolsClient(endpoint: endpoint)
            defer { client.close() }
            let proxyServer = try #require(rejected.server)
            let context = try #require(try await client.send("Target.createBrowserContext",
                                                             ["proxyServer": proxyServer])["browserContextId"] as? String)
            let session = try await BrowserContexts.openTarget(client, context: context)
            _ = try await client.send("Page.navigate", ["url": "http://page.anybrowser.test/rejected"], sessionId: session)
            var text = ""
            for _ in 0..<50 where text.isEmpty {
                try await Task.sleep(nanoseconds: 100_000_000)
                text = try await BrowserContexts.evaluate(client, session, "document.readyState === 'complete' ? document.body.innerText : ''")
                    as? String ?? ""
            }
            #expect(text.contains(ProxyRelay.Failure.credentialsRejected.message), "\(text)")
            #expect(try await BrowserContexts.evaluate(client, session, BrowserContexts.webSocketEcho("rejected"), awaitPromise: true) as? String == "error")
            #expect(rejected.lastFailure == .credentialsRejected)
            _ = try await client.send("Target.disposeBrowserContext", ["browserContextId": context])
        }
    }

    @Test(
        "A SOCKS5 proxy with a password works through the relay, with names resolved by the proxy",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the relay test.")
    )
    @MainActor
    func signsInToSOCKS() async throws {
        let sites = try await RelaySites.start()
        defer { sites.stop() }
        let upstream = try UpstreamSOCKSStub(username: "socks-user", password: "socks:pass", route: sites.route)
        defer { upstream.stop() }
        let relay = try ProxyRelay(upstream: try #require(
            try ProxyEndpoint.parse("socks5h://socks-user:socks%3Apass@127.0.0.1:\(upstream.port)", allowingSOCKSCredentials: true)))
        try await relay.start()
        defer { relay.stop() }

        try await withBrowser(proxy: try #require(relay.server), port: testPort(9331)) { port, endpoint in
            try await BrowserContexts.expectWorking(port: port, endpoint: endpoint, label: "socks")
            let reached = upstream.requests.filter { $0.host.hasSuffix(".anybrowser.test") }
            #expect(!reached.isEmpty)
            #expect(reached.allSatisfy { $0.addressType == 3 && $0.username == "socks-user" && $0.password == "socks:pass" })
            #expect(Set(reached.map(\.host)) == ["page.anybrowser.test", "ws.anybrowser.test"])
        }
    }

    /// Starts a Profile whose proxy is `proxy` and hands over its debug port and browser endpoint.
    @MainActor
    private func withBrowser(proxy: String, port: Int, _ body: (Int, URL) async throws -> Void) async throws {
        let engine = try testEngine()
        let directory = try scratchDirectory("relay-engine")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        var profile = try store.makeDraft()
        profile.port = port
        profile.proxy = proxy
        try store.save(profile)
        let runtime = BrowserRuntime(engine: engine, storage: store.directory)
        try await runtime.start(profile)
        do {
            guard case let .running(pid, _, true) = runtime.status(for: profile.id) else {
                throw VerificationFailure.message("CDP 未就绪：\(runtime.status(for: profile.id))")
            }
            let arguments = try #require(ProcessInspection.arguments(pid))
            #expect(arguments.contains("--proxy-server=\(proxy)"))
            // No sign-in extension: the relay itself has no credentials.
            #expect(!arguments.contains { $0.hasPrefix("--load-extension=") && $0.contains("ProxyAuth") })
            try await body(profile.port, try #require(await runtime.devToolsEndpoint(for: profile.id)))
            try await runtime.stop(profile.id)
        } catch {
            try? await runtime.stop(profile.id)
            throw error
        }
    }
}
