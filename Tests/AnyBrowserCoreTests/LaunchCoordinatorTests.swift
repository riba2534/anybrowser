@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

// The fake engine listens on ports 11600–11649 here (plus ANYBROWSER_TEST_PORT_OFFSET); the
// automation servers use 9460–9469.

/// A store and a coordinator on the fake engine. The proxy check and the exit lookup answer at
/// once with nothing unless a test replaces them.
@MainActor
struct CoordinatorFixture {
    let fake: FakeEngineFixture
    let store: ProfileStore
    let coordinator: LaunchCoordinator
    var runtime: BrowserRuntime { fake.runtime }

    init(_ label: String) throws {
        fake = try FakeEngineFixture(label)
        store = try ProfileStore(directory: fake.storage)
        coordinator = LaunchCoordinator(store: store, runtime: fake.runtime)
        coordinator.proxyPreflight = { _ in nil }
        coordinator.exitLookup = { _ in nil }
    }

    /// Saves a Profile on the fake engine's `port` and returns it as saved.
    @discardableResult
    func add(_ port: Int, _ change: (inout BrowserProfile) -> Void = { _ in }) throws -> BrowserProfile {
        var profile = fake.profile(port: testPort(port), name: "P\(port)")
        change(&profile)
        try store.save(profile)
        return try #require(store.profiles.first { $0.id == profile.id })
    }

    func saved(_ profile: BrowserProfile) throws -> BrowserProfile {
        try #require(store.profiles.first { $0.id == profile.id })
    }

    /// Saves a change to a Profile and returns it as saved.
    @discardableResult
    func edit(_ profile: BrowserProfile, _ change: (inout BrowserProfile) -> Void) throws -> BrowserProfile {
        var value = try saved(profile)
        change(&value)
        try store.save(value)
        return try saved(value)
    }

    func pid(_ profile: BrowserProfile) -> Int32? {
        if case let .running(pid, _, _) = runtime.status(for: profile.id) { return pid }
        return nil
    }

    func data(_ profile: BrowserProfile, _ relative: String) -> URL {
        runtime.dataDirectory(for: profile.id).appendingPathComponent(relative)
    }

    func cache(_ profile: BrowserProfile, _ relative: String) -> URL {
        runtime.cacheDirectory(for: profile.id).appendingPathComponent(relative)
    }

    /// Writes a file the way Chromium leaves one, creating private parents.
    func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data("kept".utf8).write(to: url)
    }

    /// Cookies, a cache entry and preferences, as a used Profile has them.
    func writeSiteData(_ profile: BrowserProfile) throws {
        try write(data(profile, "Default/Network/Cookies"))
        try write(data(profile, "Default/Preferences"))
        try write(cache(profile, "Default/Cache/Cache_Data/index"))
    }

    func exists(_ url: URL) -> Bool {
        var details = stat()
        return lstat(url.path, &details) == 0
    }

    func run(_ profiles: [BrowserProfile], runtimes: [BrowserRuntime] = [], _ body: () async throws -> Void) async throws {
        try await runThenCleanUp(body) { await finish(profiles, runtimes: runtimes) }
    }

    private func finish(_ profiles: [BrowserProfile], runtimes: [BrowserRuntime]) async {
        coordinator.stopMonitoring()
        _ = await coordinator.automation.save(AutomationConfiguration(enabled: false, token: automationTestToken))
        await fake.cleanUp(profiles, runtimes: runtimes)
    }
}

