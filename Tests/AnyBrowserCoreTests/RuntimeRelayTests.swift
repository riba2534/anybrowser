@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

// The fake engine listens on ports 11440–11446 here; the relay helper is the AnyBrowserRelay
// product built beside the tests.

/// A fake-engine runtime whose engine has the relay helper.
@MainActor
private struct RelayFixture {
    let fake: FakeEngineFixture
    let engine: BrowserEngine
    let runtime: BrowserRuntime
    let origin: EchoStub
    let upstream: UpstreamHTTPStub

    init(_ label: String, helper: String? = relayHelperPath) throws {
        fake = try FakeEngineFixture(label)
        var engine = fake.engine
        engine.relayExecutable = helper.map { URL(fileURLWithPath: $0) }
        self.engine = engine
        origin = try EchoStub()
        let echo = origin.port
        upstream = try UpstreamHTTPStub(credentials: "alice:s3cret") { $0.hasPrefix("echo.test") ? echo : nil }
        runtime = Self.runtime(engine, fake)
    }

    static func runtime(_ engine: BrowserEngine, _ fake: FakeEngineFixture) -> BrowserRuntime {
        let runtime = BrowserRuntime(engine: engine, storage: fake.storage, applicationSupport: fake.applicationSupport,
                                     caches: fake.caches)
        runtime.readinessTimeout = 5
        runtime.stopTimeout = 2
        runtime.terminationGrace = 1
        runtime.startPageBudget = 2
        runtime.relayRelaunchGrace = 3
        return runtime
    }

    /// Another runtime on the same folders, as AnyBrowser has after a restart.
    func restarted() -> BrowserRuntime { Self.runtime(engine, fake) }

    func profile(port: Int, password: String = "s3cret") -> BrowserProfile {
        var profile = fake.profile(port: port)
        profile.proxy = "http://alice:\(password)@127.0.0.1:\(upstream.port)"
        return profile
    }

    func directory(_ profile: BrowserProfile) -> URL { runtime.dataDirectory(for: profile.id) }

    func receipt(_ profile: BrowserProfile) -> BrowserRuntime.Receipt? {
        let url = runtime.receiptURL(directory(profile))
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(BrowserRuntime.Receipt.self, from: $0) }
    }

    /// Helpers still running for the Profile's data directory.
    func helpers(_ profile: BrowserProfile) -> [Int32] {
        let portFile = runtime.relayPortFile(directory(profile)).path
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { Int(proc_listallpids($0.baseAddress, Int32($0.count))) }
        return pids.prefix(max(0, min(count, capacity))).filter { pid in
            pid > 0 && isAlive(pid) && ProcessInspection.arguments(pid)?.contains(portFile) == true
        }
    }

    func browserArguments(_ profile: BrowserProfile, in runtime: BrowserRuntime? = nil) -> [String] {
        guard case let .running(pid, _, _) = (runtime ?? self.runtime).status(for: profile.id) else { return [] }
        return ProcessInspection.arguments(pid) ?? []
    }

    func relayPort(_ profile: BrowserProfile, in runtime: BrowserRuntime? = nil) -> Int? {
        let prefix = "--proxy-server=http://127.0.0.1:"
        return browserArguments(profile, in: runtime).first { $0.hasPrefix(prefix) }.flatMap { Int($0.dropFirst(prefix.count)) }
    }

    func run(_ profiles: [BrowserProfile], runtimes: [BrowserRuntime] = [], _ body: () async throws -> Void) async throws {
        try await runThenCleanUp(body) { await cleanUp(profiles, runtimes: runtimes) }
    }

    private func cleanUp(_ profiles: [BrowserProfile], runtimes: [BrowserRuntime]) async {
        for profile in profiles {
            for runtime in [runtime] + runtimes { try? await runtime.stop(profile.id, force: true) }
            for pid in helpers(profile) { kill(pid, SIGKILL) }
        }
        await fake.cleanUp(profiles)
        upstream.stop()
        origin.stop()
    }
}

