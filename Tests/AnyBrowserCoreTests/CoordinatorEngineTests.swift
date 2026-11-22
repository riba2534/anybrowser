@testable import AnyBrowserCore
import Foundation
import Network
import Testing

/// A loopback page whose `/asset.js` the HTTP cache may keep for a day, counting requests per path.
private final class AssetServer: @unchecked Sendable {
    let listener: NWListener
    let base: URL
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    private init(listener: NWListener, base: URL) {
        self.listener = listener
        self.base = base
    }

    static func start() async throws -> AssetServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "anybrowser.coordinator.assets")
        var server: AssetServer?
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                server?.count(path)
                let (headers, body) = path == "/asset.js"
                    ? ("Content-Type: text/javascript\r\nCache-Control: public, max-age=86400", "window.loaded = 1;")
                    : ("Content-Type: text/html\r\nCache-Control: no-store", "<!doctype html><title>AnyBrowser coordinator</title>")
                let response = Data("HTTP/1.1 200 OK\r\n\(headers)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port = try await listener.startAndWait(on: queue)
        let created = AssetServer(listener: listener, base: try #require(URL(string: "http://127.0.0.1:\(port)/")))
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

    var page: URL { base.appendingPathComponent("page") }
}

// Debug ports 9370–9379 belong to this suite.
@Suite(.serialized)
@MainActor
struct CoordinatorEngineTests {
    /// A real browser on a scratch data directory. Chromium only moves the caches to ~/Library/Caches
    /// for a directory in the real Application Support, so here they stay in the data directory;
    /// the stand-in folders keep the runtime away from the real ones. The mock keychain lets cookies
    /// written by one launch be read by the next from a test process.
    @MainActor
    private struct Fixture {
        let root: URL
        let store: ProfileStore
        let runtime: BrowserRuntime
        let coordinator: LaunchCoordinator

        init(_ label: String) throws {
            root = try scratchDirectory(label)
            let support = root.appendingPathComponent("Application Support", isDirectory: true)
            let caches = root.appendingPathComponent("Caches", isDirectory: true)
            let storage = support.appendingPathComponent("AnyBrowser", isDirectory: true)
            for directory in [support, caches, storage] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            store = try ProfileStore(directory: storage)
            runtime = BrowserRuntime(engine: try testEngine(), storage: storage, applicationSupport: support, caches: caches)
            runtime.additionalArguments = ["--use-mock-keychain"]
            coordinator = LaunchCoordinator(store: store, runtime: runtime)
        }
    }

    private static let identityCookies = ["dom", "m", "hostm", "lsid", "chips", "__stripe_mid"]

    /// Sets lasting cookies of a payment site's device identity, plus one of an unrelated site,
    /// and loads the cacheable asset twice.
    private func browse(_ fixture: Fixture, _ profile: BrowserProfile, _ server: AssetServer) async throws {
        let endpoint = try #require(await fixture.runtime.devToolsEndpoint(for: profile.id))
        let browser = try DevToolsClient(endpoint: endpoint)
        defer { browser.close() }
        let expires = Date().addingTimeInterval(86400).timeIntervalSince1970
        func cookie(_ name: String, _ domain: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["name": name, "value": "1", "domain": domain, "path": "/", "secure": true, "expires": expires].merging(extra) { $1 }
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
        try await fetchAsset(fixture, profile, server)
        try await fetchAsset(fixture, profile, server)
    }

    private func cookieNames(_ fixture: Fixture, _ profile: BrowserProfile) async throws -> Set<String> {
        let endpoint = try #require(await fixture.runtime.devToolsEndpoint(for: profile.id))
        let browser = try DevToolsClient(endpoint: endpoint)
        defer { browser.close() }
        let cookies = try await browser.send("Storage.getCookies")["cookies"] as? [[String: Any]] ?? []
        return Set(cookies.compactMap { $0["name"] as? String })
    }

    private func fetchAsset(_ fixture: Fixture, _ profile: BrowserProfile, _ server: AssetServer) async throws {
        let page = try await DevToolsPage.open(port: profile.port, url: server.page)
        defer { page.socket.cancel(with: .normalClosure, reason: nil) }
        _ = try await page.evaluate("fetch('/asset.js').then(r => r.text())", awaitPromise: true)
    }

    private func seedArgument(_ fixture: Fixture, _ profile: BrowserProfile) -> String? {
        guard case let .running(pid, _, _) = fixture.runtime.status(for: profile.id) else { return nil }
        return ProcessInspection.arguments(pid)?.first { $0.hasPrefix("--fingerprint=") }
    }

    @Test(
        "A stopped Profile's saved new identity loses every site's cookies and cache; a discarded one loses nothing",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test.")
    )
    func stoppedRegeneration() async throws {
        let fixture = try Fixture("coordinator-engine-stopped")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let server = try await AssetServer.start()
        defer { server.listener.cancel() }
        var draft = try fixture.store.makeDraft()
        draft.port = testPort(9370)
        draft.proxy = ""
        draft.launch.startURLs = [server.page.absoluteString]
        try fixture.store.save(draft)
        let profile = try #require(fixture.store.profiles.first)
        let coordinator = fixture.coordinator
        do {
            try await coordinator.start(profile.id)
            try await browse(fixture, profile, server)
            #expect(server.requests("/asset.js") == 1)
            try await coordinator.stop(profile.id)

            // Generated, then discarded: nothing changes.
            _ = try await coordinator.generateIdentity(for: profile)
            try await coordinator.start(profile.id)
            #expect(try await cookieNames(fixture, profile).isSuperset(of: Self.identityCookies + ["keep"]))
            try await fetchAsset(fixture, profile, server)
            #expect(server.requests("/asset.js") == 1)
            try await coordinator.stop(profile.id)

            // Generated and saved: cleared at once.
            var renewed = profile
            renewed.fingerprint = try await coordinator.generateIdentity(for: profile).fingerprint
            try coordinator.saveNewIdentity(renewed)
            #expect(try await coordinator.clearPendingSiteData(profile.id))
            #expect(!fixture.store.pendingIdentityReset(profile.id))
            try await coordinator.start(profile.id)
            #expect(seedArgument(fixture, profile) == "--fingerprint=\(renewed.fingerprint.seed)")
            #expect(try await cookieNames(fixture, profile).isEmpty)
            try await fetchAsset(fixture, profile, server)
            #expect(server.requests("/asset.js") == 2)
            try await coordinator.stop(profile.id)
        } catch {
            try? await fixture.runtime.stop(profile.id, force: true)
            throw error
        }
    }

    @Test(
        "A running Profile's saved new identity is applied by the restart, which clears the same data",
        .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test.")
    )
    func runningRegeneration() async throws {
        let fixture = try Fixture("coordinator-engine-running")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let server = try await AssetServer.start()
        defer { server.listener.cancel() }
        var draft = try fixture.store.makeDraft()
        draft.port = testPort(9371)
        draft.proxy = ""
        draft.launch.startURLs = [server.page.absoluteString]
        try fixture.store.save(draft)
        let profile = try #require(fixture.store.profiles.first)
        let coordinator = fixture.coordinator
        do {
            try await coordinator.start(profile.id)
            try await browse(fixture, profile, server)
            #expect(server.requests("/asset.js") == 1)

            var renewed = profile
            renewed.fingerprint = try await coordinator.generateIdentity(for: profile).fingerprint
            try coordinator.saveNewIdentity(renewed)
            #expect(try await coordinator.clearPendingSiteData(profile.id) == false)
            // Nothing is cleared under the old identity's open pages.
            #expect(try await cookieNames(fixture, profile).isSuperset(of: Self.identityCookies))
            #expect(coordinator.hasPendingRestart(profile.id))

            try await coordinator.restart(profile.id)
            #expect(!fixture.store.pendingIdentityReset(profile.id))
            #expect(!coordinator.hasPendingRestart(profile.id))
            #expect(seedArgument(fixture, profile) == "--fingerprint=\(renewed.fingerprint.seed)")
            #expect(try await cookieNames(fixture, profile).isEmpty)
            try await fetchAsset(fixture, profile, server)
            #expect(server.requests("/asset.js") == 2)
            try await coordinator.stop(profile.id)
        } catch {
            try? await fixture.runtime.stop(profile.id, force: true)
            throw error
        }
    }
}
