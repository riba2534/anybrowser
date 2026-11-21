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
            notice = Notice(text: text + "。", isError: result.profiles.isEmpty)
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

    func createBatch(_ batch: ProfileLibrary.BatchRequest) throws -> [BrowserProfile] {
        guard let store else { throw ProfileError.invalid(Self.storeUnavailable) }
        return try store.saveBatch(batch)
    }

    /// Selects the first new Profile once the batch sheet has closed.
    func showCreated(_ created: [BrowserProfile]) {
        guard let first = created.first else { return }
        request(.profile(first.id))
        notice = Notice(text: "已新建 \(created.count) 个 Profile。")
    }

    func startBatch() async {
        let picked = batchSelection
        let targets = picked.filter { !state(for: $0.id).isRunning && !isBusy($0.id) }
        await runBatch(targets, skipped: picked.count - targets.count, verb: "启动", skippedReason: "已在运行") {
            try await self.start($0)
        }
    }

    func stopBatch() async {
        let picked = batchSelection
        let targets = picked.filter { state(for: $0.id).isRunning && !isBusy($0.id) }
        await runBatch(targets, skipped: picked.count - targets.count, verb: "停止", skippedReason: "未在运行") {
            try await self.stopProfile($0.id)
            return nil
        }
    }

    /// Runs one Profile at a time and sums up the outcome, with any warnings `action` returns, in a single notice.
    private func runBatch(_ targets: [BrowserProfile], skipped: Int, verb: String, skippedReason: String,
                          action: (BrowserProfile) async throws -> String?) async {
        guard !targets.isEmpty else {
            notice = Notice(text: "所选 Profile 都\(skippedReason)。")
            return
        }
        library.batchRunning = true
        defer { library.batchRunning = false }
        var succeeded = 0
        var failures: [String] = []
        var warnings: [String] = []
        notice = nil
        for profile in targets {
            do {
                if let warning = try await action(profile) { warnings.append("\(profile.name)：\(warning)") }
                succeeded += 1
            } catch {
                failures.append("\(profile.name)：\(error.localizedDescription)")
            }
        }
        var text = "已\(verb) \(succeeded) 个 Profile"
        if skipped > 0 { text += "，跳过 \(skipped) 个\(skippedReason)的" }
        text += "。"
        if !failures.isEmpty { text += "\(failures.count) 个未能\(verb)：\(failures.joined(separator: "；"))。" }
        if !warnings.isEmpty { text += "提醒：\(warnings.joined(separator: "；"))" }
        notice = Notice(text: text, isError: !failures.isEmpty || !warnings.isEmpty)
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

    /// Removes the record, then the browser data. Refuses while the Profile runs.
    func removeDeletingData(_ id: UUID) async {
        guard let runtime, let store, !isBusy(id), !state(for: id).isRunning else { return }
        var removed = false
        do {
            try await runtime.removeData(for: id) {
                remove(id)
                removed = !store.profiles.contains { $0.id == id }
                // remove(_:) has already shown why the record stayed.
                if !removed { throw CancellationError() }
            }
            notice = Notice(text: "已移除 Profile 并删除浏览器资料。")
        } catch {
            if removed {
                notice = Notice(text: "已移除 Profile，但\(error.localizedDescription)", isError: true)
            } else if !(error is CancellationError) {
                show(error)
            }
        }
        library.selection.remove(id)
    }
}