@MainActor
@Suite(.serialized, .enabled(if: relayHelperPath != nil, "Build the AnyBrowserRelay product (swift build) to run the relay runtime tests."))
struct RuntimeRelayTests {
    @Test("A proxy with credentials is reached through a helper the receipt records, and survives an AnyBrowser restart")
    func relaysThroughTheHelper() async throws {
        let fixture = try RelayFixture("runtime-relay")
        let profile = fixture.profile(port: 11440)
        // AnyBrowser 0.4 left a sign-in extension with the password in it.
        let legacy = ProfileExtensions.legacyProxySignIn(in: fixture.runtime.storage, for: profile.id)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(#"{"name": "AnyBrowser Proxy Sign-in"}"#.utf8).write(to: legacy.appendingPathComponent("manifest.json"))
        try fixture.fake.configure(profile, [:])
        let restored = fixture.restarted()
        try await fixture.run([profile], runtimes: [restored]) {
            try await fixture.runtime.start(profile)
            #expect(!FileManager.default.fileExists(atPath: legacy.path))
            let port = try #require(fixture.relayPort(profile))
            let arguments = fixture.browserArguments(profile)
            #expect(!arguments.contains { $0.contains("s3cret") || $0.contains(":\(fixture.upstream.port)") || $0.contains("ProxyAuth") })
            let relay = try #require(fixture.receipt(profile)?.relay)
            #expect(relay.port == port && fixture.helpers(profile) == [relay.pid])
            #expect(!(ProcessInspection.arguments(relay.pid) ?? []).joined(separator: " ").contains("s3cret"))

            // The browser's proxy reaches the origin through the upstream, signed in.
            #expect(await RelayClient.tunnel(port, to: "echo.test:7", payload: Data("one".utf8))?.text == "echo:one")
            #expect(fixture.upstream.requests.last?.authorization == fixture.upstream.signIn)

            // A new port every launch is no pending restart; another password or no relay is.
            #expect(fixture.runtime.matchesRunningConfiguration(profile) == true)
            var changed = profile
            changed.proxy = "http://alice:other@127.0.0.1:\(fixture.upstream.port)"
            #expect(fixture.runtime.matchesRunningConfiguration(changed) == false)
            var plain = profile
            plain.proxy = "http://127.0.0.1:\(fixture.upstream.port)"
            #expect(fixture.runtime.matchesRunningConfiguration(plain) == false)

            // AnyBrowser restarts: the browser and its relay carry on, and nothing waits for a restart.
            await restored.refresh([profile])
            #expect(restored.status(for: profile.id).isUp)
            #expect(restored.matchesRunningConfiguration(profile) == true)
            #expect(await RelayClient.tunnel(port, to: "echo.test:7", payload: Data("two".utf8))?.text == "echo:two")

            try await restored.stop(profile.id)
            #expect(restored.status(for: profile.id) == .stopped)
            #expect(fixture.helpers(profile).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.runtime.relayPortFile(fixture.directory(profile)).path))
            #expect(fixture.receipt(profile) == nil)
        }
    }

    @Test("A browser that relaunches itself keeps its relay, and a relay that died shows as a pending restart")
    func followsARelaunchedBrowser() async throws {
        let fixture = try RelayFixture("runtime-relay-relaunch")
        let profile = fixture.profile(port: 11441)
        // The launch starts a relay and then the browser; it must finish before the browser relaunches,
        // also on a busy machine.
        try fixture.fake.configure(profile, ["relaunch_ms": "2500"])
        try await fixture.run([profile]) {
            try await fixture.runtime.start(profile)
            guard case let .running(first, _, _) = fixture.runtime.status(for: profile.id) else {
                Issue.record("Not running: \(fixture.runtime.status(for: profile.id))")
                return
            }
            let relay = try #require(fixture.receipt(profile)?.relay)
            // The relaunched browser holds the data directory under a new pid; the relay follows it.
            var adopted: Int32?
            #expect(await fixture.fake.eventually(10) {
                await fixture.runtime.refresh([profile])
                if case let .running(pid, _, _) = fixture.runtime.status(for: profile.id), pid != first { adopted = pid }
                return adopted != nil
            })
            #expect(fixture.receipt(profile)?.relay == relay)
            try await Task.sleep(nanoseconds: UInt64(fixture.runtime.relayRelaunchGrace * 1_000_000_000) + 500_000_000)
            #expect(isAlive(relay.pid))
            #expect(fixture.runtime.matchesRunningConfiguration(profile) == true)
            #expect(await RelayClient.tunnel(relay.port, to: "echo.test:7", payload: Data("after".utf8))?.text == "echo:after")

            kill(relay.pid, SIGKILL)
            #expect(await fixture.fake.eventually { !isAlive(relay.pid) })
            #expect(fixture.runtime.matchesRunningConfiguration(profile) == false)
        }
    }

    @Test("A relay outlives AnyBrowser but not its browser")
    func endsWithTheBrowser() async throws {
        let fixture = try RelayFixture("runtime-relay-crash")
        let profile = fixture.profile(port: 11447)
        try fixture.fake.configure(profile, [:])
        try await fixture.run([profile]) {
            try await fixture.runtime.start(profile)
            guard case let .running(pid, _, _) = fixture.runtime.status(for: profile.id) else {
                Issue.record("Not running: \(fixture.runtime.status(for: profile.id))")
                return
            }
            let relay = try #require(fixture.receipt(profile)?.relay)
            // The helper was handed the browser: it is the browser's end, not AnyBrowser's, that it waits for.
            #expect(ProcessInspection.arguments(relay.pid)?.contains(String(getpid())) == true)
            kill(pid, SIGKILL)
            let grace = fixture.runtime.relayRelaunchGrace
            #expect(await fixture.fake.eventually(grace + 3) { !isAlive(relay.pid) })
            #expect(!FileManager.default.fileExists(atPath: fixture.runtime.relayPortFile(fixture.directory(profile)).path))
        }
    }

    @Test("A launch that fails ends its relay, and an app bundle without the helper says so")
    func cleansUpAfterFailures() async throws {
        let fixture = try RelayFixture("runtime-relay-failures")
        let early = fixture.profile(port: 11442)
        try fixture.fake.configure(early, ["exit_ms": "200", "exit_code": "3", "ready_ms": "5000"])
        var plain = fixture.fake.profile(port: 11443)
        plain.proxy = "http://127.0.0.1:\(fixture.upstream.port)"
        try fixture.fake.configure(plain, [:])
        let old = try RelayFixture("runtime-relay-old", helper: nil)
        let stranded = old.profile(port: 11444)
        let broken = try RelayFixture("runtime-relay-broken", helper: "/usr/bin/false")
        let silent = broken.profile(port: 11445)
        try await fixture.run([early, plain]) {
            await #expect(throws: (any Error).self) { try await fixture.runtime.start(early) }
            #expect(fixture.helpers(early).isEmpty)
            #expect(fixture.fake.lockHolder(early) == nil)

            // Without credentials there is no relay.
            try await fixture.runtime.start(plain)
            #expect(fixture.receipt(plain)?.relay == nil)
            #expect(fixture.helpers(plain).isEmpty)
            #expect(fixture.browserArguments(plain).contains("--proxy-server=http://127.0.0.1:\(fixture.upstream.port)"))
        }
        try await old.run([stranded]) {
            let error = await #expect(throws: (any Error).self) { try await old.runtime.start(stranded) }
            #expect(error?.localizedDescription.contains("缺少代理中继组件") == true)
            #expect(old.fake.lockHolder(stranded) == nil)
        }
        try await broken.run([silent]) {
            let error = await #expect(throws: (any Error).self) { try await broken.runtime.start(silent) }
            #expect(error?.localizedDescription.hasPrefix("代理中继未能启动") == true)
            #expect(broken.fake.lockHolder(silent) == nil)
            guard case .failed = broken.runtime.status(for: silent.id) else {
                Issue.record("Not failed: \(broken.runtime.status(for: silent.id))")
                return
            }
        }
    }
}

