import AnyBrowserCore
import AppKit
import Combine
import SwiftUI

/// Sidebar search, grouping, sorting and multi-selection, and the library's sheets.
@MainActor
final class LibraryModel: ObservableObject {
    enum Sheet: Identifiable {
        case proxyLibrary, trash, repair, databaseBackups
        case batchProxy([UUID])
        case backupExport([UUID])
        case backupRestore(URL)

        var id: String {
            switch self {
            case .proxyLibrary: return "proxy-library"
            case .trash: return "trash"
            case .repair: return "repair"
            case .databaseBackups: return "database-backups"
            case .batchProxy: return "batch-proxy"
            case .backupExport: return "backup-export"
            case .backupRestore: return "backup-restore"
            }
        }
    }

    @Published var query = ""
    @Published var sort: ProfileLibrary.Sort = .created
    /// Profiles picked with ⌘- or ⇧-click for batch actions; separate from the Profile being edited.
    @Published var selection: Set<UUID> = []
    @Published var sheet: Sheet?
    /// Bumped by ⌘F; the search field takes the focus when it changes.
    @Published var searchFocusRequest = 0
    /// Browser data directories no saved, trashed or unreadable Profile owns, as last looked up.
    @Published private(set) var orphans: [UUID] = []
    /// Where a ⇧-click range starts: the Profile clicked last.
    var anchor: UUID?
    /// The sidebar's sections, kept until the Profiles, the search or the sort change.
    let index = LibraryIndex()
    let proxyChecks = ProxyChecks()
    /// Batch actions run in the coordinator; the Workbench forwards its changes to the views.
    weak var coordinator: LaunchCoordinator? {
        didSet {
            // The sidebar shows each Profile's last exit, which the proxy library records.
            proxyLibraryChanges = coordinator?.proxyLibrary.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    private var proxyLibraryChanges: AnyCancellable?

    var batchRunning: Bool { coordinator?.batch != nil }

    func toggle(_ id: UUID) {
        if selection.remove(id) == nil { selection.insert(id) }
        anchor = id
    }

    /// Looks for orphaned data directories again; a short directory listing.
    func refreshOrphans(_ store: ProfileStore?) {
        let found = store?.orphanDataDirectories() ?? []
        if found != orphans { orphans = found }
    }
}

extension Workbench {
    /// False without the database, or when a newer AnyBrowser wrote it.
    var canWrite: Bool { store.map { !$0.isReadOnly } ?? false }

    var proxyLibrary: ProxyLibrary? { coordinator?.proxyLibrary }

    var librarySections: [ProfileLibrary.Section] {
        refreshIndex()
        return library.index.sections
    }

    var profileGroups: [String] {
        refreshIndex()
        return library.index.groups
    }

    /// Tags in use, for the search's filter menu.
    var profileTags: [String] {
        refreshIndex()
        return library.index.tags
    }

    /// The sidebar rows in display order.
    var visibleIDs: [UUID] {
        refreshIndex()
        return library.index.visibleIDs
    }

    private func refreshIndex() {
        library.index.update(.init(profiles: profiles, query: library.query, sort: library.sort,
                                   lastLaunched: store?.lastLaunched ?? [:], exits: proxyLibrary?.profileExits ?? [:]))
    }

    /// Saved Profiles picked for batch actions, in creation order.
    var batchSelection: [BrowserProfile] { profiles.filter { library.selection.contains($0.id) } }

    /// Picked Profiles the current search hides.
    var hiddenSelectionCount: Int {
        library.selection.subtracting(visibleIDs).intersection(profiles.map(\.id)).count
    }

    /// The country of the Profile's last exit, and the names of the other Profiles that left
    /// through the same IP.
    func exitSummary(for id: UUID) -> (country: String, ip: String, sharedWith: [String])? {
        guard let record = proxyLibrary?.profileExits[id] else { return nil }
        refreshIndex()
        let names = (library.index.sharedExits[id] ?? []).compactMap { other in profiles.first { $0.id == other }?.name }
        return (record.exit.countryCode, record.exit.ip, names)
    }

    // MARK: Selection

    /// A click on a sidebar row: ⌘ toggles it in the batch selection, ⇧ adds the rows from the
    /// last clicked one, otherwise it opens the Profile.
    func click(_ id: UUID) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) {
            let rows = LibrarySelection.range(from: library.anchor ?? selectedID, to: id, in: visibleIDs)
            library.selection.formUnion(rows)
            if library.anchor == nil { library.anchor = id }
        } else if modifiers.contains(.command) {
            library.toggle(id)
        } else {
            library.anchor = id
            // Ends typing in the editor, so the arrow keys move through the list from here.
            NSApp.keyWindow?.makeFirstResponder(nil)
            request(.profile(id))
        }
    }

