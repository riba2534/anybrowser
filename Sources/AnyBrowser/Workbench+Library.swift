import AnyBrowserCore
import Combine
import SwiftUI

/// Sidebar search, grouping, sorting and multi-selection.
@MainActor
final class LibraryModel: ObservableObject {
    @Published var query = ""
    @Published var sort: ProfileLibrary.Sort = .created
    /// Profiles picked with ⌘-click for batch actions; separate from the Profile being edited.
    @Published var selection: Set<UUID> = []
    @Published var batchRunning = false
    /// Profiles whose files are being deleted; `Workbench.isBusy` treats them as busy.
    @Published var removing: Set<UUID> = []

    func toggle(_ id: UUID) {
        if selection.remove(id) == nil { selection.insert(id) }
    }
}

extension Workbench {
    var librarySections: [ProfileLibrary.Section] {
        ProfileLibrary.sections(profiles, query: library.query, sort: library.sort,
                                lastLaunched: store?.lastLaunched ?? [:])
    }

    var profileGroups: [String] { ProfileLibrary.groups(profiles) }

    /// Saved Profiles picked for batch actions, in creation order.
    var batchSelection: [BrowserProfile] { profiles.filter { library.selection.contains($0.id) } }

    // MARK: Clone

    /// Reached through `request(.clone)`, which asks about unsaved edits first.
    func cloneSaved() {
        guard let store, let id = selectedID else { return }
        do {
            let copy = try store.saveClone(of: id)
            draft = ProfileDraft(copy)
            notice = Notice(text: "已复制为「\(copy.name)」。浏览器资料没有复制。")
        } catch {
            show(error)
        }
    }

    // MARK: Import and export

    func importProfiles() {
        guard let store else { return }
        guard let url = FilePanels.file(title: "导入 Profile",
                                        message: "选择 AnyBrowser 导出的 Profile 文件。浏览器资料不会导入。") else { return }
        do {
            let result = try store.importProfiles(from: ProfileLibrary.contents(of: url))
            var text = "已导入 \(result.profiles.count) 个 Profile"
            if result.skipped > 0 { text += "，跳过 \(result.skipped) 个无效条目" }
            text += "。"
            let review = ProfileLibrary.importReview(result.profiles)
            notice = Notice(text: text + (review ?? ""), isError: result.profiles.isEmpty || review != nil)
            if draft == nil, let first = result.profiles.first { draft = ProfileDraft(first) }
        } catch {
            show(error)
        }
    }

    func exportProfiles(includeSecrets: Bool) {
        let exported = profiles
        guard !exported.isEmpty else { return }
        guard let url = FilePanels.saveLocation(
            title: includeSecrets ? "导出 Profile（含密码）" : "导出 Profile",
            message: includeSecrets
                ? "文件包含代理和 Passkey Box 的账号密码，请妥善保管。浏览器资料不会导出。"
                : "代理账号密码和 Profile 自己的 Passkey Box 账号不会导出。浏览器资料不会导出。",
            name: "AnyBrowser Profiles.json") else { return }
        do {
            try ProfileLibrary.writePrivately(ProfileLibrary.export(exported, includeSecrets: includeSecrets), to: url)
            notice = Notice(text: "已导出 \(exported.count) 个 Profile\(includeSecrets ? "，文件包含密码" : "")。")
        } catch {
            show(error)
        }
    }

    // MARK: Batch actions

    func createBatch(_ batch: ProfileLibrary.BatchRequest) async throws -> [BrowserProfile] {
        guard let store else { throw ProfileError.invalid(Self.storeUnavailable) }
        var batch = batch
        batch.locale = await localeHint(for: batch.proxy)
        return try store.saveBatch(batch)
    }

    /// Selects the first new Profile once the batch sheet has closed.
    func showCreated(_ created: [BrowserProfile]) {
        guard let first = created.first else { return }
        request(.profile(first.id))
        notice = Notice(text: "已新建 \(created.count) 个 Profile。")
    }

