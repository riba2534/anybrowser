@testable import AnyBrowserCore
import Foundation
import Testing

// Debug port 9303 belongs to this suite; its tests take turns on it.
@Suite(.serialized)
struct ProxyEngineTests {
    @Test(
        "A Profile's proxy with a password works in every context, incognito windows included, through its relay",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the proxy tests.")
    )
    @MainActor
    func relaysEveryContext() async throws {
        let sites = try await RelaySites.start()
        defer { sites.stop() }
        let upstream = try UpstreamHTTPStub(credentials: "relay-user:relay:pass", route: sites.route)
        defer { upstream.stop() }
        let launch = try ProxiedLaunch("proxy-engine-http", proxy: "http://relay-user:relay%3Apass@127.0.0.1:\(upstream.port)")
        defer { launch.remove() }

        try await launch.run { runtime, profile in
            let (port, endpoint) = try await launch.checkArguments(runtime, hiding: ["relay-user", "relay%3Apass", ":\(upstream.port)"])
            try await BrowserContexts.expectWorking(port: port, endpoint: endpoint, label: "http")
            #expect(upstream.requests.contains { $0.method == "GET" && $0.target == "http://page.anybrowser.test/context-http" })
            #expect(upstream.requests.contains { $0.method == "CONNECT" && $0.target == "ws.anybrowser.test:80" })
            #expect(upstream.requests.allSatisfy { $0.authorization == upstream.signIn }, "\(upstream.requests.map(\.target))")
            try await runtime.stop(profile.id)

            // An incognito window is a context of its own; the relay serves it like any other.
            try await runtime.start(profile, overrides: LaunchOverrides(arguments: ["--incognito"]))
            let (incognitoPort, incognitoEndpoint) = try await launch.checkArguments(runtime, hiding: ["relay-user"])
            let page = try await DevToolsPage.open(port: incognitoPort, url: try #require(URL(string: "http://page.anybrowser.test/incognito")))
            defer { page.socket.cancel(with: .normalClosure, reason: nil) }
            #expect(try await page.evaluate("document.title") as? String == "origin page.anybrowser.test")
            #expect(try await page.evaluate(BrowserContexts.webSocketEcho("incognito"), awaitPromise: true) as? String == "incognito")
            let client = try DevToolsClient(endpoint: incognitoEndpoint)
            defer { client.close() }
            let regular = try #require(try await client.send("Target.createTarget", ["url": "about:blank"])["targetId"] as? String)
            let pages = (try await client.send("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "page" }
            let incognito = pages.first { ($0["url"] as? String)?.hasSuffix("/incognito") == true }?["browserContextId"] as? String
            let ordinary = pages.first { $0["targetId"] as? String == regular }?["browserContextId"] as? String
            #expect(incognito != nil && ordinary != nil && incognito != ordinary)
            #expect(upstream.requests.contains { $0.target == "http://page.anybrowser.test/incognito" && $0.authorization == upstream.signIn })
        }
    }

    @Test(
        "A SOCKS5 proxy with a password works through the Profile's relay, which hands host names to the proxy",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the proxy tests.")
    )
    @MainActor
    func relaysSOCKS() async throws {
        let sites = try await RelaySites.start()
        defer { sites.stop() }
        let upstream = try UpstreamSOCKSStub(username: "socks-user", password: "p@ss", route: sites.route)
        defer { upstream.stop() }
        let launch = try ProxiedLaunch("proxy-engine-socks", proxy: "socks5://socks-user:p%40ss@127.0.0.1:\(upstream.port)")
        defer { launch.remove() }

        try await launch.run { runtime, _ in
            let (port, endpoint) = try await launch.checkArguments(runtime, hiding: ["socks-user", "p%40ss", ":\(upstream.port)"])
            try await BrowserContexts.expectWorking(port: port, endpoint: endpoint, label: "socks")
            let reached = upstream.requests.filter { $0.host.hasSuffix(".anybrowser.test") }
            #expect(Set(reached.map(\.host)) == ["page.anybrowser.test", "ws.anybrowser.test"])
            #expect(reached.allSatisfy { $0.addressType == 3 && $0.username == "socks-user" && $0.password == "p@ss" })
        }
    }

    @Test(
        "After AnyBrowser restarts, the browser still goes through its relay and is not waiting for a restart",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the proxy tests.")
    )
    @MainActor
    func keepsTheRelayAcrossRestarts() async throws {
        let sites = try await RelaySites.start()
        defer { sites.stop() }
        let upstream = try UpstreamHTTPStub(credentials: "user:pass", route: sites.route)
        defer { upstream.stop() }
        let launch = try ProxiedLaunch("proxy-engine-restart", proxy: "http://user:pass@127.0.0.1:\(upstream.port)")
        defer { launch.remove() }

        var first: BrowserRuntime? = BrowserRuntime(engine: launch.engine, storage: launch.store.directory)
        try await first?.start(launch.profile)
        guard case let .running(pid, _, true)? = first?.status(for: launch.profile.id) else {
            throw VerificationFailure.message("CDP 未就绪：\(String(describing: first?.status(for: launch.profile.id)))")
        }
        let relay = try #require(launch.relay(of: pid)).pid
        // The app quits: its runtime goes away, the browser and the relay stay.
        first = nil
        let restored = BrowserRuntime(engine: launch.engine, storage: launch.store.directory)
        do {
            await restored.refresh([launch.profile])
            #expect(restored.status(for: launch.profile.id) == .running(pid: pid, port: launch.profile.port, debugReady: true),
                    "\(String(describing: ProcessInspection.image(pid)?.executablePath)) \(String(describing: ProcessInspection.executable(pid))) \(launch.engine.executable.path)")
            #expect(restored.matchesRunningConfiguration(launch.profile) == true)
            #expect(isAlive(relay))
            let endpoint = try #require(await restored.devToolsEndpoint(for: launch.profile.id))
            try await BrowserContexts.expectWorking(port: launch.profile.port, endpoint: endpoint, label: "restored")
            #expect(upstream.requests.contains { $0.target == "http://page.anybrowser.test/context-restored" })
            try await restored.stop(launch.profile.id)
            #expect(!isAlive(pid) && !isAlive(relay))
        } catch {
            try? await restored.stop(launch.profile.id, force: true)
            throw error
        }
    }
}

/// A Profile in a scratch store whose proxy goes through the packaged app's relay helper.
@MainActor
private struct ProxiedLaunch {
    let directory: URL
    let store: ProfileStore
    let engine: BrowserEngine
    let profile: BrowserProfile

    init(_ label: String, proxy: String) throws {
        var engine = try testEngine()
        guard engine.relayExecutable != nil else {
            throw VerificationFailure.message("The packaged app has no \(RelayHelper.executableName)")
        }
        // The helper built from this checkout, which a packaged app made earlier may not carry yet.
        if let built = relayHelperPath { engine.relayExecutable = URL(fileURLWithPath: built) }
        self.engine = engine
        directory = try scratchDirectory(label)
        store = try ProfileStore(directory: directory)
        var profile = try store.makeDraft()
        profile.port = testPort(9303)
        profile.proxy = proxy
        try store.save(profile)
        self.profile = profile
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Starts the Profile, runs `body`, and stops it whatever happens.
    func run(_ body: (BrowserRuntime, BrowserProfile) async throws -> Void) async throws {
        let runtime = BrowserRuntime(engine: engine, storage: store.directory)
        try await runtime.start(profile)
        do {
            try await body(runtime, profile)
            try await runtime.stop(profile.id)
        } catch {
            try? await runtime.stop(profile.id, force: true)
            throw error
        }
        let relays = (try? FileManager.default.contentsOfDirectory(atPath: runtime.dataDirectory(for: profile.id).path)) ?? []
        #expect(!relays.contains(RelayHelper.portFileName))
    }

    /// The browser goes through its relay on 127.0.0.1, and none of `secrets` is in its arguments
    /// or the relay's.
    func checkArguments(_ runtime: BrowserRuntime, hiding secrets: [String]) async throws -> (port: Int, endpoint: URL) {
        guard case let .running(pid, port, true) = runtime.status(for: profile.id) else {
            throw VerificationFailure.message("CDP 未就绪：\(runtime.status(for: profile.id))")
        }
        let arguments = try #require(ProcessInspection.arguments(pid))
        let relay = try #require(relay(of: pid))
        let relayArguments = try #require(ProcessInspection.arguments(relay.pid))
        #expect(arguments.contains("--proxy-server=http://127.0.0.1:\(relay.port)"))
        #expect(!arguments.contains { $0.contains("ProxyAuth") })
        for secret in secrets {
            #expect(!arguments.contains { $0.contains(secret) }, "\(secret)")
            #expect(!relayArguments.contains { $0.contains(secret) }, "\(secret)")
        }
        return (port, try #require(await runtime.devToolsEndpoint(for: profile.id)))
    }

    /// The relay helper the browser's receipt names.
    func relay(of pid: Int32) -> RelayReceipt? {
        let directory = store.directory.appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".anybrowser-runtime.json")),
              let receipt = try? JSONDecoder().decode(BrowserRuntime.Receipt.self, from: data), receipt.pid == pid else { return nil }
        return receipt.relay
    }
}
