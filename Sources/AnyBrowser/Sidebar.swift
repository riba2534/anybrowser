import AnyBrowserCore
import AppKit
import SwiftUI

/// The left column: search, the Profiles by group, batch actions and the library's entry points.
/// The library's sheets hang off it, since it is always on screen.
struct LibrarySidebar: View {
    @ObservedObject var workbench: Workbench
    @State private var restoreOutcome = DatabaseRestore.outcome
    private static let brandImage = Bundle.main.url(forResource: "AnyBrowser", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:))

    private var library: LibraryModel { workbench.library }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 20)
                .padding(.top, 48)
                .padding(.bottom, 20)
            LibrarySearchField(workbench: workbench, library: library)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            repairNotice
            HStack(spacing: 8) {
                Text("Profiles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(WorkbenchPalette.muted)
                Spacer()
                Text(workbench.profiles.count.formatted())
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(WorkbenchPalette.muted)
                    .accessibilityLabel("Profile 数量 \(workbench.profiles.count)")
                LibrarySortMenu(library: library)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            list
            bottomBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Rectangle().fill(WorkbenchPalette.rule).frame(height: 1)
            VStack(spacing: 12) {
                libraryLinks
                passkeyBoxFootnote
                engineFootnote
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxHeight: .infinity)
        .background(WorkbenchPalette.sidebar)
        .background(SidebarKeys { key in handle(key) })
        .onAppear { library.refreshOrphans(workbench.store) }
        .sheet(item: Binding(get: { library.sheet }, set: { library.sheet = $0 })) { sheet in
            switch sheet {
            case .proxyLibrary:
                if let proxies = workbench.proxyLibrary {
                    ProxyLibrarySheet(workbench: workbench, library: proxies, checks: library.proxyChecks)
                }
            case .trash:
                TrashSheet(workbench: workbench)
            case .repair:
                RepairSheet(workbench: workbench)
            case .databaseBackups:
                DatabaseBackupsSheet(workbench: workbench)
            case .batchProxy(let ids):
                BatchProxySheet(workbench: workbench, ids: ids)
            case .backupExport(let ids):
                FullBackupSheet(workbench: workbench, mode: .export(ids))
            case .backupRestore(let file):
                FullBackupSheet(workbench: workbench, mode: .restore(file))
            }
        }
        .alert("数据库备份", isPresented: Binding(showing: $restoreOutcome)) {
            Button("好") { restoreOutcome = nil }
        } message: {
            Text(restoreOutcome ?? "")
        }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Group {
                if let image = Self.brandImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(WorkbenchPalette.muted)
                }
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("AnyBrowser")
                    .font(.system(size: 16, weight: .semibold))
                Text("浏览器工作台")
                    .font(.system(size: 11))
                    .foregroundColor(WorkbenchPalette.muted)
            }
        }
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    let sections = workbench.librarySections
                    // Headers only help once at least one Profile has a group.
                    let showsHeaders = sections.contains { !$0.group.isEmpty }
                    ForEach(sections, id: \.group) { section in
                        if showsHeaders {
                            sectionHeader(section)
                        }
                        ForEach(section.profiles) { profile in
                            profileRow(profile)
                                .id(profile.id)
                        }
                    }
                    if sections.isEmpty && !workbench.profiles.isEmpty {
                        Text("没有匹配的 Profile")
                            .font(.system(size: 12))
                            .foregroundColor(WorkbenchPalette.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    if let draft = workbench.draft, workbench.saved == nil {
                        profileRow(draft.profile, isDraft: true)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: workbench.selectedID) { id in
                if let id { scroller.scrollTo(id) }
            }
        }
    }

    private func sectionHeader(_ section: ProfileLibrary.Section) -> some View {
        HStack(spacing: 6) {
            Text(section.group.isEmpty ? "未分组" : section.group)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(section.profiles.count.formatted())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundColor(WorkbenchPalette.muted)
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func profileRow(_ profile: BrowserProfile, isDraft: Bool = false) -> some View {
        let isSelected = profile.id == workbench.selectedID
        let isPicked = !isDraft && library.selection.contains(profile.id)
        let state = workbench.state(for: profile.id)
        let exit = isDraft ? nil : workbench.exitSummary(for: profile.id)
        return Button {
            if isDraft {
                workbench.request(.profile(profile.id))
            } else {
                workbench.click(profile.id)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isPicked ? "checkmark" : platformIcon(profile.fingerprint.platform))
                    .font(.system(size: 13, weight: isPicked ? .bold : .medium))
                    .foregroundColor(isPicked ? .white : WorkbenchPalette.ink)
                    .frame(width: 30, height: 30)
                    .background(isPicked ? Color.accentColor : WorkbenchPalette.iconSurface,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name.isEmpty ? "未命名 Profile" : profile.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(verbatim: isDraft ? "草稿" : "127.0.0.1:\(profile.port)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(WorkbenchPalette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 4) {
                        if let exit, !exit.sharedWith.isEmpty {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(WorkbenchPalette.amber)
                                .help("与「\(exit.sharedWith.joined(separator: "」「"))」共用出口 IP \(exit.ip)")
                                .accessibilityLabel("与 \(exit.sharedWith.count) 个 Profile 共用出口")
                        }
                        Circle()
                            .fill(state.indicator)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    // The country of the last exit; the IP would not fit.
                    if let exit, !exit.country.isEmpty {
                        Text(verbatim: exit.country)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(WorkbenchPalette.muted)
                            .help("最近一次出口 IP \(exit.ip)")
                            .accessibilityLabel("出口国家 \(exit.country)")
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(WorkbenchPalette.selected)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(WorkbenchPalette.strongRule, lineWidth: 1)
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isDraft {
                rowMenu(profile, isPicked: isPicked, state: state)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isPicked ? "已加入批量选择" : "")
        .accessibilityIdentifier("profile-row-\(profile.id.uuidString)")
        .help(isDraft ? profile.name : "\(profile.name)（按住 Command 点击多选，按住 Shift 点击连选）")
    }

    @ViewBuilder
    private func rowMenu(_ profile: BrowserProfile, isPicked: Bool, state: BrowserRunState) -> some View {
        Button(isPicked ? "取消选择" : "加入批量选择") { library.toggle(profile.id) }
        Button("选择列表中的全部 Profile") { workbench.selectAllVisible() }
        if state.isRunning {
            Divider()
            Button("显示窗口") { workbench.showWindows(profile.id) }
            Button("停止") { Task { await workbench.stop(profile.id) } }
                .disabled(workbench.isBusy(profile.id))
        }
        Divider()
        Button("移到回收站") { workbench.trashProfiles([profile.id]) }
            .disabled(!workbench.canWrite || workbench.removalBlocker(profile.id) != nil)
    }

    private func platformIcon(_ platform: BrowserPlatform?) -> String {
        switch platform {
        case .macOS: return "laptopcomputer"
        case .windows: return "macwindow"
        case .linux: return "terminal"
        case nil: return "globe"
        }
    }

    // MARK: Keyboard

    private func handle(_ key: SidebarKeys.Key) -> Bool {
        switch key {
        case .up: workbench.selectAdjacent(-1)
        case .down: workbench.selectAdjacent(1)
        case .selectAll:
            guard !workbench.visibleIDs.isEmpty else { return false }
            workbench.selectAllVisible()
        }
        return true
    }

    // MARK: Bottom

    @ViewBuilder private var bottomBar: some View {
        if let batch = workbench.coordinator?.batch {
            BatchProgressBar(workbench: workbench, batch: batch)
        } else if workbench.batchSelection.isEmpty {
            Button {
                workbench.request(.new)
            } label: {
                Label("新建 Profile", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(WorkbenchButtonStyle(.quiet))
            .disabled(!workbench.canWrite)
            .accessibilityIdentifier("new-profile")
        } else {
            LibraryBatchBar(workbench: workbench)
        }
    }

    /// Rows the store could not read, and data directories no row owns, need the user's decision.
    @ViewBuilder private var repairNotice: some View {
        let unreadable = workbench.store?.unreadableRows.count ?? 0
        let orphans = library.orphans.count
        if unreadable + orphans > 0 {
            Button {
                library.sheet = .repair
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text([unreadable > 0 ? "\(unreadable) 份配置无法读取" : nil,
                          orphans > 0 ? "\(orphans) 个资料目录未关联" : nil].compactMap { $0 }.joined(separator: "，"))
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundColor(WorkbenchPalette.amber)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .help("查看并处理无法读取的配置和未关联的资料目录")
            .accessibilityIdentifier("library-repair")
        }
    }

    private var libraryLinks: some View {
        HStack(spacing: 16) {
            footnoteLink("代理库", icon: "network", value: workbench.proxyLibrary.map { "\($0.entries.count)" } ?? "不可用",
                         identifier: "open-proxy-library") {
                library.sheet = .proxyLibrary
            }
            .disabled(workbench.proxyLibrary == nil)
            .help("导入、检测和分配代理")
            footnoteLink("回收站", icon: "trash", value: "\(workbench.store?.trashed.count ?? 0)", identifier: "open-trash") {
                library.sheet = .trash
            }
            .disabled(workbench.store == nil)
            .help("恢复或永久删除移到回收站的 Profile")
        }
    }

    private func footnoteLink(_ title: String, icon: String, value: String, identifier: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(WorkbenchPalette.muted)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(value)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(WorkbenchPalette.muted)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private var passkeyBoxFootnote: some View {
        Button {
            workbench.showingPasskeyBox = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(workbench.passkeyBoxAccount == nil ? WorkbenchPalette.amber : WorkbenchPalette.green)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text("Passkey Box")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(workbench.passkeyBoxAccount?.username ?? "未设置账号")
                    .font(.system(size: 10))
                    .foregroundColor(WorkbenchPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(workbench.store == nil)
        .help("设置各 Profile 内置 Passkey Box 使用的账号")
        .accessibilityIdentifier("passkey-box-account")
    }

    private var engineFootnote: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(workbench.engineVersion == nil ? WorkbenchPalette.amber : WorkbenchPalette.green)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text("内置引擎")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(workbench.engineVersion ?? "不可用")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(WorkbenchPalette.muted)
                .lineLimit(1)
        }
    }
}

/// How far a batch start or stop has come, with its Cancel button.
private struct BatchProgressBar: View {
    @ObservedObject var workbench: Workbench
    let batch: BatchProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: "\(batch.action == .start ? "正在启动" : "正在停止") \(batch.completed)/\(batch.total)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                Spacer()
                Button(batch.canCancel ? "取消" : "正在取消…") { workbench.cancelBatch() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(WorkbenchPalette.muted)
                    .disabled(!batch.canCancel)
                    .accessibilityIdentifier("batch-cancel")
            }
            ProgressView(value: Double(batch.completed), total: Double(max(batch.total, 1)))
                .progressViewStyle(.linear)
            Text(batch.canCancel ? "正在进行的会完成，其余的取消后跳过。" : "等正在进行的完成后结束。")
                .font(.system(size: 10))
                .foregroundColor(WorkbenchPalette.muted)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("batch-progress")
    }
}

/// Arrow keys and ⌘A for the sidebar, while no text is being edited and no sheet is open. The
/// sidebar is not a List: one would merge the Profile being edited with the batch selection.
struct SidebarKeys: NSViewRepresentable {
    enum Key {
        case up, down, selectAll
    }

    /// Returns whether the key was used; unused keys go on as usual.
    let handle: (Key) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.handle = handle
    }

    final class KeyView: NSView {
        var handle: ((Key) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let key = self.key(for: event), self.handle?(key) == true else { return event }
                return nil
            }
        }

        private func key(for event: NSEvent) -> Key? {
            // Text fields keep their arrows and ⌘A; sheets, alerts and popovers are other windows.
            guard let window, event.window === window, window.attachedSheet == nil,
                  !(window.firstResponder is NSText) else { return nil }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.function, .numericPad, .capsLock])
            if modifiers.isEmpty, event.specialKey == .upArrow { return .up }
            if modifiers.isEmpty, event.specialKey == .downArrow { return .down }
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "a" { return .selectAll }
            return nil
        }
    }
}
