@testable import AnyBrowserCore
import Foundation
import Testing

@Suite("Editor drafts")
struct ProfileDraftTests {
    private func saved(_ change: (inout BrowserProfile) -> Void = { _ in }) -> BrowserProfile {
        var profile = BrowserProfile(id: UUID(uuidString: "6F0C1B53-3E7C-4D51-9B0E-63C5F33A7A10")!, name: "Shop",
                                     port: 9222, fingerprint: FingerprintSettings(seed: 4242), proxy: "127.0.0.1:7890",
                                     group: "A", tags: ["one"])
        change(&profile)
        return profile
    }

    @Test("A new draft counts as changed only once it differs from the draft as generated")
    func newDraftSnapshot() {
        let generated = ProfileDraft(saved())
        let origin = DraftOrigin(new: generated)
        #expect(!origin.isSaved)
        #expect(!origin.hasChanges(generated, saved: nil))

        var edited = generated
        edited.seedText = "17"
        #expect(origin.hasChanges(edited, saved: nil))
        edited.seedText = generated.seedText
        #expect(!origin.hasChanges(edited, saved: nil))
        edited.profile.notes = "x"
        #expect(origin.hasChanges(edited, saved: nil))

        // A saved Profile is compared with what the store holds now.
        let stored = saved()
        let savedOrigin = DraftOrigin(saved: stored)
        #expect(savedOrigin.isSaved)
        #expect(!savedOrigin.hasChanges(ProfileDraft(stored), saved: stored))
        #expect(savedOrigin.hasChanges(ProfileDraft(stored), saved: saved { $0.notes = "API" }))
    }

    @Test("Fields count as changed as the editor shows them")
    func changedFields() {
        let base = ProfileDraft(saved())
        var draft = base
        #expect(draft.changedFields(from: base).isEmpty)
        draft.portText = "9300"
        draft.cpuText = "8"
        draft.profile.tags = ["one", "two"]
        draft.profile.accountStatus = .limited
        #expect(draft.changedFields(from: base) == [.port, .fingerprint, .tags, .accountStatus])
        var reset = base
        reset.resetsSiteData = true
        #expect(reset.changedFields(from: base) == [.fingerprint])
        var launch = base
        launch.profile.launch.restoreSession = true
        #expect(launch.changedFields(from: base) == [.launch])
    }

    @Test("Without edits the draft follows a change saved elsewhere")
    func refreshesWithoutEdits() {
        let stored = saved()
        let origin = DraftOrigin(saved: stored)
        #expect(origin.sync(ProfileDraft(stored), with: stored) == .unchanged)
        let incoming = saved { $0.proxy = "socks5://10.0.0.1:1080"; $0.fingerprint.seed = 77 }
        #expect(origin.sync(ProfileDraft(stored), with: incoming) == .refreshed(ProfileDraft(incoming)))
    }

    @Test("Edits that already show the change are absorbed without asking")
    func absorbsMatchingEdits() throws {
        let stored = saved()
        let origin = DraftOrigin(saved: stored)
        var draft = ProfileDraft(stored)
        draft.profile.notes = "typed"
        // The batch bar saved the group and put the same value into the draft.
        draft.profile.group = "B"
        let incoming = saved { $0.group = "B" }
        guard case .absorbed(let merged) = origin.sync(draft, with: incoming) else {
            Issue.record("Expected the change to be absorbed")
            return
        }
        #expect(merged == draft)
        #expect(origin.hasChanges(merged, saved: incoming))
        #expect(merged.changedFields(from: ProfileDraft(incoming)) == [.notes])
    }

    @Test("Edits plus a change elsewhere ask the user; keeping the edits takes the rest")
    func conflictsKeepEditsAndTakeTheRest() {
        let stored = saved()
        let origin = DraftOrigin(saved: stored)
        var draft = ProfileDraft(stored)
        draft.profile.name = "Mine"
        draft.seedText = "99"
        let incoming = saved { $0.proxy = "http://10.0.0.2:8080"; $0.tags = ["api"]; $0.port = 9333 }

        guard case let .conflict(kept, unseen) = origin.sync(draft, with: incoming) else {
            Issue.record("Expected a conflict")
            return
        }
        #expect(unseen == [.proxy, .tags, .port])
        #expect(kept.profile.name == "Mine")
        #expect(kept.seedText == "99")
        #expect(kept.profile.proxy == "http://10.0.0.2:8080")
        #expect(kept.profile.tags == ["api"])
        #expect(kept.portText == "9333")
        #expect(kept.profile.port == 9333)
        // Once kept, the draft's own edits are what is left to save.
        #expect(kept.changedFields(from: ProfileDraft(incoming)) == [.name, .fingerprint])
    }

    @Test("The same field changed to different values on both sides is a conflict")
    func sameFieldConflicts() {
        let stored = saved()
        let origin = DraftOrigin(saved: stored)
        var draft = ProfileDraft(stored)
        draft.profile.proxy = "127.0.0.1:1111"
        let incoming = saved { $0.proxy = "127.0.0.1:2222" }
        guard case let .conflict(kept, unseen) = origin.sync(draft, with: incoming) else {
            Issue.record("Expected a conflict")
            return
        }
        #expect(unseen == [.proxy])
        #expect(kept.profile.proxy == "127.0.0.1:1111")
    }

    @Test("Validation reads the typed numbers")
    func validation() throws {
        var draft = ProfileDraft(saved())
        draft.portText = " 9400 "
        draft.seedText = "12"
        draft.cpuText = ""
        draft.profile.name = "  Name  "
        let value = try draft.validated()
        #expect(value.port == 9400)
        #expect(value.fingerprint.seed == 12)
        #expect(value.fingerprint.cpuCount == nil)
        #expect(value.name == "Name")
        #expect(draft.effectiveSeed == 12)
        draft.seedText = "0"
        #expect(throws: ProfileError.self) { try draft.validated() }
        #expect(draft.effectiveSeed == 4242)
        draft.seedText = "1"
        draft.cpuText = "300"
        #expect(throws: ProfileError.self) { try draft.validated() }
    }
}
