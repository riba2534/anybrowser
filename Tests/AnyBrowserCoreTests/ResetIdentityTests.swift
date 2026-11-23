@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

// The store's whole identity reset and the coordinator's "重置且随机指纹".

@Suite("Reset identity", .serialized)
@MainActor
struct ResetIdentityTests {
    /// A Profile on a port free right now; a fixed test port can belong to another program.
    private func add(_ fixture: CoordinatorFixture, _ change: (inout BrowserProfile) -> Void = { _ in }) throws -> BrowserProfile {
        var profile = fixture.fake.profile(port: freeTestPort(), name: "Reset")
        change(&profile)
        try fixture.store.save(profile)
        return try #require(fixture.store.profiles.first { $0.id == profile.id })
    }

    @Test("A reset draws a new seed, device id, screen and font combination and locale, and keeps the rest")
    func storeDrawsANewIdentity() throws {
        let directory = try scratchDirectory("reset-identity-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let other = try store.makeDraft()
        try store.save(other)
        var profile = try store.makeDraft()
        profile.name = "Shop"
        profile.proxy = "127.0.0.1:7890"
        profile.group = "工作"
        profile.tags = ["us", "主号"]
        profile.notes = "保留"
        profile.accountStatus = .active
        profile.deviceIdentity = DeviceIdentity.mint()
        try store.save(profile)
        let before = try #require(store.profiles.first { $0.id == profile.id })
        let beforeCombination = try #require(ScreenFontCombination(before.fingerprint))
        let otherCombination = ScreenFontCombination(try #require(store.profiles.first { $0.id == other.id }).fingerprint)
        let locale = try #require(IdentitySampler.LocaleHint(language: "ja-JP", timeZone: "Asia/Tokyo"))

        let after = try store.resetIdentity(profile.id, locale: locale)

        // The identity four-tuple is new: seed, device id, screen and font combination, locale.
        #expect(after.id == before.id)
        #expect(after.fingerprint.seed != before.fingerprint.seed)
        #expect(after.deviceIdentity != before.deviceIdentity)
        #expect(DeviceIdentity.isValid(try #require(after.deviceIdentity)))
        let afterCombination = try #require(ScreenFontCombination(after.fingerprint))
        #expect(afterCombination != beforeCombination)
        #expect(afterCombination != otherCombination)
        #expect(after.fingerprint.language == "ja-JP")
        #expect(after.fingerprint.timeZone == "Asia/Tokyo")
        // Memory and the privacy posture are re-derived with the seed.
        #expect(after.fingerprint.deviceMemory != nil)
        #expect(after.fingerprint.adjustments.contains(.canvas))
        #expect(after.fingerprint.adjustments.contains(.clientRects))
        // The Profile's own fields stay.
        #expect(after.name == before.name)
        #expect(after.port == before.port)
        #expect(after.proxy == before.proxy)
        #expect(after.group == before.group)
        #expect(after.tags == before.tags)
        #expect(after.notes == before.notes)
        #expect(after.accountStatus == before.accountStatus)
        #expect(store.profiles.first { $0.id == before.id } == after)
    }

    @Test("A running Profile is stopped first, its data deleted, and the new identity starts")
    func stopsAndClearsBeforeTheNewIdentity() async throws {
        let fixture = try CoordinatorFixture("reset-running")
        let profile = try add(fixture)
        try fixture.writeSiteData(profile)
        try await fixture.run([profile]) {
            try await fixture.coordinator.start(profile.id)
            let old = try fixture.saved(profile)
            let oldPid = try #require(fixture.pid(profile))
            let oldSeed = old.fingerprint.seed

            var phases: [LaunchCoordinator.ResetPhase] = []
            let outcome = try await fixture.coordinator.resetAndRandomize(old.id) { phases.append($0) }

            #expect(phases == [.stopping, .clearing, .generating, .saving, .starting])
            #expect(!isAlive(oldPid))
            let fresh = try fixture.saved(profile)
            #expect(fresh.fingerprint.seed != oldSeed)
            let newPid = try #require(fixture.pid(fresh))
            #expect(newPid != oldPid)
            #expect(ProcessInspection.arguments(newPid)?.contains("--fingerprint=\(fresh.fingerprint.seed)") == true)
            // The old identity's cookies went; preferences stay.
            #expect(!fixture.exists(fixture.data(fresh, "Default/Network/Cookies")))
            #expect(fixture.exists(fixture.data(fresh, "Default/Preferences")))
            #expect(!fixture.store.pendingIdentityReset(fresh.id))
            #expect(outcome.warnings.isEmpty)
            try await fixture.coordinator.stop(fresh.id, force: true)
        }
    }

    @Test("A browser that ignores the stop is force stopped, with a warning")
    func forceStopsAStubbornBrowser() async throws {
        let fixture = try CoordinatorFixture("reset-force")
        let profile = try add(fixture)
        try fixture.fake.configure(profile, ["ignore_term": "1"])
        try await fixture.run([profile]) {
            try await fixture.coordinator.start(profile.id)
            let oldPid = try #require(fixture.pid(profile))
            let oldSeed = try fixture.saved(profile).fingerprint.seed

            let outcome = try await fixture.coordinator.resetAndRandomize(profile.id)

            #expect(!isAlive(oldPid))
            #expect(outcome.warnings.contains { $0.contains("已强制结束") })
            let fresh = try fixture.saved(profile)
            #expect(fresh.fingerprint.seed != oldSeed)
            if case .running = fixture.coordinator.state(for: fresh.id) {} else {
                Issue.record("Not running after the reset: \(fixture.coordinator.state(for: fresh.id))")
            }
            try await fixture.coordinator.stop(fresh.id, force: true)
        }
    }

    @Test("A start that fails after the reset names the stage and keeps the saved new identity")
    func startFailureNamesTheStage() async throws {
        let fixture = try CoordinatorFixture("reset-start-failure")
        let profile = try add(fixture) { $0.launch.extensionDirectories = ["/nonexistent/anybrowser-extension"] }
        let oldSeed = profile.fingerprint.seed
        try await fixture.run([profile]) {
            let error = await #expect(throws: (any Error).self) {
                try await fixture.coordinator.resetAndRandomize(profile.id)
            }
            #expect(error?.localizedDescription.contains("「以新身份启动」阶段失败") == true)
            let fresh = try fixture.saved(profile)
            #expect(fresh.fingerprint.seed != oldSeed)
            // The data was cleared and the mark stays, so the next launch clears again.
            #expect(fixture.store.pendingIdentityReset(fresh.id))
            #expect(!fixture.coordinator.isBusy(fresh.id))
        }
    }
}