    /// Picks every Profile the current search shows.
    func selectAllVisible() {
        library.selection.formUnion(visibleIDs)
    }

    /// Opens the Profile one row up or down.
    func selectAdjacent(_ offset: Int) {
        guard let next = LibrarySelection.step(from: selectedID, by: offset, in: visibleIDs), next != selectedID else { return }
        library.anchor = next
        request(.profile(next))
    }

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

    /// Exports `ids` (every Profile when nil) to a JSON file.
    func exportProfiles(includeSecrets: Bool, ids: Set<UUID>? = nil) {
        guard let store else { return }
        let exported = profiles.filter { ids?.contains($0.id) ?? true }
        guard !exported.isEmpty else { return }
        guard let url = FilePanels.saveLocation(
            title: includeSecrets ? "导出 Profile（含密码）" : "导出 Profile",
            message: includeSecrets
                ? "文件包含代理和 Passkey Box 的账号密码，请妥善保管。浏览器资料不会导出。"
                : "代理账号密码和 Profile 自己的 Passkey Box 账号不会导出。浏览器资料不会导出。",
            name: "AnyBrowser Profiles.json") else { return }
        do {
            try ProfileLibrary.writePrivately(store.exportProfiles(Set(exported.map(\.id)), includeSecrets: includeSecrets), to: url)
            var text = "已导出 \(exported.count) 个 Profile\(includeSecrets ? "，文件包含密码" : "")。"
            // Only a whole-library export leaves them out unnoticed.
            if ids == nil, !store.unreadableRows.isEmpty {
                text += "另有 \(store.unreadableRows.count) 份无法读取的配置未导出，可在「资料库检查」里单独导出。"
            }
            notice = Notice(text: text)
        } catch {
            show(error)
        }
    }

    // MARK: Batch creation

    /// Selects the first new Profile once the batch sheet has closed.
    func showCreated(_ created: [BrowserProfile], unaligned: Int) {
        guard let first = created.first else { return }
        request(.profile(first.id))
        var text = "已新建 \(created.count) 个 Profile"
        if unaligned > 0 {
            text += "。其中 \(unaligned) 个的代理出口检测失败，语言和时区为随机值，可在编辑器的「代理」卡片里点「检测」后对齐。"
        } else {
            text += "，语言和时区已与各自的代理出口对齐。"
        }
        notice = Notice(text: text, isError: unaligned > 0)
    }

    /// Records exits found while creating or reassigning Profiles, for the sidebar and the
    /// exit-sharing hints, and for the library entries they came from.
    func recordExits(_ lookups: [String: ProxyAssignment.Lookup], for profiles: [BrowserProfile]) {
        guard let proxyLibrary else { return }
        for profile in profiles {
            if case .found(let exit)? = lookups[ProxyAssignment.normalized(profile.proxy)] {
                try? proxyLibrary.recordExit(exit, forProfile: profile.id)
            }
        }
        for entry in proxyLibrary.entries {
            guard let lookup = lookups[entry.url] else { continue }
            try? proxyLibrary.recordCheck(entry.id, exit: lookup.exit)
        }
    }

    // MARK: Batch start and stop

    func startBatch() async {
        await runBatch(verb: "启动", noneApplies: "所选 Profile 都已在运行。",
                       applies: { !self.state(for: $0.id).isRunning && !self.isBusy($0.id) }) {
            try await $0.startBatch($1)
        }
    }

    func stopBatch() async {
        await runBatch(verb: "停止", noneApplies: "所选 Profile 都未在运行。",
                       applies: { self.state(for: $0.id).isRunning && !self.isBusy($0.id) }) {
            try await $0.stopBatch($1)
        }
    }

    /// Lets the Profiles already starting or stopping finish and skips the rest.
    func cancelBatch() {
        coordinator?.cancelBatch()
    }

