@testable import AnyBrowserCore
import Darwin
import Foundation
import SQLite3
import Testing

// Data that must survive database restores, recycle-bin races, read-only databases and backups of
// a Profile waiting for its identity reset. Fake engine ports 11961–11969.
@Suite("Data safety", .serialized)
@MainActor
struct DataSafetyTests {
    @Test("A database restore gives recycle-bin entries 30 days again, so maintenance keeps a Profile used since")
    func restoredBinStartsAgain() async throws {
        let fixture = try CoordinatorFixture("safety-restore-bin")
        let profile = try fixture.add(11961)
        try fixture.writeSiteData(profile)
        try fixture.coordinator.trash(profile.id)
        // The daily backup made while the Profile sat in the bin.
        let backup = try fixture.store.backup(reason: "daily")
        // Taken out of the bin and used again.
        try fixture.coordinator.restore(profile.id)
        try await fixture.run([]) {
            // The backup is restored over 30 days after the Profile was trashed.
            let restoredAt = Date(timeIntervalSince1970: Date().addingTimeInterval(31 * 86400).timeIntervalSince1970.rounded())
            try ProfileStore.restoreBackup(backup, into: fixture.store.directory, now: restoredAt)
            let reopened = try ProfileStore(directory: fixture.fake.storage)
            let coordinator = LaunchCoordinator(store: reopened, runtime: fixture.fake.makeRuntime())
            #expect(reopened.trashed.map(\.id) == [profile.id])
            #expect(reopened.trashed.first?.deletedAt == restoredAt)
            #expect(await coordinator.performLaunchMaintenance(now: restoredAt).isEmpty)
            #expect(fixture.exists(fixture.data(profile, "Default/Network/Cookies")))
            #expect(reopened.trashed.map(\.id) == [profile.id])
            #expect(reopened.expiredTrash(now: restoredAt.addingTimeInterval(29 * 86400)).isEmpty)
            #expect(reopened.expiredTrash(now: restoredAt.addingTimeInterval(30 * 86400)) == [profile.id])
        }
    }

    @Test("A database restore drops pending identity resets; the changed seed is warned about instead")
    func restoreDropsPendingReset() async throws {
        let fixture = try CoordinatorFixture("safety-restore-pending")
        let profile = try fixture.add(11962)
        var other: BrowserRuntime?
        try await fixture.run([profile], runtimes: []) {
            try await fixture.coordinator.start(profile.id)
            // A new identity saved while the browser runs waits for the restart.
            var regenerated = try fixture.saved(profile)
            regenerated.fingerprint.seed = 990_001
            try fixture.coordinator.saveNewIdentity(regenerated)
            let backup = try fixture.store.backup(reason: "daily")
            try await fixture.coordinator.restart(profile.id)
            try await fixture.coordinator.stop(profile.id)
            // The new identity signs in to sites.
            try fixture.writeSiteData(profile)

            try ProfileStore.restoreBackup(backup, into: fixture.store.directory)
            let reopened = try ProfileStore(directory: fixture.fake.storage)
            let runtime = fixture.fake.makeRuntime()
            other = runtime
            let coordinator = LaunchCoordinator(store: reopened, runtime: runtime)
            coordinator.proxyPreflight = { _ in nil }
            coordinator.exitLookup = { _ in nil }
            #expect(!reopened.pendingIdentityReset(profile.id))
            #expect(reopened.profiles.first { $0.id == profile.id }?.fingerprint.seed == 990_001)
            let outcome = try await coordinator.start(profile.id)
            #expect(fixture.exists(fixture.data(profile, "Default/Network/Cookies")))
            #expect(outcome.warnings.contains { $0.hasPrefix("指纹种子或平台自上次启动后已改变") })
            try await coordinator.stop(profile.id)
        }
        if let other { try? await other.stop(profile.id, force: true) }
    }

    @Test("A Profile cannot leave the recycle bin while its purge deletes the data")
    func restoreWaitsForPurge() async throws {
        let fixture = try CoordinatorFixture("safety-purge-race")
        let profile = try fixture.add(11963)
        try fixture.writeSiteData(profile)
        try fixture.coordinator.trash(profile.id)
        try await fixture.run([]) {
            let purge = Task { try await fixture.coordinator.purge(profile.id) }
            await Task.yield()
            #expect(fixture.coordinator.isBusy(profile.id))
            #expect(throws: ProfileError.self) { try fixture.coordinator.restore(profile.id) }
            try await purge.value
            #expect(!fixture.store.profiles.contains { $0.id == profile.id })
            #expect(!fixture.store.trashed.contains { $0.id == profile.id })
            #expect(!fixture.exists(fixture.runtime.dataDirectory(for: profile.id)))
        }
    }

