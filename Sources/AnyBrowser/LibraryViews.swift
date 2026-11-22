import AnyBrowserCore
import SwiftUI

/// A group name typed freely or picked from the groups already in use.
struct GroupField: View {
    @Binding var text: String
    let groups: [String]
    var identifier = "profile-group"

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            EditorInput("分组", placeholder: "未分组", value: $text, identifier: identifier)
            Menu {
                ForEach(groups, id: \.self) { group in
                    Button(group) { text = group }
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !groups.isEmpty { Divider() }
                    Button("移出分组") { text = "" }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 34, height: 34)
            .fieldSurface()
            .disabled(groups.isEmpty && text.isEmpty)
            .help("选择已有分组")
            .accessibilityLabel("选择已有分组")
            .accessibilityIdentifier("\(identifier)-menu")
        }
    }
}

/// The sidebar search. Besides free text it takes `tag:`, `status:` and `group:` terms, which the
/// filter menu inserts.
struct LibrarySearchField: View {
    @ObservedObject var workbench: Workbench
    @ObservedObject var library: LibraryModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(WorkbenchPalette.muted)
                    .accessibilityHidden(true)
                TextField("搜索 Profile", text: $library.query,
                          prompt: Text("名称、分组、备注或端口").foregroundColor(WorkbenchPalette.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .accessibilityIdentifier("profile-search")
                if !library.query.isEmpty {
                    Button {
                        library.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(WorkbenchPalette.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
                filterMenu
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .fieldSurface(focused: focused)
            if focused && library.query.isEmpty {
                Text("可用 tag:标签、status:状态、group:分组 筛选，可组合")
                    .font(.system(size: 10))
                    .foregroundColor(WorkbenchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .onChange(of: library.searchFocusRequest) { _ in focused = true }
    }

    private var filterMenu: some View {
        Menu {
            let tags = workbench.profileTags
            Menu("按标签") {
                ForEach(tags, id: \.self) { tag in
                    Button(tag) { insert("tag", tag) }
                }
            }
            .disabled(tags.isEmpty)
            Menu("按账号状态") {
                ForEach(AccountStatus.allCases, id: \.self) { status in
                    Button(status.title) { insert("status", status.title) }
                }
            }
            let groups = workbench.profileGroups
            Menu("按分组") {
                ForEach(groups, id: \.self) { group in
                    Button(group) { insert("group", group) }
                }
            }
            .disabled(groups.isEmpty)
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("按标签、账号状态或分组筛选：在搜索框输入 tag:、status: 或 group:，值含空格时加引号")
        .accessibilityLabel("筛选条件")
        .accessibilityIdentifier("profile-search-filters")
    }

    private func insert(_ key: String, _ value: String) {
        let term = value.contains(where: \.isWhitespace) ? "\(key):\"\(value)\"" : "\(key):\(value)"
        let current = library.query.trimmingCharacters(in: .whitespaces)
        library.query = current.isEmpty ? term : "\(current) \(term)"
    }
}

struct LibrarySortMenu: View {
    @ObservedObject var library: LibraryModel

    var body: some View {
        Menu {
            Picker("排序", selection: $library.sort) {
                ForEach(ProfileLibrary.Sort.allCases, id: \.self) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("排序：\(library.sort.title)")
        .accessibilityLabel("排序方式")
        .accessibilityValue(library.sort.title)
        .accessibilityIdentifier("profile-sort")
    }
}

/// Batch actions on the Profiles picked with ⌘- or ⇧-click.
struct LibraryBatchBar: View {
    @ObservedObject var workbench: Workbench
    @State private var popover: Popover?

    private enum Popover: String, Identifiable {
        case group, tags
        var id: String { rawValue }
    }

    var body: some View {
        let picked = workbench.batchSelection
        let ids = Set(picked.map(\.id))
        let running = picked.filter { workbench.state(for: $0.id).isRunning }.count
        let hidden = workbench.hiddenSelectionCount
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已选择 \(picked.count) 个")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("取消选择") { workbench.library.selection = [] }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(WorkbenchPalette.muted)
                    .accessibilityIdentifier("batch-clear")
            }
            if hidden > 0 {
                Text("其中 \(hidden) 个不在当前列表")
                    .font(.system(size: 11))
                    .foregroundColor(WorkbenchPalette.muted)
                    .accessibilityIdentifier("batch-hidden")
            }
            HStack(spacing: 8) {
                Button {
                    Task { await workbench.startBatch() }
                } label: {
                    Text("启动所选").frame(maxWidth: .infinity)
                }
                .disabled(running == picked.count || workbench.runtime == nil)
                .accessibilityIdentifier("batch-start")
                Button {
                    Task { await workbench.stopBatch() }
                } label: {
                    Text("停止所选").frame(maxWidth: .infinity)
                }
                .disabled(running == 0)
                .accessibilityIdentifier("batch-stop")
            }
            .buttonStyle(WorkbenchButtonStyle(.neutral))
            HStack(spacing: 8) {
                Button {
                    Task { await workbench.tileWindows(picked.map(\.id)) }
                } label: {
                    Text("平铺窗口").frame(maxWidth: .infinity)
                }
                .buttonStyle(WorkbenchButtonStyle(.quiet))
                .disabled(running == 0)
                .help("把所选 Profile 的浏览器窗口按网格排满当前屏幕")
                .accessibilityIdentifier("batch-tile")
                more(picked, ids: ids)
            }
        }
        .popover(item: $popover, arrowEdge: .top) { which in
            switch which {
            case .group:
                GroupAssignment(workbench: workbench, ids: ids, isPresented: presented)
            case .tags:
                TagAssignment(workbench: workbench, ids: ids, isPresented: presented)
            }
        }
    }

    private var presented: Binding<Bool> {
        Binding(showing: $popover)
    }

    private func more(_ picked: [BrowserProfile], ids: Set<UUID>) -> some View {
        Menu {
            Group {
                Button("设置代理…") { workbench.library.sheet = .batchProxy(picked.map(\.id)) }
                    .disabled(workbench.proxyLibrary == nil)
                Button("设为分组…") { show(.group) }
                Button("设置标签…") { show(.tags) }
                Menu("账号状态") {
                    ForEach(AccountStatus.allCases, id: \.self) { status in
                        Button(status.title) { workbench.setAccountStatus(status, on: ids) }
                    }
                    Divider()
                    Button("清除状态") { workbench.setAccountStatus(nil, on: ids) }
                }
            }
            .disabled(!workbench.canWrite)
            Divider()
            Button("导出所选…") { workbench.exportProfiles(includeSecrets: false, ids: ids) }
            Button("导出所选（含密码）…") { workbench.exportProfiles(includeSecrets: true, ids: ids) }
            Button("完整备份所选…") { workbench.library.sheet = .backupExport(picked.map(\.id)) }
                .disabled(workbench.coordinator == nil)
            Divider()
            Button("选择列表中的全部 Profile") { workbench.selectAllVisible() }
            Divider()
            Button("移到回收站") { workbench.trashProfiles(picked.map(\.id)) }
                .disabled(!workbench.canWrite)
        } label: {
            Text("更多")
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(WorkbenchPalette.iconSurface.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityLabel("更多批量操作")
        .accessibilityIdentifier("batch-more")
    }

    /// A popover asked for from the menu shows once the menu has closed.
    private func show(_ which: Popover) {
        DispatchQueue.main.async { popover = which }
    }
}

private struct GroupAssignment: View {
    @ObservedObject var workbench: Workbench
    let ids: Set<UUID>
    @Binding var isPresented: Bool
    @State private var group = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("为 \(ids.count) 个 Profile 设置分组")
                .font(.system(size: 13, weight: .semibold))
            GroupField(text: $group, groups: workbench.profileGroups, identifier: "batch-group-name")
            Text("留空则移出分组。")
                .font(.system(size: 11))
                .foregroundColor(WorkbenchPalette.muted)
            if let error {
                ErrorLabel(error)
            }
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .keyboardShortcut(.cancelAction)
                Button("应用") {
                    error = workbench.assignGroup(group, to: ids)
                    if error == nil { isPresented = false }
                }
                .buttonStyle(WorkbenchButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("batch-group-apply")
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct TagAssignment: View {
    @ObservedObject var workbench: Workbench
    let ids: Set<UUID>
    @Binding var isPresented: Bool
    @State private var change: Workbench.TagChange = .add
    @State private var tags = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("为 \(ids.count) 个 Profile 设置标签")
                .font(.system(size: 13, weight: .semibold))
            Picker("方式", selection: $change) {
                ForEach(Workbench.TagChange.allCases, id: \.self) { change in
                    Text(change.title).tag(change)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("batch-tags-mode")
            EditorInput("标签", placeholder: "多个标签用逗号分隔", value: $tags, identifier: "batch-tags")
            Text(change == .replace ? "留空则清除所选 Profile 的全部标签。" : "标签不区分大小写，每个 Profile 最多 \(BrowserProfile.maximumTags) 个。")
                .font(.system(size: 11))
                .foregroundColor(WorkbenchPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                ErrorLabel(error)
            }
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .keyboardShortcut(.cancelAction)
                Button("应用") {
                    error = workbench.changeTags(tags, change, on: ids)
                    if error == nil { isPresented = false }
                }
                .buttonStyle(WorkbenchButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("batch-tags-apply")
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