    /// Runs the picked Profiles and sums up the outcome in a single notice.
    private func runBatch(verb: String, noneApplies: String, applies: (BrowserProfile) -> Bool,
                          action: (LaunchCoordinator, [UUID]) async throws -> BatchReport) async {
        guard let coordinator else { return }
        let picked = batchSelection
        guard picked.contains(where: applies) else {
            notice = Notice(text: noneApplies)
            return
        }
        notice = nil
        do {
            let report = try await action(coordinator, picked.map(\.id))
            notice = Notice(text: report.summary(verb: verb),
                            isError: !report.outcome.failures.isEmpty || !report.outcome.warnings.isEmpty)
        } catch {
            show(error)
        }
    }

    // MARK: Batch edits

    /// Applies `change` to the saved Profiles in `ids` in one transaction (all or none), and to the
    /// editor's draft when it is one of them, so that its other unsaved edits stay.
    @discardableResult
    func updateProfiles(_ ids: [UUID], _ change: (inout BrowserProfile) throws -> Void) throws -> [BrowserProfile] {
        guard let store else { throw ProfileError.invalid(Self.storeUnavailable) }
        let isSaved = saved != nil
        let updated = try store.update(ids, change)
        if isSaved, let id = selectedID, ids.contains(id), var current = draft {
            try? change(&current.profile)
            draft = current
        }
        return updated
    }