    func startBatch() async {
        let startable = { (profile: BrowserProfile) in !self.state(for: profile.id).isRunning && !self.isBusy(profile.id) }
        await runBatch(verb: "启动", noneApplies: "所选 Profile 都已在运行。", applies: startable) {
            try await self.start($0)
        }
    }

    func stopBatch() async {
        let stoppable = { (profile: BrowserProfile) in self.state(for: profile.id).isRunning && !self.isBusy(profile.id) }
        await runBatch(verb: "停止", noneApplies: "所选 Profile 都未在运行。", applies: stoppable) {
            try await self.stopProfile($0.id)
            return nil
        }
    }

    /// Runs the picked Profiles one at a time and sums up the outcome in a single notice.
    private func runBatch(verb: String, noneApplies: String, applies: (BrowserProfile) -> Bool,
                          action: (BrowserProfile) async throws -> String?) async {
        let picked = batchSelection
        guard picked.contains(where: applies) else {
            notice = Notice(text: noneApplies)
            return
        }
        library.batchRunning = true
        defer { library.batchRunning = false }
        notice = nil
        let outcome = await ProfileLibrary.runBatch(picked.map(\.id), lookup: { id in self.profiles.first { $0.id == id } },
                                                    applies: applies, action: action)
        notice = Notice(text: outcome.summary(verb: verb), isError: !outcome.failures.isEmpty || !outcome.warnings.isEmpty)
    }

    /// Moves the picked Profiles into `group`; an empty group removes them from their group.
    /// Returns an error message on failure.
    func assignGroup(_ group: String, to ids: Set<UUID>) -> String? {
        guard let store else { return Self.storeUnavailable }
        let value = group.trimmingCharacters(in: .whitespacesAndNewlines)
        var moved = 0
        for var profile in profiles where ids.contains(profile.id) && profile.group != value {
            profile.group = value
            do {
                try store.save(profile)
            } catch {
                return error.localizedDescription
            }
            moved += 1
        }
        // Keep the editor in step without discarding its other unsaved edits.
        if let id = selectedID, ids.contains(id) { draft?.profile.group = value }
        notice = Notice(text: value.isEmpty ? "已将 \(moved) 个 Profile 移出分组。" : "已将 \(moved) 个 Profile 设为分组「\(value)」。")
        return nil
    }

    // MARK: Removal

    /// Why the Profile cannot be removed right now, or nil.
    func removalBlocker(_ id: UUID) -> String? {
        ProfileLibrary.removalBlocker(state: state(for: id), busy: isBusy(id), batchRunning: library.batchRunning)
    }

    /// Removes the record, then the extension directory holding the passwords AnyBrowser wrote for the
    /// Profile, and with `deletingBrowserData` its browser data too. Refuses while the Profile runs.
    func removeProfile(_ id: UUID, deletingBrowserData: Bool) async {
        if let blocker = removalBlocker(id) {
            notice = Notice(text: blocker, isError: true)
            return
        }
        guard let runtime, let store else {
            remove(id)
            return
        }
        var removed = false
        defer {
            library.removing.remove(id)
            library.selection.remove(id)
        }
        do {
            try await runtime.removeData(for: id, keepingBrowserData: !deletingBrowserData) {
                remove(id)
                // remove(_:) has already shown why the record stayed.
                guard !store.profiles.contains(where: { $0.id == id }) else { throw CancellationError() }
                removed = true
                library.removing.insert(id)
            }
            notice = Notice(text: deletingBrowserData ? "已移除 Profile 并删除浏览器资料。" : "已移除 Profile，浏览器资料保留在本机。")
        } catch {
            if removed {
                notice = Notice(text: "已移除 Profile，但\(error.localizedDescription)", isError: true)
            } else if !(error is CancellationError) {
                show(error)
            }
        }
    }
}
