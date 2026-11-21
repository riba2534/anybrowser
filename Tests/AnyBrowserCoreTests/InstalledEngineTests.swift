import AnyBrowserCore
import Foundation
import Network
import Testing

@Suite(.serialized)
struct InstalledEngineTests {
    @Test(
        "Separate profiles run on the installed Apple silicon engine",
        .enabled(
            if: testAppPath != nil,
            "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test."
        )
    )
    func separateProfilesOnInstalledAppleSiliconEngine() async throws {
        let engine = try testEngine()
        try await verify(engine: engine)
    }

    @Test(
        "Passkey Box signs in from AnyBrowser and completes passkeys without clicks",
        .enabled(
            if: PasskeyFlow.current != nil,
            "Set ANYBROWSER_TEST_APP and ANYBROWSER_TEST_PASSKEY_SERVER, _USERNAME, _PASSWORD and _RP to run the passkey test."
        )
    )
    @MainActor
    func passkeysWithoutClicks() async throws {
        let flow = try #require(PasskeyFlow.current)
        let engine = try BrowserEngine.bundled(in: URL(fileURLWithPath: flow.app))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anybrowser-passkey-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        var profile = try store.makeDraft()
        profile.proxy = ""
        try store.save(profile)
        try await flow.account.verify()
        try store.savePasskeyBoxAccount(flow.account)

        let runtime = BrowserRuntime(engine: engine, storage: store.directory)
        try await runtime.start(profile, passkeyBox: store.passkeyBoxAccount)
        do {
            // A site that requires user verification: the extension answers it directly.
            let site = try #require(URL(string: flow.rp + "/?uv=required"))
            let page = try await DevToolsPage.open(port: profile.port, url: site)
            defer { page.socket.cancel(with: .normalClosure, reason: nil) }
            let name = "anybrowser-" + UUID().uuidString.prefix(8).lowercased()
            _ = try await page.evaluate(
                "document.querySelector('#username').value = '\(name)'; document.querySelector('#register').click(); true",
                userGesture: true
            )
            #expect(try await page.siteResult() == "registered:\(name)")
            _ = try await page.evaluate("document.querySelector('#login').click(); true", userGesture: true)
            #expect(try await page.siteResult() == "authenticated:\(name)")
            // No verification window or dialog was opened along the way.
            #expect(try await DevToolsPage.pageCount(port: profile.port) == 1)
            try await runtime.stop(profile.id)
        } catch {
            try? await runtime.stop(profile.id)
            throw error
        }
    }

    @Test(
        "Profiles sharing a Passkey Box account each sign in to their own site account without a picker",
        .enabled(
            if: PasskeyFlow.current != nil,
            "Set ANYBROWSER_TEST_APP and ANYBROWSER_TEST_PASSKEY_SERVER, _USERNAME, _PASSWORD and _RP to run the passkey test."
        )
    )
    @MainActor
    func identitiesShareAnAccount() async throws {
        let flow = try #require(PasskeyFlow.current)
        let engine = try BrowserEngine.bundled(in: URL(fileURLWithPath: flow.app))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anybrowser-identities-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        var profiles: [BrowserProfile] = []
        for _ in 0..<2 {
            var profile = try store.makeDraft()
            profile.proxy = ""
            try store.save(profile)
            profiles.append(profile)
        }
        try await flow.account.verify()
        try store.savePasskeyBoxAccount(flow.account)

        let runtime = BrowserRuntime(engine: engine, storage: store.directory)
        do {
            let site = try #require(URL(string: flow.rp + "/?uv=required"))
            var pages: [DevToolsPage] = []
            defer { pages.forEach { $0.socket.cancel(with: .normalClosure, reason: nil) } }
            let names = profiles.map { _ in "identity-" + UUID().uuidString.prefix(8).lowercased() }
            for (profile, name) in zip(profiles, names) {
                try await runtime.start(profile, passkeyBox: store.passkeyBoxAccount)
                let page = try await DevToolsPage.open(port: profile.port, url: site)
                pages.append(page)
                _ = try await page.evaluate(
                    "document.querySelector('#username').value = '\(name)'; document.querySelector('#register').click(); true",
                    userGesture: true
                )
                #expect(try await page.siteResult() == "registered:\(name)")
            }
            // The account now holds both site accounts; each Profile signs in to its own, with no picker.
            for (page, name) in zip(pages, names) {
                _ = try await page.evaluate("document.querySelector('#login').click(); true", userGesture: true)
                #expect(try await page.siteResult() == "authenticated:\(name)")
            }
            for profile in profiles { try await runtime.stop(profile.id) }
        } catch {
            for profile in profiles { try? await runtime.stop(profile.id) }
            throw error
        }
    }