    /// Moves the picked Profiles into `group`; an empty group removes them from their group.
    /// Returns an error message on failure.
    func assignGroup(_ group: String, to ids: Set<UUID>) -> String? {
        let value = group.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let moved = try updateProfiles(profiles.map(\.id).filter(ids.contains)) { $0.group = value }
            notice = Notice(text: value.isEmpty ? "已将 \(moved.count) 个 Profile 移出分组。"
                                                : "已将 \(moved.count) 个 Profile 设为分组「\(value)」。")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    enum TagChange: String, CaseIterable {
        case add, remove, replace

        var title: String {
            switch self {
            case .add: return "添加"
            case .remove: return "移除"
            case .replace: return "替换为"
            }
        }
    }

    /// Adds, removes or replaces tags on the picked Profiles. `text` holds tags separated by
    /// commas. Returns an error message on failure.
    func changeTags(_ text: String, _ change: TagChange, on ids: Set<UUID>) -> String? {
        let tags = text.components(separatedBy: CharacterSet(charactersIn: ",，、"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if tags.isEmpty, change != .replace { return "请填写标签，多个标签用逗号分隔。" }
        do {
            let changed = try updateProfiles(profiles.map(\.id).filter(ids.contains)) { profile in
                switch change {
                case .add:
                    profile.tags = try BrowserProfile.validatedTags(profile.tags + tags)
                case .remove:
                    profile.tags.removeAll { tag in tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
                case .replace:
                    profile.tags = try BrowserProfile.validatedTags(tags)
                }
            }
            notice = Notice(text: "已更新 \(changed.count) 个 Profile 的标签。")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setAccountStatus(_ status: AccountStatus?, on ids: Set<UUID>) {
        do {
            let changed = try updateProfiles(profiles.map(\.id).filter(ids.contains)) { $0.accountStatus = status }
            notice = Notice(text: status.map { "已将 \(changed.count) 个 Profile 的账号状态设为「\($0.title)」。" }
                ?? "已清除 \(changed.count) 个 Profile 的账号状态。")
        } catch {
            show(error)
        }
    }

    /// Gives each Profile in `ids` the proxy at the same place in `proxies` and, when `locales`
    /// has one for it, that language and time zone, all in one transaction.
    @discardableResult
    func assignProxies(_ ids: [UUID], proxies: [String], locales: [IdentitySampler.LocaleHint?],
                       aligning: Bool) throws -> [BrowserProfile] {
        var plan: [UUID: (proxy: String, locale: IdentitySampler.LocaleHint?)] = [:]
        for (offset, id) in ids.enumerated() { plan[id] = (proxies[offset], locales[offset]) }
        let running = ids.filter { state(for: $0).isRunning }.count
        let updated = try updateProfiles(ids) { profile in
            guard let assigned = plan[profile.id] else { return }
            profile.proxy = assigned.proxy
            if let locale = assigned.locale { profile.fingerprint.apply(locale) }
        }
        for id in ids { proxyCenter.proxyChanged(id, to: plan[id]?.proxy ?? "") }
        let unaligned = locales.filter { $0 == nil }.count
        var text = "已为 \(ids.count) 个 Profile 设置代理"
        if !aligning {
            text += "，语言和时区没有改动。"
        } else if unaligned == 0 {
            text += "，语言和时区已与各自的出口对齐。"
        } else {
            text += "。其中 \(unaligned) 个的出口检测失败，语言和时区没有改动。"
        }
        if running > 0 { text += "正在运行的 \(running) 个重启后生效。" }
        notice = Notice(text: text, isError: aligning && unaligned > 0)
        return updated
    }

    /// Tiles the windows of `ids`, or of every running Profile when nil, on the screen with the
    /// AnyBrowser window.
    func tileWindows(_ ids: [UUID]? = nil) async {
        guard let runtime else { return }
        let targets = (ids ?? profiles.map(\.id)).filter { state(for: $0).isRunning }
        guard !targets.isEmpty else {
            notice = Notice(text: ids == nil ? "没有正在运行的 Profile。" : "所选 Profile 都未在运行。")
            return
        }
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let outcomes = await runtime.arrangeWindows(targets, in: WindowArrangement.visibleArea(of: screen))
        let placed = outcomes.filter { $0.failure == nil }.count
        let failures = outcomes.compactMap { outcome in
            outcome.failure.map { "\(profiles.first { $0.id == outcome.id }?.name ?? "Profile")：\($0)" }
        }
        var text = "已平铺 \(placed) 个窗口。"
        if !failures.isEmpty { text += "\(failures.count) 个未能平铺：\(failures.joined(separator: "；"))" }
        notice = Notice(text: text, isError: !failures.isEmpty)
    }

    // MARK: Removal and the recycle bin

    /// Why the Profile cannot be removed right now, or nil.
    func removalBlocker(_ id: UUID) -> String? {
        coordinator?.removalBlocker(id)
    }

    /// Moves stopped Profiles to the recycle bin; running or busy ones stay and are reported.
    func trashProfiles(_ ids: [UUID]) {
        guard let store else { return }
        var moved: [String] = []
        var refused: [String] = []
        for id in ids {
            guard let profile = profiles.first(where: { $0.id == id }) else { continue }
            do {
                if let coordinator {
                    try coordinator.trash(id)
                } else {
                    try store.trash(id)
                }
                moved.append(profile.name)
                library.selection.remove(id)
            } catch {
                refused.append("\(profile.name)：\(error.localizedDescription)")
            }
        }
        if let id = selectedID, saved == nil, store.trashed.contains(where: { $0.id == id }) {
            draft = profiles.first.map(ProfileDraft.init)
        }
        var text: String
        switch moved.count {
        case 0: text = ""
        case 1: text = "已将「\(moved[0])」移到回收站，\(Self.trashRetention) 天内可在回收站恢复。"
        default: text = "已将 \(moved.count) 个 Profile 移到回收站，\(Self.trashRetention) 天内可在回收站恢复。"
        }
        if !refused.isEmpty { text += "\(refused.count) 个未移动：\(refused.joined(separator: "；"))" }
        notice = Notice(text: text, isError: !refused.isEmpty)
    }

    /// How long trashed Profiles stay; launch maintenance purges them after that.
    static let trashRetention = 30

    func restoreFromTrash(_ id: UUID) {
        guard let store, let entry = store.trashed.first(where: { $0.id == id }) else { return }
        do {
            if let coordinator {
                try coordinator.restore(id)
            } else {
                try store.restore(id)
            }
            notice = Notice(text: "已恢复「\(entry.profile.name)」，浏览器资料和端口保持不变。")
            if draft == nil { draft = ProfileDraft(entry.profile) }
        } catch {
            show(error)
        }
    }

    /// Deletes trashed Profiles with their browser data, cache and extension directories.
    func purge(_ ids: [UUID]) async {
        guard let coordinator, let store else { return }
        var purged = 0
        var failures: [String] = []
        for id in ids {
            let name = store.trashed.first { $0.id == id }?.profile.name ?? "Profile"
            do {
                try await coordinator.purge(id)
                purged += 1
            } catch {
                failures.append("\(name)：\(error.localizedDescription)")
            }
        }
        library.refreshOrphans(store)
        var text = purged == 1 && ids.count == 1 ? "已永久删除，浏览器资料一并删除。" : "已永久删除 \(purged) 个 Profile 及其浏览器资料。"
        if !failures.isEmpty { text = (purged > 0 ? text : "") + "\(failures.count) 个未能删除：\(failures.joined(separator: "；"))" }
        notice = Notice(text: text, isError: !failures.isEmpty)
    }

    /// Removes the record for good with the extension directory holding the passwords AnyBrowser
    /// wrote for the Profile, and with `deletingBrowserData` its browser data too. Refuses while
    /// the Profile runs.
    func removeProfile(_ id: UUID, deletingBrowserData: Bool) async {
        if let blocker = removalBlocker(id) {
            notice = Notice(text: blocker, isError: true)
            return
        }
        guard let coordinator else {
            remove(id)
            return
        }
        defer { library.selection.remove(id) }
        do {
            let problem = try await coordinator.remove(id, deletingBrowserData: deletingBrowserData) {
                if selectedID == id { draft = profiles.first.map(ProfileDraft.init) }
            }
            library.refreshOrphans(store)
            if let problem {
                notice = Notice(text: "已移除 Profile，但\(problem)", isError: true)
            } else {
                notice = Notice(text: deletingBrowserData ? "已永久删除 Profile 及其浏览器资料。" : "已移除 Profile，浏览器资料保留在本机。")
            }
        } catch {
            show(error)
        }
    }

    // MARK: Unreadable rows and orphaned data

    /// Saves an unreadable row's stored JSON as it is, readable only by the current user.
    func exportUnreadable(_ row: UnreadableProfile) {
        guard let url = FilePanels.saveLocation(title: "导出无法读取的配置", prompt: "导出",
                                                message: "原样保存数据库里的 JSON，可能包含代理和 Passkey Box 的账号密码。",
                                                name: "AnyBrowser 无法读取的配置 \(row.id.prefix(8)).json") else { return }
        do {
            try ProfileLibrary.writePrivately(row.payload, to: url)
            notice = Notice(text: "已导出这份配置的原始 JSON。")
        } catch {
            show(error)
        }
    }

    func deleteUnreadable(_ row: UnreadableProfile) {
        guard let store else { return }
        do {
            try store.deleteUnreadable(row.id)
            library.refreshOrphans(store)
            notice = Notice(text: "已删除这份无法读取的配置。它的浏览器资料目录（如有）保留，出现在「未关联的资料目录」里。")
        } catch {
            show(error)
        }
    }

    /// A new Profile that keeps the orphaned directory's UUID, and so its browser data.
    func adoptOrphan(_ id: UUID) {
        guard let store else { return }
        do {
            let profile = try store.adoptOrphan(id)
            library.refreshOrphans(store)
            request(.profile(profile.id))
            notice = Notice(text: "已沿用这个资料目录新建「\(profile.name)」。它使用新的端口和身份，请检查指纹和代理后再启动。")
        } catch {
            show(error)
        }
    }

    func deleteOrphan(_ id: UUID) async {
        guard let runtime, let store else { return }
        // Adopted or claimed meanwhile: then it is no longer an orphan to delete.
        guard store.orphanDataDirectories().contains(id) else {
            library.refreshOrphans(store)
            return
        }
        do {
            try await runtime.removeData(for: id)
            notice = Notice(text: "已删除这个未关联的资料目录。")
        } catch {
            show(error)
        }
        library.refreshOrphans(store)
    }
}

/// Exit checks of proxy library entries, with how long each took.
@MainActor
final class ProxyChecks: ObservableObject {
    struct Result {
        var latency: TimeInterval?
        var failure: String?
    }

    @Published private(set) var results: [UUID: Result] = [:]
    @Published private(set) var checking: Set<UUID> = []
    @Published private(set) var progress: (done: Int, total: Int)?

    var isChecking: Bool { progress != nil }

    /// Looks up the exit of each entry, a few at a time, and records it in the library.
    func check(_ entries: [ProxyEntry], in library: ProxyLibrary) async {
        guard progress == nil, !entries.isEmpty else { return }
        let ids = Dictionary(entries.map { ($0.url, $0.id) }, uniquingKeysWith: { first, _ in first })
        checking = Set(entries.map(\.id))
        defer {
            checking = []
            progress = nil
        }
        _ = await ProxyAssignment.lookUpExits(entries.map(\.url), limit: 6, lookup: { endpoint in
            try await ProxyProbe.lookupExit(through: endpoint)
        }, progress: { done, total in
            self.progress = (done, total)
        }, completed: { url, lookup, duration in
            guard let id = ids[url] else { return }
            self.checking.remove(id)
            self.results[id] = Result(latency: lookup.exit == nil ? nil : duration, failure: {
                if case .failed(let reason) = lookup { return reason }
                return nil
            }())
            try? library.recordCheck(id, exit: lookup.exit)
        })
    }
}