    @Test("A newer version's database refuses to launch a Profile waiting for its identity reset, and deletes nothing")
    func readOnlyPendingReset() async throws {
        let fixture = try CoordinatorFixture("safety-readonly-pending")
        let profile = try fixture.add(11964)
        let plain = try fixture.add(11965)
        try fixture.store.setPendingIdentityReset(profile.id, true)
        // A newer AnyBrowser migrated the database past this version's schema.
        #expect(sqlite3_exec(fixture.store.database, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
        let reopened = try ProfileStore(directory: fixture.fake.storage)
        #expect(reopened.isReadOnly)
        let runtime = fixture.fake.makeRuntime()
        let coordinator = LaunchCoordinator(store: reopened, runtime: runtime)
        coordinator.proxyPreflight = { _ in nil }
        coordinator.exitLookup = { _ in nil }
        try await fixture.run([profile, plain], runtimes: [runtime]) {
            try fixture.writeSiteData(profile)
            for _ in 0..<2 {
                await #expect(throws: ProfileError.self) { try await coordinator.start(profile.id) }
                #expect(fixture.exists(fixture.data(profile, "Default/Network/Cookies")))
                #expect(reopened.pendingIdentityReset(profile.id))
                #expect(runtime.status(for: profile.id) == .stopped)
            }
            // Other Profiles still launch.
            #expect(try await coordinator.start(plain.id).startedFresh)
            try await coordinator.stop(plain.id)
        }
    }

    @Test("Without Passkey Box an account change asks for no restart; turning it on does")
    func passkeyBoxOffIgnoresAccounts() async throws {
        let old = PasskeyBoxAccount(serverURL: "https://box.example", username: "old", password: "pw")
        let next = PasskeyBoxAccount(serverURL: "https://box.example", username: "next", password: "pw")
        var stored = BrowserProfile(name: "P", port: 9999, fingerprint: FingerprintSettings(seed: 1))
        stored.launch.loadPasskeyBox = false
        var launched = stored
        launched.passkeyBox = old
        #expect(!LaunchCoordinator.needsRestart(launched, toRun: stored, account: next))

        let fixture = try CoordinatorFixture("safety-passkey-off")
        try fixture.store.savePasskeyBoxAccount(old)
        let off = try fixture.add(11966) { $0.launch.loadPasskeyBox = false }
        try await fixture.run([off]) {
            try await fixture.coordinator.start(off.id)
            #expect(!fixture.coordinator.hasPendingRestart(off.id))
            try fixture.store.savePasskeyBoxAccount(next)
            #expect(!fixture.coordinator.hasPendingRestart(off.id))
            try fixture.edit(off) { $0.passkeyBox = PasskeyBoxAccount(serverURL: "https://box.example", username: "own", password: "pw") }
            #expect(!fixture.coordinator.hasPendingRestart(off.id))
            try fixture.edit(off) { $0.launch.loadPasskeyBox = true }
            #expect(fixture.coordinator.hasPendingRestart(off.id))
        }
    }

    @Test("Profiles on one proxy server with different credentials get their own proxy check", arguments: [false, true])
    func preflightPerCredentials(wrongFirst: Bool) async {
        let wrong = "http://alice:wrong@127.0.0.1:18080"
        let right = "http://alice:secret@127.0.0.1:18080"
        let checked = CheckLog()
        let check: (String) async -> String? = { proxy in
            checked.proxies.append(proxy)
            return proxy.contains(":wrong@") ? "代理 127.0.0.1:18080 拒绝了用户名或密码。" : nil
        }
        let cache = PreflightCache()
        var warnings: [String: String?] = [:]
        for proxy in wrongFirst ? [wrong, right] : [right, wrong] {
            warnings[proxy] = await cache.warning(for: proxy, check: check)
        }
        #expect(warnings[wrong] == .some("代理 127.0.0.1:18080 拒绝了用户名或密码。"))
        #expect(warnings[right] == .some(nil))
        // The same proxy written another way is still checked once.
        #expect(await cache.warning(for: "127.0.0.1:18080:alice:secret", check: check) == nil)
        #expect(checked.proxies.count == 2)
    }

    @Test("One-off launch arguments cannot override the Profile's fingerprint switches")
    func fingerprintSwitchesRefused() throws {
        for argument in ["--fingerprint=1", "--fingerprint", "--fingerprint-platform=windows", "--fingerprint-hardware-concurrency=4"] {
            #expect(throws: ProfileError.self, "\(argument)") { try BrowserRuntime.checkedArguments([argument]) }
        }
        let allowed = ["--mute-audio", "--fingerprinting-canvas-noise"]
        #expect(try BrowserRuntime.checkedArguments(allowed) == allowed)
    }

