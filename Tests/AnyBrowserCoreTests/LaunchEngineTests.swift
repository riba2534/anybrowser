@testable import AnyBrowserCore
import Foundation
import Testing

// Debugging ports 9302 and 9312 belong to this suite.
@Suite(.serialized)
struct LaunchEngineTests {
    private static let passkeyBoxID = "gfejlnakeokbjdhoionfappnfepjoili"

    @Test(
        "A Profile opens its start page in the configured window with an extra extension",
        .enabled(
            if: testAppPath != nil,
            "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test."
        )
    )
    @MainActor
    func startPageWindowAndExtension() async throws {
        let (engine, root) = try prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try await LoopbackPage.start(title: "AnyBrowser launch options")
        defer { page.listener.cancel() }
        let worker = "anybrowser-launch-test-worker.js"
        let extensionDirectory = root.appendingPathComponent("Extension", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"AnyBrowser launch test","version":"1.0","background":{"service_worker":"\#(worker)"}}"#.utf8)
            .write(to: extensionDirectory.appendingPathComponent("manifest.json"))
        try Data("chrome.runtime.onInstalled.addListener(() => {});".utf8)
            .write(to: extensionDirectory.appendingPathComponent(worker))

        var profile = BrowserProfile(name: "Launch options", port: testPort(9302), fingerprint: FingerprintSettings(seed: 9302), proxy: "")
        profile.launch = LaunchOptions(startURLs: [page.url.absoluteString],
                                       window: WindowLayout(width: 1000, height: 700, x: 60, y: 80),
                                       extensionDirectories: [extensionDirectory.path])
        try profile.launch.checkExtensionDirectories()

        let runtime = BrowserRuntime(engine: engine, storage: root.appendingPathComponent("Storage", isDirectory: true))
        try await runtime.start(profile)
        do {
            // The start page opens over DevTools in the tab Chromium starts with, not from the arguments.
            guard case let .running(pid, _, true) = runtime.status(for: profile.id) else {
                throw VerificationFailure.message("Not running: \(runtime.status(for: profile.id))")
            }
            #expect(ProcessInspection.arguments(pid)?.contains(page.url.absoluteString) == false)
            let opened = try await waitForTarget(port: profile.port) {
                $0["type"] as? String == "page" && $0["url"] as? String == page.url.absoluteString
            }
            #expect(try await DevToolsPage.pageCount(port: profile.port) == 1)
            let extensionWorker = try await waitForTarget(port: profile.port) {
                $0["type"] as? String == "service_worker"
                    && ($0["url"] as? String).map { $0.hasPrefix("chrome-extension://") && $0.hasSuffix("/" + worker) } == true
            }
            #expect(!(extensionWorker["url"] as? String ?? "").contains(Self.passkeyBoxID))

            let endpoint = try #require(await runtime.devToolsEndpoint(for: profile.id))
            let browser = try DevToolsClient(endpoint: endpoint)
            defer { browser.close() }
            let targetID = try #require(opened["id"] as? String)
            let window = try await browser.send("Browser.getWindowForTarget", ["targetId": targetID])
            let bounds = try #require(window["bounds"] as? [String: Any])
            #expect(bounds["width"] as? Int == 1000)
            #expect(bounds["height"] as? Int == 700)
            #expect(bounds["left"] as? Int == 60)
            #expect(bounds["top"] as? Int == 80)
            try await runtime.stop(profile.id)
        } catch {
            try? await runtime.stop(profile.id)
            throw error
        }
    }

    @Test(
        "Each Profile's Passkey Box signs in with the account it was started with",
        .enabled(
            if: testAppPath != nil,
            "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test."
        )
    )
    @MainActor
    func separatePasskeyBoxAccounts() async throws {
        let (engine, root) = try prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("Storage", isDirectory: true)
        let suffix = UUID().uuidString.prefix(8).lowercased()
        // The extension stores the managed account without contacting the server.
        let accounts = [
            PasskeyBoxAccount(serverURL: "http://127.0.0.1:9", username: "alice-\(suffix)", password: "first"),
            PasskeyBoxAccount(serverURL: "http://127.0.0.1:9", username: "bob-\(suffix)", password: "second"),
        ]
        let profiles = [testPort(9302), testPort(9312)].map {
            BrowserProfile(name: "Identity \($0)", port: $0, fingerprint: FingerprintSettings(seed: $0), proxy: "")
        }

        let runtime = BrowserRuntime(engine: engine, storage: storage)
        do {
            for (profile, account) in zip(profiles, accounts) {
                try await runtime.start(profile, passkeyBox: account)
            }
            for (profile, account) in zip(profiles, accounts) {
                let config = storage.appendingPathComponent("Extensions/\(profile.id.uuidString.lowercased())/PasskeyBox/managed-config.json")
                let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: String])
                #expect(written["username"] == account.username)

                let options = try #require(URL(string: "chrome-extension://\(Self.passkeyBoxID)/options.html"))
                let page = try await DevToolsPage.open(port: profile.port, url: options)
                defer { page.socket.cancel(with: .normalClosure, reason: nil) }
                #expect(try await storedUsername(page) == account.username)
            }
            for profile in profiles { try await runtime.stop(profile.id) }
        } catch {
            for profile in profiles { try? await runtime.stop(profile.id) }
            throw error
        }
    }

    private func prepare() throws -> (BrowserEngine, URL) {
        (try testEngine(), try scratchDirectory("launch"))
    }

    /// The account Passkey Box copied from managed-config.json into its storage.
    private func storedUsername(_ page: DevToolsPage) async throws -> String? {
        for _ in 0..<100 {
            let value = try await page.evaluate(
                "chrome.storage.local.get('pkb_config').then(data => data.pkb_config?.username ?? null)",
                awaitPromise: true
            )
            if let username = value as? String { return username }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func waitForTarget(port: Int, matching: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let target = try await DevToolsPage.waitForTargets(port: port) { $0.contains(where: matching) }
            .first(where: matching)
        return try #require(target)
    }
}

