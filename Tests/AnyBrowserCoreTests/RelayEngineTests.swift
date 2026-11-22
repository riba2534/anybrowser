@testable import AnyBrowserCore
import Foundation
import Network
import Testing

// Debug ports 9320 and 9321 belong to this suite.
@Suite(.serialized)
struct RelayEngineTests {
    /// The page origin, a WebSocket echo origin, and the route the upstream stubs take to them.
    private struct Sites {
        let page: OriginStub
        let socket: NWListener
        let route: @Sendable (String) -> Int?

        static func start() async throws -> Sites {
            let page = try OriginStub()
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let socket = try NWListener(using: parameters)
            let queue = DispatchQueue(label: "anybrowser.tests.relay-websocket")
            socket.newConnectionHandler = { connection in
                connection.start(queue: queue)
                echo(connection)
            }
            let socketPort = Int(try await socket.startAndWait(on: queue))
            let pagePort = page.port
            return Sites(page: page, socket: socket) { host in
                switch host.split(separator: ":").first {
                case "page.anybrowser.test": return pagePort
                case "ws.anybrowser.test": return socketPort
                default: return nil
                }
            }
        }

        private static func echo(_ connection: NWConnection) {
            connection.receiveMessage { data, context, _, error in
                guard error == nil, let data else { return connection.cancel() }
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let reply = NWConnection.ContentContext(identifier: "echo", metadata: [metadata])
                connection.send(content: data, contentContext: reply, isComplete: true, completion: .idempotent)
                echo(connection)
            }
        }

        func stop() {
            page.stop()
            socket.cancel()
        }
    }

    @Test(
        "Every browser context reaches the web through a relay to a proxy that requires sign-in",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the relay test.")
    )
    @MainActor
    func signsInForEveryContext() async throws {
        let sites = try await Sites.start()
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

        try await withBrowser(proxy: try #require(relay.server), port: testPort(9320)) { port, endpoint in
            try await expectContextsWork(port: port, endpoint: endpoint, label: "http")
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
            let session = try await openTarget(client, context: context)
            _ = try await client.send("Page.navigate", ["url": "http://page.anybrowser.test/rejected"], sessionId: session)
            var text = ""
            for _ in 0..<50 where text.isEmpty {
                try await Task.sleep(nanoseconds: 100_000_000)
                text = try await evaluate(client, session, "document.readyState === 'complete' ? document.body.innerText : ''")
                    as? String ?? ""
            }
            #expect(text.contains(ProxyRelay.Failure.credentialsRejected.message), "\(text)")
            #expect(try await evaluate(client, session, Self.webSocketEcho("rejected"), awaitPromise: true) as? String == "error")
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
        let sites = try await Sites.start()
        defer { sites.stop() }
        let upstream = try UpstreamSOCKSStub(username: "socks-user", password: "socks:pass", route: sites.route)
        defer { upstream.stop() }
        let relay = try ProxyRelay(upstream: try #require(
            try ProxyEndpoint.parse("socks5h://socks-user:socks%3Apass@127.0.0.1:\(upstream.port)", allowingSOCKSCredentials: true)))
        try await relay.start()
        defer { relay.stop() }

        try await withBrowser(proxy: try #require(relay.server), port: testPort(9321)) { port, endpoint in
            try await expectContextsWork(port: port, endpoint: endpoint, label: "socks")
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

    /// A page load (forwarded request) and a WebSocket (CONNECT tunnel) in the default context and in
    /// one made with Target.createBrowserContext, the context Playwright's newContext() uses.
    private func expectContextsWork(port: Int, endpoint: URL, label: String) async throws {
        let page = try await DevToolsPage.open(port: port, url: try #require(URL(string: "http://page.anybrowser.test/default-\(label)")))
        defer { page.socket.cancel(with: .normalClosure, reason: nil) }
        #expect(try await page.evaluate("document.title") as? String == "origin page.anybrowser.test")
        #expect(try await page.evaluate(Self.webSocketEcho("default-\(label)"), awaitPromise: true) as? String == "default-\(label)")

        let client = try DevToolsClient(endpoint: endpoint)
        defer { client.close() }
        let context = try #require(try await client.send("Target.createBrowserContext")["browserContextId"] as? String)
        let session = try await openTarget(client, context: context)
        _ = try await client.send("Page.navigate", ["url": "http://page.anybrowser.test/context-\(label)"], sessionId: session)
        var title = ""
        for _ in 0..<100 where title.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
            title = try await evaluate(client, session, "document.readyState === 'complete' ? document.title : ''") as? String ?? ""
        }
        #expect(title == "origin page.anybrowser.test")
        #expect(try await evaluate(client, session, Self.webSocketEcho("context-\(label)"), awaitPromise: true) as? String
            == "context-\(label)")
        _ = try await client.send("Target.disposeBrowserContext", ["browserContextId": context])
    }

    private func openTarget(_ client: DevToolsClient, context: String) async throws -> String {
        let target = try #require(try await client.send("Target.createTarget", ["url": "about:blank", "browserContextId": context])["targetId"] as? String)
        return try #require(try await client.send("Target.attachToTarget", ["targetId": target, "flatten": true])["sessionId"] as? String)
    }

    private func evaluate(_ client: DevToolsClient, _ session: String, _ expression: String,
                          awaitPromise: Bool = false) async throws -> Any? {
        let reply = try await client.send("Runtime.evaluate", ["expression": expression, "returnByValue": true,
                                                               "awaitPromise": awaitPromise], sessionId: session)
        return (reply["result"] as? [String: Any])?["value"]
    }

    /// Browsers tunnel ws:// through an HTTP proxy with CONNECT, so this exercises the tunnel path.
    private static func webSocketEcho(_ message: String) -> String {
        """
        new Promise((resolve) => {
          const socket = new WebSocket('ws://ws.anybrowser.test/');
          socket.onopen = () => socket.send('\(message)');
          socket.onmessage = (event) => { resolve(String(event.data)); socket.close(); };
          socket.onerror = () => resolve('error');
          setTimeout(() => resolve('timeout'), 8000);
        })
        """
    }
}
