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
            .background(WorkbenchPalette.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WorkbenchPalette.rule, lineWidth: 1) }
            .disabled(groups.isEmpty && text.isEmpty)
            .help("选择已有分组")
            .accessibilityLabel("选择已有分组")
            .accessibilityIdentifier("\(identifier)-menu")
        }
    }
}

struct LibrarySearchField: View {
    @ObservedObject var library: LibraryModel
    @FocusState private var focused: Bool

    var body: some View {
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
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(WorkbenchPalette.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : WorkbenchPalette.rule, lineWidth: 1)
        }
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

/// Batch actions on the Profiles picked with ⌘-click.
struct LibraryBatchBar: View {
    @ObservedObject var workbench: Workbench
    @State private var assigningGroup = false

    var body: some View {
        let picked = workbench.batchSelection
        let running = picked.filter { workbench.state(for: $0.id).isRunning }.count
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
            Button {
                assigningGroup = true
            } label: {
                Text("设为分组…").frame(maxWidth: .infinity)
            }
            .buttonStyle(WorkbenchButtonStyle(.quiet))
            .accessibilityIdentifier("batch-group")
            .popover(isPresented: $assigningGroup, arrowEdge: .top) {
                GroupAssignment(workbench: workbench, ids: Set(picked.map(\.id)), isPresented: $assigningGroup)
            }
        }
        .disabled(workbench.library.batchRunning)
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
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
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

/// Creates several Profiles at once.
struct BatchCreateSheet: View {
    @ObservedObject var workbench: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var countText = "5"
    @State private var prefix = "Profile"
    @State private var group = ""
    @State private var presetID: String?
    @State private var proxy = BrowserProfile.defaultProxy
    @State private var error: String?
    @State private var created: [BrowserProfile] = []
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("批量新建 Profile")
                    .font(.system(size: 18, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("名称按前缀自动编号，每个 Profile 使用新的指纹种子和调试端口。")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                EditorInput("数量", placeholder: "1–50", value: $countText, identifier: "batch-count", numeric: true)
                EditorInput("名称前缀", placeholder: "Profile", value: $prefix, identifier: "batch-prefix")
                GroupField(text: $group, groups: workbench.profileGroups, identifier: "batch-group-field")
                EditorPicker(title: "身份模板", identifier: "batch-identity", selection: $presetID,
                             choices: [(nil, "保持默认")] + IdentityPreset.all.map { (Optional($0.id), $0.title) })
            }
            EditorInput("代理地址", placeholder: "留空使用系统网络设置", value: $proxy, identifier: "batch-proxy")
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .keyboardShortcut(.cancelAction)
                Button("新建") { create() }
                    .buttonStyle(WorkbenchButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("batch-create")
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(WorkbenchPalette.workspace)
        .foregroundColor(WorkbenchPalette.ink)
        // Selecting a new Profile may ask about unsaved edits, which needs the sheet gone first.
        .onDisappear { workbench.showCreated(created) }
    }

    private func create() {
        guard let count = Int(countText.trimmingCharacters(in: .whitespaces)), (1...50).contains(count) else {
            error = "数量须为 1–50 的整数。"
            return
        }
        let preset = IdentityPreset.all.first { $0.id == presetID }
        do {
            created = try workbench.createBatch(.init(count: count, prefix: prefix, group: group,
                                                      preset: preset, proxy: proxy))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
