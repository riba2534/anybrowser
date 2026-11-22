@testable import AnyBrowserCore
import Foundation
import Network
import Testing

// Shared by the engine suites that send a browser through the relay.

/// The page origin, a WebSocket echo origin, and the route the upstream stubs take to them.
struct RelaySites {
    let page: OriginStub
    let socket: NWListener
    let route: @Sendable (String) -> Int?

    static func start() async throws -> RelaySites {
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
        return RelaySites(page: page, socket: socket) { host in
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

/// Checks that a running browser's contexts reach the test sites.
enum BrowserContexts {
    /// A page load (forwarded request) and a WebSocket (CONNECT tunnel) in the default context and in
    /// one made with Target.createBrowserContext, the context Playwright's newContext() uses.
    static func expectWorking(port: Int, endpoint: URL, label: String) async throws {
        let page = try await DevToolsPage.open(port: port, url: try #require(URL(string: "http://page.anybrowser.test/default-\(label)")))
        defer { page.socket.cancel(with: .normalClosure, reason: nil) }
        #expect(try await page.evaluate("document.title") as? String == "origin page.anybrowser.test")
        #expect(try await page.evaluate(webSocketEcho("default-\(label)"), awaitPromise: true) as? String == "default-\(label)")

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
        #expect(try await evaluate(client, session, webSocketEcho("context-\(label)"), awaitPromise: true) as? String
            == "context-\(label)")
        _ = try await client.send("Target.disposeBrowserContext", ["browserContextId": context])
    }

    static func openTarget(_ client: DevToolsClient, context: String) async throws -> String {
        let target = try #require(try await client.send("Target.createTarget", ["url": "about:blank", "browserContextId": context])["targetId"] as? String)
        return try #require(try await client.send("Target.attachToTarget", ["targetId": target, "flatten": true])["sessionId"] as? String)
    }

    static func evaluate(_ client: DevToolsClient, _ session: String, _ expression: String,
                         awaitPromise: Bool = false) async throws -> Any? {
        let reply = try await client.send("Runtime.evaluate", ["expression": expression, "returnByValue": true,
                                                               "awaitPromise": awaitPromise], sessionId: session)
        return (reply["result"] as? [String: Any])?["value"]
    }

    /// Browsers tunnel ws:// through an HTTP proxy with CONNECT, so this exercises the tunnel path.
    static func webSocketEcho(_ message: String) -> String {
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