    @MainActor
    private func verify(engine: BrowserEngine) async throws {
        #expect(engine.version == "148.0.7778.215")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anybrowser-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = try await LoopbackPage.start()
        defer { page.listener.cancel() }
        let proxy = try await LoopbackPage.start(title: "AnyBrowser proxy fixture")
        defer { proxy.listener.cancel() }
        let store = try ProfileStore(directory: directory)
        var first = try store.makeDraft()
        let proxyPort = try #require(proxy.url.port)
        first.proxy = "127.0.0.1:\(proxyPort)"
        first.fingerprint.platform = .macOS
        first.fingerprint.cpuCount = 8
        first.fingerprint.timeZone = "UTC"
        try store.save(first)
        var second = try store.makeDraft()
        second.fingerprint.platform = .windows
        second.fingerprint.cpuCount = 12
        second.fingerprint.timeZone = "Asia/Tokyo"
        try store.save(second)
        #expect([first.port, second.port] == [9222, 9223] as [Int])

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
            #expect(pids[0] != pids[1])

            let restored = BrowserRuntime(engine: engine, storage: store.directory)
            await restored.refresh([first, second])
            #expect(restored.status(for: first.id) == runtime.status(for: first.id))
            #expect(restored.status(for: second.id) == runtime.status(for: second.id))
            #expect(restored.matchesRunningConfiguration(first) == true)
            // Starting a Profile that is already running adopts it and reports that nothing was launched.
            #expect(try await restored.start(first) == false)
            var changed = first
            changed.fingerprint.cpuCount = 16
            #expect(restored.matchesRunningConfiguration(changed) == false)
            changed = first
            changed.proxy = ""
            #expect(restored.matchesRunningConfiguration(changed) == false)

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
            #expect(secondInitial is NSNull)
            _ = try await secondPage.evaluate("localStorage.setItem('anybrowser-fixture', 'profile-two')")
            let firstStored = try await firstPage.evaluate("localStorage.getItem('anybrowser-fixture')")
            #expect((firstStored as? String) == "profile-one")

            let proxyTarget = try #require(URL(string: "http://anybrowser-proxy.invalid/"))
            try await firstPage.navigate(to: proxyTarget)
            let proxyTitle = try await firstPage.evaluate("document.title")
            #expect((proxyTitle as? String) == "AnyBrowser proxy fixture")

            let extensionID = "gfejlnakeokbjdhoionfappnfepjoili"
            let optionsURL = try #require(URL(string: "chrome-extension://\(extensionID)/options.html"))
            for tab in [firstPage, secondPage] {
                try await tab.navigate(to: optionsURL)
                try await assertPasskeyBox(tab, id: extensionID)
            }
            _ = try await firstPage.evaluate(
                "chrome.storage.local.set({anybrowserFixture: 'profile-one'}).then(() => true)",
                awaitPromise: true
            )
            let initialSecondExtensionValue = try await passkeyBoxFixture(secondPage)
            #expect(initialSecondExtensionValue is NSNull)

            var conflict = try store.makeDraft()
            conflict.port = first.port
            do {
                try await runtime.start(conflict)
                Issue.record("A second instance unexpectedly started on an occupied port")
                try await runtime.stop(conflict.id)
            } catch {
                #expect(runtime.status(for: first.id) == .running(pid: pids[0], port: first.port, debugReady: true))
            }

            try await runtime.stop(first.id)
            #expect(runtime.status(for: first.id) == .stopped)
            #expect(runtime.status(for: second.id) == .running(pid: pids[1], port: second.port, debugReady: true))
            try await runtime.start(first)
            let reopened = try await DevToolsPage.open(port: first.port, url: page.url)
            defer { reopened.socket.cancel(with: .normalClosure, reason: nil) }
            try await assertPage(reopened, platform: "macOS", cores: 8, timezone: "UTC")
            let reopenedValue = try await reopened.evaluate("localStorage.getItem('anybrowser-fixture')")
            #expect((reopenedValue as? String) == "profile-one")
            try await reopened.navigate(to: optionsURL)
            try await assertPasskeyBox(reopened, id: extensionID)
            let reopenedExtensionValue = try await passkeyBoxFixture(reopened)
            #expect((reopenedExtensionValue as? String) == "profile-one")

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
        let fields = try #require(observed as? [String: Any])
        #expect((fields["platform"] as? String) == platform)
        #expect((fields["cores"] as? Int) == cores)
        #expect((fields["zone"] as? String) == timezone)
    }

    private func assertPasskeyBox(_ page: DevToolsPage, id: String) async throws {
        for _ in 0..<50 {
            let observed = try await page.evaluate("""
                (() => {
                    const input = document.querySelector('[name=serverUrl]');
                    if (!input || !chrome.runtime?.id) return null;
                    return { id: chrome.runtime.id, version: chrome.runtime.getManifest().version, server: input.value };
                })()
                """)
            if let fields = observed as? [String: Any] {
                #expect((fields["id"] as? String) == id)
                #expect((fields["version"] as? String) == "0.4.0")
                #expect((fields["server"] as? String) == "https://password.riba2534.cn/")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VerificationFailure.message("Passkey Box 设置页没有就绪")
    }

    private func passkeyBoxFixture(_ page: DevToolsPage) async throws -> Any {
        try await page.evaluate(
            "chrome.storage.local.get('anybrowserFixture').then(data => data.anybrowserFixture ?? null)",
            awaitPromise: true
        )
    }
}