@MainActor
struct RuntimeOwnershipTests {
    @Test("After AnyBrowser restarts it still knows a browser whose recorded path names the engine through a link")
    func recognizesLinkedEnginePaths() async throws {
        let fake = try FakeEngineFixture("runtime-linked")
        let folder = fake.root.appendingPathComponent("Engine", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("fake-chromium")
        try FileManager.default.copyItem(at: try FakeEngine.executable(), to: binary)
        let engine = BrowserEngine(version: "test", executable: try #require(ProcessInspection.canonicalURL(binary)),
                                   passkeyBoxDirectory: fake.engine.passkeyBoxDirectory)
        let runtime = BrowserRuntime(engine: engine, storage: fake.storage, applicationSupport: fake.applicationSupport,
                                     caches: fake.caches)
        let restored = BrowserRuntime(engine: engine, storage: fake.storage, applicationSupport: fake.applicationSupport,
                                      caches: fake.caches)
        let profile = fake.profile(port: 11446)
        try fake.configure(profile, [:])
        do {
            try await runtime.start(profile)
            guard case let .running(pid, _, _) = runtime.status(for: profile.id) else {
                throw VerificationFailure.message("Not running: \(runtime.status(for: profile.id))")
            }
            // Process records /var/… for /private/var/…; once the running file has moved, as Chromium's
            // code-signing clone makes it look, only that recorded path still names the engine.
            #expect(ProcessInspection.image(pid)?.executablePath != engine.executable.path)
            try FileManager.default.moveItem(at: binary, to: folder.appendingPathComponent("fake-chromium-moved"))
            try FileManager.default.copyItem(at: folder.appendingPathComponent("fake-chromium-moved"), to: binary)
            #expect(ProcessInspection.executable(pid) != engine.executable)
            await restored.refresh([profile])
            #expect(restored.status(for: profile.id) == runtime.status(for: profile.id))
            #expect(restored.matchesRunningConfiguration(profile) == true)
        } catch {
            await fake.cleanUp([profile], runtimes: [runtime, restored])
            throw error
        }
        await fake.cleanUp([profile], runtimes: [runtime, restored])
    }
}
