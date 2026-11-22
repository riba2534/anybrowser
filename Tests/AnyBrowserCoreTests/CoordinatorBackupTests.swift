@testable import AnyBrowserCore
import Foundation
import Testing

/// A full backup or restore holds the Profiles it works on, so nothing starts, stops or edits
/// them while their files are copied, and batches wait for it.
@MainActor
@Suite(.serialized)
struct CoordinatorBackupTests {
    @Test("A backup keeps its Profiles busy until it ends and refuses while they are busy")
    func exportHoldsProfiles() async throws {
        let fixture = try CoordinatorFixture("coordinator-backup-export")
        let profile = try fixture.add(11690)
        let other = try fixture.add(11691)
        try await fixture.run([profile, other]) {
            let coordinator = fixture.coordinator
            let file = fixture.fake.storage.appendingPathComponent("backup.anybrowser")
            var seen: [Bool] = []
            var otherSeen: [Bool] = []
            _ = try await coordinator.exportBackup([profile.id], to: file) { _ in
                seen.append(coordinator.isBusy(profile.id))
                otherSeen.append(coordinator.isBusy(other.id))
            }
            #expect(!seen.isEmpty && seen.allSatisfy { $0 })
            #expect(otherSeen.allSatisfy { !$0 })
            #expect(coordinator.archiving.isEmpty && !coordinator.isBusy(profile.id))

            coordinator.removing.insert(profile.id)
            await #expect(throws: ProfileError.self) { _ = try await coordinator.exportBackup([profile.id], to: file) }
            coordinator.removing.remove(profile.id)
        }
    }

    @Test("A restore keeps the Profiles it adds busy, not the ones that were there")
    func restoreHoldsAddedProfiles() async throws {
        let fixture = try CoordinatorFixture("coordinator-backup-restore")
        let profile = try fixture.add(11692)
        try await fixture.run([profile]) {
            let coordinator = fixture.coordinator
            let file = fixture.fake.storage.appendingPathComponent("restore.anybrowser")
            _ = try await coordinator.exportBackup([profile.id], to: file)
            var addedBusy: [Bool] = []
            var existingBusy: [Bool] = []
            let result = try await coordinator.restoreBackup(from: file, identity: .renew) { _ in
                for added in fixture.store.profiles where added.id != profile.id {
                    addedBusy.append(coordinator.isBusy(added.id))
                }
                existingBusy.append(coordinator.isBusy(profile.id))
            }
            let restored = try #require(result.profiles.first?.profile)
            #expect(restored.id != profile.id)
            #expect(!addedBusy.isEmpty && addedBusy.allSatisfy { $0 })
            #expect(existingBusy.allSatisfy { !$0 })
            #expect(coordinator.restoreBaseline == nil && !coordinator.isBusy(restored.id))
        }
    }

    @Test("Batches and backups wait for each other")
    func batchesAndBackupsExclude() async throws {
        let fixture = try CoordinatorFixture("coordinator-backup-batch")
        let profile = try fixture.add(11693)
        try await fixture.run([profile]) {
            let coordinator = fixture.coordinator
            coordinator.archiving = [UUID()]
            await #expect(throws: ProfileError.self) { _ = try await coordinator.startBatch([profile.id]) }
            coordinator.archiving = []
            coordinator.restoreBaseline = []
            await #expect(throws: ProfileError.self) { _ = try await coordinator.stopBatch([profile.id]) }
            #expect(coordinator.isBusy(profile.id))
            coordinator.restoreBaseline = nil
            #expect(!coordinator.isBusy(profile.id))
        }
    }
}