/// The highest value `count` had while `body` ran, sampled every 20 ms.
@MainActor
func peak(_ count: @escaping @MainActor () -> Int, during body: () async throws -> Void) async rethrows -> Int {
    final class Highest { var value = 0 }
    let highest = Highest()
    let sampler = Task { @MainActor in
        while !Task.isCancelled {
            highest.value = max(highest.value, count())
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    try await body()
    sampler.cancel()
    return max(highest.value, count())
}

/// Whether something accepts TCP connections on 127.0.0.1:`port`.
func listening(_ port: Int) -> Bool {
    let socket = Sockets.connect(to: port)
    guard socket >= 0 else { return false }
    close(socket)
    return true
}

private func managedAccount(_ fixture: CoordinatorFixture, _ profile: BrowserProfile) throws -> String? {
    let file = PasskeyBoxInstall.directory(in: fixture.fake.storage, for: profile.id)
        .appendingPathComponent(PasskeyBoxInstall.managedConfigFile)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String]
    return json?["username"]
}

@Suite("Launch coordinator", .serialized)
@MainActor
struct LaunchCoordinatorTests {
    @Test("A Profile without its own Passkey Box account signs in with the global one, on every path")
    func accountFallback() async throws {
        let fixture = try CoordinatorFixture("coordinator-account")
        try fixture.store.savePasskeyBoxAccount(PasskeyBoxAccount(serverURL: "https://box.example", username: "global", password: "pw"))
        let shared = try fixture.add(11600)
        let own = try fixture.add(11601) { $0.passkeyBox = PasskeyBoxAccount(serverURL: "https://box.example", username: "own", password: "pw") }
        let backend: AutomationBackend = fixture.coordinator
        try await fixture.run([shared, own]) {
            try await backend.start(shared)
            try await fixture.coordinator.start(own.id)
            #expect(try managedAccount(fixture, shared) == "global")
            #expect(try managedAccount(fixture, own) == "own")
            #expect(!fixture.coordinator.hasPendingRestart(shared.id))

            // Another global account applies to the Profile using it once it restarts.
            try fixture.store.savePasskeyBoxAccount(PasskeyBoxAccount(serverURL: "https://box.example", username: "next", password: "pw"))
            #expect(fixture.coordinator.hasPendingRestart(shared.id))
            #expect(!fixture.coordinator.hasPendingRestart(own.id))
            // Removing it does not sign the extension out, so there is nothing to restart for.
            try fixture.store.savePasskeyBoxAccount(nil)
            #expect(!fixture.coordinator.hasPendingRestart(shared.id))
            try fixture.store.savePasskeyBoxAccount(PasskeyBoxAccount(serverURL: "https://box.example", username: "next", password: "pw"))
            try await fixture.coordinator.restart(shared.id)
            #expect(try managedAccount(fixture, shared) == "next")
            #expect(!fixture.coordinator.hasPendingRestart(shared.id))
        }
    }

    @Test("A Profile is busy from the proxy check until its browser is up, and refuses another operation")
    func busyWhileLaunching() async throws {
        let fixture = try CoordinatorFixture("coordinator-busy")
        fixture.coordinator.proxyPreflight = { _ in
            try? await Task.sleep(nanoseconds: 400_000_000)
            return nil
        }
        let profile = try fixture.add(11602) { $0.proxy = "127.0.0.1:9" }
        try fixture.fake.configure(profile, ["ready_ms": "300"])
        try await fixture.run([profile]) {
            let launch = Task { try await fixture.coordinator.start(profile.id) }
            #expect(await fixture.fake.eventually { fixture.coordinator.launches.contains(profile.id) })
            // Still checking the proxy: the runtime has not been asked yet.
            #expect(fixture.runtime.status(for: profile.id) == .stopped)
            #expect(fixture.coordinator.isBusy(profile.id))
            #expect(fixture.coordinator.removalBlocker(profile.id) != nil)
            let again = await #expect(throws: ProfileError.self) { try await fixture.coordinator.start(profile.id) }
            #expect(again?.localizedDescription.contains("正在执行另一个操作") == true)
            await #expect(throws: ProfileError.self) { try await fixture.coordinator.stop(profile.id) }
            await #expect(throws: ProfileError.self) { try await fixture.coordinator.generateIdentity(for: profile) }
            let outcome = try await launch.value
            #expect(outcome.startedFresh)
            #expect(!fixture.coordinator.isBusy(profile.id))
            #expect(fixture.pid(profile) != nil)
            #expect(fixture.store.lastLaunched[profile.id] != nil)
        }
    }

    @Test("Restarting stops the browser and starts it with the saved configuration")
    func restartAppliesSavedConfiguration() async throws {
        let fixture = try CoordinatorFixture("coordinator-restart")
        let profile = try fixture.add(11603)
        try await fixture.run([profile]) {
            try await fixture.coordinator.start(profile.id)
            let first = try #require(fixture.pid(profile))
            try fixture.edit(profile) { $0.fingerprint.language = "fr-FR" }
            #expect(fixture.coordinator.hasPendingRestart(profile.id))
            let outcome = try await fixture.coordinator.restart(profile.id)
            #expect(outcome.startedFresh)
            let second = try #require(fixture.pid(profile))
            #expect(second != first)
            #expect(!isAlive(first))
            #expect(ProcessInspection.arguments(second)?.contains("--lang=fr-FR") == true)
            #expect(!fixture.coordinator.hasPendingRestart(profile.id))
            try await fixture.coordinator.stop(profile.id)
            #expect(fixture.runtime.status(for: profile.id) == .stopped)
            #expect(!fixture.coordinator.hasPendingRestart(profile.id))
        }
    }

    @Test("Waiting for a restart ignores renames, start pages and one-off launch overrides")
    func pendingRestartRules() async throws {
        let fixture = try CoordinatorFixture("coordinator-pending")
        let profile = try fixture.add(11604)
        let adopted = try fixture.add(11605)
        let restarted = fixture.fake.makeRuntime()
        try await fixture.run([profile, adopted], runtimes: [restarted]) {
            try await fixture.coordinator.start(profile.id, overrides: LaunchOverrides(headless: true, arguments: ["--test-switch"]))
            let coordinator = fixture.coordinator
            #expect(!coordinator.hasPendingRestart(profile.id))
            try fixture.edit(profile) { $0.name = "Renamed" }
            #expect(!coordinator.hasPendingRestart(profile.id))
            try fixture.edit(profile) { $0.launch.startURLs = ["https://other.example/"] }
            #expect(!coordinator.hasPendingRestart(profile.id))
            try fixture.edit(profile) { $0.notes = "Notes"; $0.group = "Group"; $0.tags = ["tag"] }
            #expect(!coordinator.hasPendingRestart(profile.id))

            let changes: [(String, (inout BrowserProfile) -> Void)] = [
                ("proxy", { $0.proxy = "127.0.0.1:9" }),
                ("port", { $0.port = testPort(11649) }),
                ("fingerprint", { $0.fingerprint.timeZone = "Asia/Tokyo" }),
                ("window", { $0.launch.window = WindowLayout(width: 800, height: 600) }),
                ("extensions", { $0.launch.loadPasskeyBox = false }),
            ]
            let base = try fixture.saved(profile)
            for (label, change) in changes {
                try fixture.edit(profile, change)
                #expect(coordinator.hasPendingRestart(profile.id), "\(label)")
                try fixture.store.save(base)
            }
            #expect(!coordinator.hasPendingRestart(profile.id))

            // After AnyBrowser restarted only the command line is known; the name is still not a reason.
            try await fixture.coordinator.start(adopted.id)
            let later = LaunchCoordinator(store: fixture.store, runtime: restarted)
            await later.refresh(adopted.id)
            #expect(restarted.status(for: adopted.id).isUp)
            #expect(!later.hasPendingRestart(adopted.id))
            try fixture.edit(adopted) { $0.name = "Adopted and renamed" }
            #expect(!later.hasPendingRestart(adopted.id))
            try fixture.edit(adopted) { $0.fingerprint.timeZone = "Asia/Tokyo" }
            #expect(later.hasPendingRestart(adopted.id))
        }
    }

    @Test("No more than three browsers start at once, however many the API asks for")
    func launchSlots() async throws {
        let fixture = try CoordinatorFixture("coordinator-slots")
        var profiles: [BrowserProfile] = []
        for port in 11606...11610 {
            let profile = try fixture.add(port)
            try fixture.fake.configure(profile, ["ready_ms": "700"])
            profiles.append(profile)
        }
        let backend: AutomationBackend = fixture.coordinator
        try await fixture.run(profiles) {
            var waiting = 0
            let starting = try await peak({
                waiting = max(waiting, fixture.coordinator.queued.count)
                return profiles.filter { fixture.runtime.status(for: $0.id) == .starting }.count
            }) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for profile in profiles {
                        group.addTask { @MainActor in try await backend.start(profile) }
                    }
                    try await group.waitForAll()
                }
            }
            #expect(starting == 3)
            #expect(waiting >= 2)
            #expect(profiles.allSatisfy { fixture.runtime.status(for: $0.id).isUp })
            #expect(fixture.coordinator.queued.isEmpty && fixture.coordinator.launches.isEmpty)
        }
    }

    @Test("A batch starts three at a time, checks each proxy once and reports its progress")
    func batchStart() async throws {
        let fixture = try CoordinatorFixture("coordinator-batch")
        var checks: [String: Int] = [:]
        fixture.coordinator.proxyPreflight = { proxy in
            let server = (try? ProxyEndpoint.parse(proxy))?.server ?? proxy
            checks[server, default: 0] += 1
            try? await Task.sleep(nanoseconds: 200_000_000)
            return server.hasSuffix(":9") ? "代理 \(server) 无法连接。" : nil
        }
        var profiles: [BrowserProfile] = []
        for (offset, port) in (11611...11615).enumerated() {
            let profile = try fixture.add(port) { $0.proxy = offset < 3 ? "127.0.0.1:9" : "socks5://127.0.0.1:10" }
            try fixture.fake.configure(profile, ["ready_ms": "600"])
            profiles.append(profile)
        }
        let ids = profiles.map(\.id)
        try await fixture.run(profiles) {
            var progress: [BatchProgress] = []
            var report = BatchReport()
            let starting = try await peak({
                if let batch = fixture.coordinator.batch, progress.last != batch { progress.append(batch) }
                return profiles.filter { fixture.runtime.status(for: $0.id) == .starting }.count
            }) {
                report = try await fixture.coordinator.startBatch(ids + [ids[0]])
            }
            #expect(starting == 3)
            #expect(report.outcome.succeeded == 5 && report.outcome.failures.isEmpty && report.cancelled == 0)
            #expect(checks == ["http://127.0.0.1:9": 1, "socks5://127.0.0.1:10": 1])
            #expect(report.outcome.warnings == ["P11611、P11612、P11613：代理 http://127.0.0.1:9 无法连接。"])
            #expect(progress.first == BatchProgress(action: .start, completed: 0, total: 5, canCancel: true))
            #expect(progress.allSatisfy { $0.action == .start && $0.total == 5 && $0.canCancel })
            #expect(progress.map(\.completed) == progress.map(\.completed).sorted())
            #expect(progress.count >= 2)
            #expect(fixture.coordinator.batch == nil)

            let again = try await fixture.coordinator.startBatch(ids)
            #expect(again.outcome.skipped == 5)
            let stopped = try await fixture.coordinator.stopBatch(ids)
            #expect(stopped.outcome.succeeded == 5)
            #expect(profiles.allSatisfy { fixture.runtime.status(for: $0.id) == .stopped })
        }
    }

    @Test("Cancelling a batch lets the launches under way finish and skips the rest")
    func batchCancel() async throws {
        let fixture = try CoordinatorFixture("coordinator-cancel")
        var profiles: [BrowserProfile] = []
        for port in 11616...11621 {
            let profile = try fixture.add(port)
            try fixture.fake.configure(profile, ["ready_ms": "700"])
            profiles.append(profile)
        }
        try await fixture.run(profiles) {
            let batch = Task { try await fixture.coordinator.startBatch(profiles.map(\.id)) }
            #expect(await fixture.fake.eventually {
                profiles.filter { fixture.runtime.status(for: $0.id) == .starting }.count == 3
            })
            await #expect(throws: ProfileError.self) { try await fixture.coordinator.stopBatch(profiles.map(\.id)) }
            fixture.coordinator.cancelBatch()
            #expect(fixture.coordinator.batch?.canCancel == false)
            let report = try await batch.value
            #expect(report.outcome.succeeded == 3)
            #expect(report.cancelled == 3)
            #expect(report.summary(verb: "启动").hasSuffix("已取消其余 3 个。"))
            #expect(profiles.filter { fixture.runtime.status(for: $0.id).isUp }.count == 3)
        }
    }

    @Test("Generating a new identity deletes and saves nothing, so discarding it keeps the data")
    func generatingKeepsData() async throws {
        let fixture = try CoordinatorFixture("coordinator-generate")
        fixture.coordinator.exitLookup = { _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return ProxyExit(ip: "203.0.113.7", countryCode: "JP", timeZone: "Asia/Tokyo", languages: ["ja-JP"])
        }
        let profile = try fixture.add(11622) { $0.proxy = "127.0.0.1:9" }
        try fixture.writeSiteData(profile)
        try await fixture.run([profile]) {
            let generation = Task { try await fixture.coordinator.generateIdentity(for: profile) }
            #expect(await fixture.fake.eventually { fixture.coordinator.regenerating.contains(profile.id) })
            #expect(fixture.coordinator.isBusy(profile.id))
            await #expect(throws: ProfileError.self) { try await fixture.coordinator.start(profile.id) }
            let identity = try await generation.value
            #expect(!fixture.coordinator.isBusy(profile.id))
            #expect(!identity.exitLookupFailed)
            #expect(identity.fingerprint.seed != profile.fingerprint.seed)
            #expect(identity.fingerprint.timeZone == "Asia/Tokyo")
            #expect(try fixture.saved(profile) == profile)
            #expect(!fixture.store.pendingIdentityReset(profile.id))
            #expect(fixture.exists(fixture.data(profile, "Default/Network/Cookies")))
            #expect(fixture.exists(fixture.cache(profile, "Default/Cache/Cache_Data/index")))

            // The edit was discarded: the next launch keeps the site data.
            try await fixture.coordinator.start(profile.id)
            #expect(fixture.exists(fixture.data(profile, "Default/Network/Cookies")))
            #expect(fixture.exists(fixture.cache(profile, "Default/Cache/Cache_Data/index")))
        }
    }

    @Test("A stopped Profile's saved new identity clears its site data; the mark stays until that succeeds")
    func stoppedReset() async throws {
        let fixture = try CoordinatorFixture("coordinator-stopped-reset")
        let profile = try fixture.add(11623)
        try fixture.writeSiteData(profile)
        let directory = fixture.runtime.dataDirectory(for: profile.id)
        // Something else holds the data directory, so clearing it has to wait.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/bash")
        holder.arguments = ["-c", "sleep 30", "anybrowser-test", "--user-data-dir=\(directory.path)"]
        try holder.run()
        defer { holder.terminate() }
        let lock = directory.appendingPathComponent("SingletonLock").path
        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: "host-\(holder.processIdentifier)")
        try await fixture.run([profile]) {
            var renewed = profile
            renewed.fingerprint = try await fixture.coordinator.generateIdentity(for: profile).fingerprint
            try fixture.coordinator.saveNewIdentity(renewed)
            #expect(try fixture.saved(profile).fingerprint == renewed.fingerprint)
            #expect(fixture.store.pendingIdentityReset(profile.id))
            await #expect(throws: ProfileError.self) { try await fixture.coordinator.clearPendingSiteData(profile.id) }
            #expect(fixture.store.pendingIdentityReset(profile.id))
            #expect(fixture.exists(fixture.data(profile, "Default/Network/Cookies")))
            // AnyBrowser quitting now loses nothing: the mark is in the database.
            #expect(try ProfileStore(directory: fixture.fake.storage).pendingIdentityReset(profile.id))

            holder.terminate()
            holder.waitUntilExit()
            try FileManager.default.removeItem(atPath: lock)
            #expect(try await fixture.coordinator.clearPendingSiteData(profile.id))
            #expect(!fixture.store.pendingIdentityReset(profile.id))
            #expect(!fixture.exists(fixture.data(profile, "Default/Network/Cookies")))
            #expect(!fixture.exists(fixture.runtime.cacheDirectory(for: profile.id)))
            #expect(fixture.exists(fixture.data(profile, "Default/Preferences")))
        }
    }

    @Test("A pending reset is carried out by the next launch and cleared only once the browser is up")
    func resetAtLaunch() async throws {
        let fixture = try CoordinatorFixture("coordinator-launch-reset")
        let profile = try fixture.add(11624)
        try fixture.writeSiteData(profile)
        try await fixture.run([profile]) {
            var renewed = profile
            renewed.fingerprint = try await fixture.coordinator.generateIdentity(for: profile).fingerprint
            try fixture.coordinator.saveNewIdentity(renewed)
            // The browser dies before it is ready.
            try fixture.fake.configure(profile, ["exit_ms": "0", "exit_code": "3"])
            await #expect(throws: (any Error).self) { try await fixture.coordinator.start(profile.id) }
            #expect(fixture.store.pendingIdentityReset(profile.id))
            #expect(fixture.store.lastLaunchFingerprint(profile.id) == nil)

            // A later AnyBrowser on the same database still knows.
            let reopened = try ProfileStore(directory: fixture.fake.storage)
            let later = LaunchCoordinator(store: reopened, runtime: fixture.fake.makeRuntime())
            later.proxyPreflight = { _ in nil }
            try fixture.fake.configure(profile, [:])
            try fixture.writeSiteData(profile)
            let outcome = try await later.start(profile.id)
            #expect(outcome.startedFresh && outcome.warnings.isEmpty)
            #expect(!reopened.pendingIdentityReset(profile.id))
            #expect(reopened.lastLaunchFingerprint(profile.id) == renewed.fingerprint)
            #expect(!fixture.exists(fixture.data(profile, "Default/Network/Cookies")))
            #expect(!fixture.exists(fixture.runtime.cacheDirectory(for: profile.id)))
            #expect(fixture.exists(fixture.data(profile, "Default/Preferences")))
            try await later.stop(profile.id)
        }
    }

    @Test("A running Profile's new identity is applied by the restart, which clears the old data first")
    func runningReset() async throws {
        let fixture = try CoordinatorFixture("coordinator-running-reset")
        let profile = try fixture.add(11625)
        try fixture.fake.configure(profile, [:])
        try await fixture.run([profile]) {
            try await fixture.coordinator.start(profile.id)
            let first = try #require(fixture.pid(profile))
            try fixture.writeSiteData(profile)
            var renewed = profile
            renewed.fingerprint = try await fixture.coordinator.generateIdentity(for: profile).fingerprint
            try fixture.coordinator.saveNewIdentity(renewed)
            // Nothing is cleared while the old identity's pages are open.
            #expect(try await fixture.coordinator.clearPendingSiteData(profile.id) == false)
            #expect(fixture.exists(fixture.data(profile, "Default/Network/Cookies")))
            #expect(fixture.coordinator.hasPendingRestart(profile.id))
            #expect(fixture.store.pendingIdentityReset(profile.id))

            try await fixture.coordinator.restart(profile.id)
            #expect(try #require(fixture.pid(profile)) != first)
            #expect(!fixture.store.pendingIdentityReset(profile.id))
            #expect(!fixture.exists(fixture.data(profile, "Default/Network/Cookies")))
            #expect(!fixture.exists(fixture.cache(profile, "Default/Cache/Cache_Data/index")))
            #expect(!fixture.coordinator.hasPendingRestart(profile.id))
            let methods = fixture.fake.commands(profile).compactMap { $0["method"] as? String }
            #expect(!methods.contains("Storage.clearDataForOrigin") && !methods.contains("Network.deleteCookies"))
        }
    }

    @Test("A changed seed or platform warns API launches, follows the user's choice, and is asked about once")
    func fingerprintChange() async throws {
        let fixture = try CoordinatorFixture("coordinator-fingerprint")
        let profile = try fixture.add(11626)
        let fresh = try fixture.add(11627)
        let cookies = fixture.data(profile, "Default/Network/Cookies")
        try await fixture.run([profile, fresh]) {
            let coordinator = fixture.coordinator
            try await coordinator.start(profile.id)
            #expect(fixture.store.lastLaunchFingerprint(profile.id) == profile.fingerprint)
            try await coordinator.stop(profile.id)
            try fixture.write(cookies)
            // Other fields do not count.
            try fixture.edit(profile) { $0.fingerprint.language = "de-DE" }
            #expect(!coordinator.fingerprintChangedSinceLastLaunch(profile.id))

            try fixture.edit(profile) { $0.fingerprint.seed = testPort(11626) + 50_000 }
            #expect(coordinator.fingerprintChangedSinceLastLaunch(profile.id))
            let warned = try await coordinator.start(profile.id)
            #expect(warned.warnings.contains { $0.contains("指纹种子或平台自上次启动后已改变") })
            #expect(fixture.exists(cookies))
            #expect(!coordinator.fingerprintChangedSinceLastLaunch(profile.id))
            try await coordinator.stop(profile.id)

            try fixture.edit(profile) { $0.fingerprint.platform = .windows }
            #expect(coordinator.fingerprintChangedSinceLastLaunch(profile.id))
            let cleared = try await coordinator.start(profile.id, fingerprintChange: .clearSiteData)
            #expect(cleared.warnings.isEmpty)
            #expect(!fixture.exists(cookies))
            try await coordinator.stop(profile.id)

            try fixture.write(cookies)
            try fixture.edit(profile) { $0.fingerprint.seed = testPort(11626) + 60_000 }
            let kept = try await coordinator.start(profile.id, fingerprintChange: .keepSiteData)
            #expect(kept.warnings.isEmpty)
            #expect(fixture.exists(cookies))
            #expect(!coordinator.fingerprintChangedSinceLastLaunch(profile.id))
            try await coordinator.stop(profile.id)

            // A pending reset clears the data anyway; there is nothing to ask.
            try fixture.edit(profile) { $0.fingerprint.seed = testPort(11626) + 70_000 }
            try fixture.store.setPendingIdentityReset(profile.id, true)
            #expect(!coordinator.fingerprintChangedSinceLastLaunch(profile.id))
            // Nor before a Profile's first recorded launch.
            try fixture.edit(fresh) { $0.fingerprint.seed = testPort(11627) + 50_000 }
            #expect(!coordinator.fingerprintChangedSinceLastLaunch(fresh.id))
        }
    }

    @Test("Polling only looks at running, failed, unknown and just-exited Profiles")
    func pollingTargets() async throws {
        let fixture = try CoordinatorFixture("coordinator-polling")
        fixture.coordinator.relaunchWindow = 0.6
        let first = try fixture.add(11628)
        let second = try fixture.add(11629)
        let idle = try fixture.add(11630)
        try await fixture.run([first, second, idle]) {
            let coordinator = fixture.coordinator
            #expect(Set(await coordinator.refreshRunning()) == [first.id, second.id, idle.id])
            #expect(await coordinator.refreshRunning() == [])
            try await coordinator.start(first.id)
            #expect(await coordinator.refreshRunning() == [first.id])
            try await coordinator.stop(first.id)
            #expect(await coordinator.refreshRunning() == [])

            // An exit nobody asked for: the browser may be relaunching itself.
            try await coordinator.start(second.id)
            kill(try #require(fixture.pid(second)), SIGKILL)
            #expect(await fixture.fake.eventually { fixture.runtime.status(for: second.id) == .stopped })
            #expect(await coordinator.refreshRunning() == [second.id])
            try await Task.sleep(nanoseconds: 700_000_000)
            #expect(await coordinator.refreshRunning() == [])

            // A Profile added later is looked at once.
            let added = try fixture.add(11648)
            #expect(await coordinator.refreshRunning() == [added.id])
        }
    }

    @Test("Monitoring runs once however often it is started, and follows a browser that relaunched itself")
    func monitoring() async throws {
        let fixture = try CoordinatorFixture("coordinator-monitor")
        let profile = try fixture.add(11631)
        try fixture.fake.configure(profile, ["relaunch_ms": "2000"])
        try await fixture.run([profile]) {
            let coordinator = fixture.coordinator
            try await coordinator.start(profile.id)
            let first = try #require(fixture.pid(profile))
            let before = coordinator.refreshes
            coordinator.startMonitoring(every: 0.2)
            coordinator.startMonitoring(every: 0.2)
            #expect(coordinator.isMonitoring)
            #expect(await fixture.fake.eventually(10) {
                fixture.pid(profile).map { $0 != first } == true
            })
            let rounds = coordinator.refreshes - before
            try await Task.sleep(nanoseconds: 1_000_000_000)
            // One loop polls about five times a second.
            #expect((coordinator.refreshes - before) - rounds <= 7)
            coordinator.stopMonitoring()
            #expect(!coordinator.isMonitoring)
        }
    }

    @Test("App Nap stays away while a browser runs or the automation API listens")
    func appNap() async throws {
        let fixture = try CoordinatorFixture("coordinator-nap")
        let profile = try fixture.add(11632)
        try await fixture.run([profile]) {
            let coordinator = fixture.coordinator
            #expect(!coordinator.holdsActivity)
            try await coordinator.start(profile.id)
            #expect(coordinator.holdsActivity)
            try await coordinator.stop(profile.id)
            #expect(!coordinator.holdsActivity)
            #expect(await coordinator.automation.save(AutomationConfiguration(enabled: true, port: testPort(9460), token: automationTestToken)) == nil)
            #expect(coordinator.automation.status == .listening(testPort(9460)))
            #expect(coordinator.holdsActivity)
            #expect(await coordinator.automation.save(AutomationConfiguration(enabled: false, port: testPort(9460), token: automationTestToken)) == nil)
            #expect(!coordinator.holdsActivity)
        }
    }

    @Test("An outdated start of the automation server never wins over newer settings")
    func automationGenerations() async throws {
        let fixture = try CoordinatorFixture("coordinator-generations")
        let host = fixture.coordinator.automation
        let (first, overtaken, latest) = (testPort(9461), testPort(9462), testPort(9463))
        try await fixture.run([]) {
            #expect(await host.save(AutomationConfiguration(enabled: true, port: first, token: automationTestToken)) == nil)
            #expect(host.status == .listening(first))
            // The second change starts while the first still waits for the old server to stop.
            let older = Task { await host.save(AutomationConfiguration(enabled: true, port: overtaken, token: automationTestToken)) }
            let newer = Task { await host.save(AutomationConfiguration(enabled: true, port: latest, token: automationTestToken)) }
            _ = await (older.value, newer.value)
            #expect(host.status == .listening(latest))
            #expect(host.configuration?.port == latest)
            #expect(listening(latest))
            #expect(!listening(overtaken) && !listening(first))

            #expect(await host.save(AutomationConfiguration(enabled: false, port: latest, token: automationTestToken)) == nil)
            #expect(host.status == .stopped)
            #expect(!listening(latest) && !listening(overtaken) && !listening(first))
        }
    }

    @Test("Launch maintenance purges Profiles 30 days in the recycle bin and cache directories nobody owns")
    func launchMaintenance() async throws {
        let fixture = try CoordinatorFixture("coordinator-maintenance")
        let trashed = try fixture.add(11633)
        let kept = try fixture.add(11634)
        try fixture.writeSiteData(trashed)
        try fixture.writeSiteData(kept)
        try fixture.write(ProfileExtensions.root(in: fixture.fake.storage, for: trashed.id).appendingPathComponent("PasskeyBox/x"))
        let orphan = UUID()
        try fixture.write(fixture.runtime.cacheDirectory(for: orphan).appendingPathComponent("Default/Cache/index"))
        try fixture.coordinator.trash(trashed.id)
        try await fixture.run([]) {
            // Not yet 30 days: only the orphaned cache goes.
            #expect(await fixture.coordinator.performLaunchMaintenance() == [])
            #expect(fixture.store.trashed.map(\.id) == [trashed.id])
            #expect(fixture.exists(fixture.data(trashed, "Default/Network/Cookies")))
            #expect(fixture.exists(fixture.runtime.cacheDirectory(for: trashed.id)))
            #expect(!fixture.exists(fixture.runtime.cacheDirectory(for: orphan)))

            // A cache that cannot be deleted is reported and stops nothing else.
            let linked = UUID()
            let outside = fixture.fake.root.appendingPathComponent("Outside", isDirectory: true)
            try fixture.write(outside.appendingPathComponent("keep"))
            try FileManager.default.createSymbolicLink(at: fixture.runtime.cacheDirectory(for: linked), withDestinationURL: outside)
            let problems = await fixture.coordinator.performLaunchMaintenance(now: Date().addingTimeInterval(31 * 86400))
            #expect(problems.count == 1)
            #expect(fixture.store.trashed.isEmpty)
            #expect(!fixture.exists(fixture.runtime.dataDirectory(for: trashed.id)))
            #expect(!fixture.exists(fixture.runtime.cacheDirectory(for: trashed.id)))
            #expect(!fixture.exists(ProfileExtensions.root(in: fixture.fake.storage, for: trashed.id)))
            #expect(fixture.exists(fixture.data(kept, "Default/Network/Cookies")))
            #expect(fixture.exists(fixture.runtime.cacheDirectory(for: kept.id)))
            #expect(fixture.exists(outside.appendingPathComponent("keep")))
        }
    }

    @Test("Removing a Profile refuses while it runs and deletes what was asked once the record is gone")
    func removal() async throws {
        let fixture = try CoordinatorFixture("coordinator-remove")
        let profile = try fixture.add(11636)
        try await fixture.run([profile]) {
            try await fixture.coordinator.start(profile.id)
            await #expect(throws: ProfileError.self) {
                try await fixture.coordinator.remove(profile.id, deletingBrowserData: true)
            }
            #expect(throws: ProfileError.self) { try fixture.coordinator.trash(profile.id) }
            try await fixture.coordinator.stop(profile.id)
            try fixture.writeSiteData(profile)
            var notified = false
            let problem = try await fixture.coordinator.remove(profile.id, deletingBrowserData: true) {
                notified = !fixture.store.profiles.contains { $0.id == profile.id }
            }
            #expect(problem == nil)
            #expect(notified)
            #expect(!fixture.exists(fixture.runtime.dataDirectory(for: profile.id)))
            #expect(!fixture.exists(fixture.runtime.cacheDirectory(for: profile.id)))
            #expect(!fixture.coordinator.isBusy(profile.id))
        }
    }

    // MARK: Exit review

    private static let tokyo = ProxyExit(ip: "203.0.113.5", countryCode: "JP", city: "Tokyo", timeZone: "Asia/Tokyo", languages: ["ja-JP"])

    @Test("A launch warns when the proxy exit does not match the time zone and language, reusing a recent exit")
    func exitReview() async throws {
        let fixture = try CoordinatorFixture("coordinator-exit")
        var lookups = 0
        fixture.coordinator.exitLookup = { _ in
            lookups += 1
            return Self.tokyo
        }
        let profile = try fixture.add(11637) {
            $0.proxy = "127.0.0.1:9"
            $0.fingerprint.timeZone = "America/New_York"
            $0.fingerprint.language = "en-US"
        }
        let direct = try fixture.add(11638) { $0.fingerprint.timeZone = "America/New_York" }
        try await fixture.run([profile, direct]) {
            let coordinator = fixture.coordinator
            let outcome = try await coordinator.start(profile.id)
            #expect(lookups == 1)
            #expect(outcome.warnings.contains { $0.contains("Asia/Tokyo") && $0.contains("America/New_York") })
            #expect(outcome.warnings.contains { $0.contains("ja-JP") })
            #expect(coordinator.lastExit(for: profile.id)?.exit == Self.tokyo)
            try await coordinator.stop(profile.id)

            // Within 30 minutes the recorded exit serves.
            let again = try await coordinator.start(profile.id)
            #expect(lookups == 1)
            #expect(again.warnings.contains { $0.contains("Asia/Tokyo") })
            try await coordinator.stop(profile.id)

            try coordinator.proxyLibrary.recordExit(Self.tokyo, forProfile: profile.id, at: Date().addingTimeInterval(-31 * 60))
            try await coordinator.start(profile.id)
            #expect(lookups == 2)
            try await coordinator.stop(profile.id)

            // Without a proxy there is nothing to review.
            #expect(try await coordinator.start(direct.id).warnings.isEmpty)
            #expect(lookups == 2)
        }
    }

    @Test("A slow exit lookup never holds up the launch; what it finds arrives as a late warning")
    func slowExitReview() async throws {
        let fixture = try CoordinatorFixture("coordinator-exit-slow")
        fixture.coordinator.exitLookup = { _ in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return Self.tokyo
        }
        let profile = try fixture.add(11639) {
            $0.proxy = "127.0.0.1:9"
            $0.fingerprint.timeZone = "America/New_York"
        }
        let failing = try fixture.add(11640) { $0.proxy = "127.0.0.1:10" }
        var late: [(profile: UUID, warnings: [String])] = []
        let subscription = fixture.coordinator.lateWarnings.sink { late.append($0) }
        defer { subscription.cancel() }
        try await fixture.run([profile, failing]) {
            let began = Date()
            let outcome = try await fixture.coordinator.start(profile.id)
            #expect(Date().timeIntervalSince(began) < 1.4)
            #expect(outcome.warnings.isEmpty)
            #expect(await fixture.fake.eventually(4) { !late.isEmpty })
            #expect(late.first?.profile == profile.id)
            #expect(late.first?.warnings.contains { $0.contains("Asia/Tokyo") } == true)

            // A lookup that fails says nothing.
            fixture.coordinator.exitLookup = { _ in nil }
            let quiet = try await fixture.coordinator.start(failing.id)
            #expect(quiet.warnings.isEmpty && quiet.startedFresh)
            #expect(fixture.coordinator.lastExit(for: failing.id) == nil)
        }
    }

    @Test("Profiles leaving through the same IP are named, and a batch looks each proxy's exit up once")
    func sharedExit() async throws {
        let fixture = try CoordinatorFixture("coordinator-exit-shared")
        var lookups = 0
        fixture.coordinator.exitLookup = { _ in
            lookups += 1
            try? await Task.sleep(nanoseconds: 300_000_000)
            return Self.tokyo
        }
        var profiles: [BrowserProfile] = []
        for port in 11641...11643 {
            profiles.append(try fixture.add(port) {
                $0.proxy = "127.0.0.1:9"
                $0.fingerprint.timeZone = "Asia/Tokyo"
                $0.fingerprint.language = "ja-JP"
            })
        }
        try await fixture.run(profiles) {
            let coordinator = fixture.coordinator
            let first = try await coordinator.startBatch(profiles.map(\.id))
            #expect(first.outcome.succeeded == 3)
            #expect(lookups == 1)
            #expect(await fixture.fake.eventually { profiles.allSatisfy { coordinator.lastExit(for: $0.id) != nil } })
            #expect(coordinator.consistencyContext(for: profiles[0].id).profilesSharingExit == ["P11642", "P11643"])
            _ = try await coordinator.stopBatch(profiles.map(\.id))

            let alone = try await coordinator.start(profiles[0].id)
            #expect(alone.warnings.contains { $0.contains("「P11642」") && $0.contains("同一个出口 IP") })
        }
    }
}