    @Test("A stopped Profile waiting for its identity reset loses the old site data before it is backed up")
    func backupAppliesPendingReset() async throws {
        let fixture = try CoordinatorFixture("safety-backup-pending")
        let profile = try fixture.add(11967)
        try fixture.writeSiteData(profile)
        // The mark outlived the save, as when clearing failed or AnyBrowser quit first.
        var regenerated = try fixture.saved(profile)
        regenerated.fingerprint.seed = 990_002
        try fixture.coordinator.saveNewIdentity(regenerated)
        try await fixture.run([profile]) {
            let file = fixture.fake.storage.appendingPathComponent("pending.anybrowser")
            let exported = try await fixture.coordinator.exportBackup([profile.id], to: file)
            #expect(exported.profiles.first?.browserData == true)
            #expect(!fixture.store.pendingIdentityReset(profile.id))
            // Cleared for the new identity, so its next launch does not ask to clear again.
            #expect(fixture.store.lastLaunchFingerprint(profile.id) == regenerated.fingerprint)
            #expect(!fixture.exists(fixture.data(profile, "Default/Network/Cookies")))
            #expect(fixture.exists(fixture.data(profile, "Default/Preferences")))

            let restored = try await fixture.coordinator.restoreBackup(from: file, identity: .renew)
            let copy = try #require(restored.profiles.first?.profile)
            #expect(restored.profiles.first?.browserData == true)
            let data = fixture.runtime.dataDirectory(for: copy.id)
            #expect(!fixture.exists(data.appendingPathComponent("Default/Network/Cookies")))
            #expect(fixture.exists(data.appendingPathComponent("Default/Preferences")))
        }
    }

    @Test("A running Profile waiting for its identity reset is backed up without the old identity's cookies")
    func backupSkipsRunningPendingReset() async throws {
        let fixture = try CoordinatorFixture("safety-backup-running")
        let profile = try fixture.add(11968)
        try await fixture.run([profile]) {
            try await fixture.coordinator.start(profile.id)
            var regenerated = try fixture.saved(profile)
            regenerated.fingerprint.seed = 990_003
            try fixture.coordinator.saveNewIdentity(regenerated)
            let file = fixture.fake.storage.appendingPathComponent("running.anybrowser")
            let exported = try #require(try await fixture.coordinator.exportBackup([profile.id], to: file).profiles.first)
            #expect(exported.skipped == nil && exported.cookies == 0 && !exported.browserData)
            #expect(exported.warnings == ["浏览器还在用旧身份的网站数据（重启后才清除），没有备份 Cookie 和浏览器资料。"])
            let methods = fixture.fake.commands(profile).compactMap { $0["method"] as? String }
            #expect(!methods.contains { $0.contains("Cookies") })
            #expect(fixture.store.pendingIdentityReset(profile.id))
        }
    }

    @Test("A Profile created while a restore runs does not make it skip an entry", arguments: [false, true])
    func restoreAvoidsPortsTakenMeanwhile(takesSeed: Bool) async throws {
        let fixture = try CoordinatorFixture("safety-restore-race")
        let first = try fixture.add(11969)
        let second = try fixture.add(11960)
        try fixture.writeSiteData(first)
        try fixture.writeSiteData(second)
        try await fixture.run([first, second]) {
            let file = fixture.fake.storage.appendingPathComponent("race.anybrowser")
            _ = try await fixture.coordinator.exportBackup([first.id, second.id], to: file)
            // Gone here, so the restore plans their own ports and seeds again.
            for profile in [first, second] { try fixture.store.remove(profile.id) }
            var intruder: BrowserProfile?
            let result = try await fixture.coordinator.restoreBackup(from: file, identity: .renew) { progress in
                // While the second entry's data directory is moved in, a script creates a Profile on its port.
                guard progress.completed == 1, intruder == nil else { return }
                var created = fixture.fake.profile(port: second.port, name: "API")
                created.fingerprint.seed = takesSeed ? second.fingerprint.seed : 990_004
                intruder = created
                Task { @MainActor in try? fixture.store.save(created) }
            }
            #expect(result.profiles.map(\.skipped) == [nil, nil])
            let restored = try #require(result.profiles.last?.profile)
            #expect(restored.port != second.port)
            #expect(Set(fixture.store.profiles.map(\.port)).count == fixture.store.profiles.count)
            #expect(Set(fixture.store.profiles.map(\.fingerprint.seed)).count == fixture.store.profiles.count)
            #expect(fixture.store.profiles.contains { $0.name == "API" })
            if takesSeed {
                #expect(restored.fingerprint.seed != second.fingerprint.seed)
                #expect(restored.fingerprint.seed % EngineHardwareTable.bundled.hardwarePeriod
                        == second.fingerprint.seed % EngineHardwareTable.bundled.hardwarePeriod)
            }
        }
    }
}

/// The proxies a preflight check was asked about, in order.
private final class CheckLog: @unchecked Sendable {
    var proxies: [String] = []
}
