import AnyBrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// The proxy library: add proxies by pasting or from a file, label them, check their exits.
/// Profiles keep their own proxy address; the library is where batch actions take them from.
struct ProxyLibrarySheet: View {
    @ObservedObject var workbench: Workbench
    @ObservedObject var library: ProxyLibrary
    @ObservedObject var checks: ProxyChecks
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var label = ""
    @State private var added: String?
    @State private var rejected: [String] = []
    @State private var error: String?
    @State private var filter = ""
    @State private var picked: Set<UUID> = []
    @State private var editing: ProxyEntry?
    @State private var confirmingDelete = false

    var body: some View {
        WorkbenchSheet(title: "代理库",
                       caption: "粘贴或从文件导入代理，每行一个。Profile 里保存的仍是代理地址；批量新建和批量设置代理时从这里按顺序或随机分配。",
                       width: 780) {
            addArea
            Rectangle().fill(WorkbenchPalette.rule).frame(height: 1)
            toolbar
            list
            HStack {
                Text(verbatim: "\(library.entries.count) 条代理")
                    .font(.system(size: 11))
                    .foregroundColor(WorkbenchPalette.muted)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .sheet(item: $editing) { entry in
            ProxyEntryEditor(library: library, entry: entry)
        }
        .alert("删除 \(picked.count) 条代理？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { deletePicked() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Profile 里保存的是代理地址，已在使用这些代理的 Profile 不受影响。")
        }
    }

    // MARK: Adding

    private var addArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                TextEditor(text: $pasted)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 86)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(WorkbenchPalette.rule, lineWidth: 1)
                    }
                    .accessibilityLabel("要添加的代理，每行一个")
                    .accessibilityIdentifier("proxy-paste")
                VStack(alignment: .leading, spacing: 8) {
                    EditorInput("名称（可选）", placeholder: "例如 住宅池", value: $label, identifier: "proxy-add-label")
                    HStack(spacing: 8) {
                        Button("添加") { add(pasted) }
                            .buttonStyle(WorkbenchButtonStyle(.primary))
                            .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !workbench.canWrite)
                            .accessibilityIdentifier("proxy-add")
                        Button("从文件导入…") { importFile() }
                            .buttonStyle(WorkbenchButtonStyle(.neutral))
                            .disabled(!workbench.canWrite)
                            .accessibilityIdentifier("proxy-import")
                    }
                }
                .frame(width: 250)
            }
            Text("可识别 主机:端口、主机:端口:用户名:密码、用户名:密码@主机:端口，以及 http://、https://、socks5:// 开头的地址；# 开头的行忽略。")
                .font(.system(size: 11))
                .foregroundColor(WorkbenchPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let added {
                Text(added)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("proxy-add-result")
            }
            if !rejected.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("以下 \(rejected.count) 行无法识别，已留在输入框里：")
                        .font(.system(size: 12, weight: .medium))
                    Text(rejected.prefix(8).joined(separator: "\n") + (rejected.count > 8 ? "\n…" : ""))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                .foregroundColor(WorkbenchPalette.danger)
                .accessibilityIdentifier("proxy-rejected")
            }
            if let error {
                ErrorLabel(error)
            }
        }
    }

    private func add(_ text: String) {
        let parsed = ProxyLibrary.parseList(text)
        error = nil
        do {
            let new = try library.add(parsed.urls, label: label)
            let known = parsed.urls.count - new.count
            var summary = "已添加 \(new.count) 条"
            if known > 0 { summary += "，\(known) 条已在代理库中" }
            added = summary + "。"
            rejected = parsed.rejected
            pasted = parsed.rejected.joined(separator: "\n")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importFile() {
        guard let url = FilePanels.file(title: "导入代理", prompt: "导入", message: "选择每行一个代理地址的文本文件。",
                                        types: [.plainText, .commaSeparatedText, .text]) else { return }
        do {
            let data = try ProfileLibrary.contents(of: url)
            add(String(decoding: data, as: UTF8.self))
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: List

    private var shown: [ProxyEntry] {
        let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return library.entries }
        return library.entries.filter { entry in
            ([entry.url, entry.label, entry.note] + entry.tags).contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    private var toolbar: some View {
        let shown = self.shown
        let targets = picked.isEmpty ? shown : shown.filter { picked.contains($0.id) }
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(WorkbenchPalette.muted)
                    .accessibilityHidden(true)
                TextField("筛选", text: $filter, prompt: Text("地址、名称、标签或备注").foregroundColor(WorkbenchPalette.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("proxy-filter")
            }
            .padding(.horizontal, 9)
            .frame(width: 240, height: 30)
            .fieldSurface()
            Toggle("全选", isOn: Binding(
                get: { !shown.isEmpty && shown.allSatisfy { picked.contains($0.id) } },
                set: { on in
                    if on { picked.formUnion(shown.map(\.id)) } else { picked.subtract(shown.map(\.id)) }
                }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .disabled(shown.isEmpty)
            Spacer()
            if let progress = checks.progress {
                ProgressView().controlSize(.small)
                Text("正在检测 \(progress.done)/\(progress.total)")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
                    .monospacedDigit()
            }
            Button(picked.isEmpty ? "检测全部" : "检测所选（\(targets.count)）") {
                Task { await checks.check(targets, in: library) }
            }
            .buttonStyle(WorkbenchButtonStyle(.neutral))
            .disabled(targets.isEmpty || checks.isChecking || !workbench.canWrite)
            .help("经每条代理查询出口 IP、所在地和时区，每次 6 条")
            .accessibilityIdentifier("proxy-check")
            Button("删除所选") { confirmingDelete = true }
                .buttonStyle(WorkbenchButtonStyle(.quiet))
                .disabled(picked.isEmpty || !workbench.canWrite)
                .accessibilityIdentifier("proxy-delete")
        }
    }

    private var list: some View {
        let usage = ProxyAssignment.usage(of: library.entries, by: workbench.profiles)
        let shown = self.shown
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if shown.isEmpty {
                    Text(library.entries.isEmpty ? "代理库还是空的。在上面粘贴代理地址，或从文件导入。" : "没有匹配的代理")
                        .font(.system(size: 12))
                        .foregroundColor(WorkbenchPalette.muted)
                        .padding(12)
                }
                ForEach(shown) { entry in
                    row(entry, usage: usage[entry.id] ?? 0)
                    Rectangle().fill(WorkbenchPalette.rule).frame(height: 1)
                }
            }
        }
        .frame(height: 300)
        .background(WorkbenchPalette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WorkbenchPalette.rule, lineWidth: 1)
        }
        .accessibilityIdentifier("proxy-list")
    }

    private func row(_ entry: ProxyEntry, usage: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { picked.contains(entry.id) },
                                     set: { if $0 { picked.insert(entry.id) } else { picked.remove(entry.id) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("选择 \(entry.label.isEmpty ? ProxyText.masked(entry.url) : entry.label)")
            VStack(alignment: .leading, spacing: 3) {
                if entry.label.isEmpty {
                    Text(verbatim: ProxyText.masked(entry.url))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                } else {
                    Text(entry.label)
                        .font(.system(size: 13, weight: .medium))
                    Text(verbatim: ProxyText.masked(entry.url))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(WorkbenchPalette.muted)
                }
                let details = [entry.tags.isEmpty ? nil : entry.tags.map { "#\($0)" }.joined(separator: " "),
                               entry.note.isEmpty ? nil : entry.note].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundColor(WorkbenchPalette.muted)
                        .lineLimit(2)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 8)
            exit(entry)
                .frame(width: 250, alignment: .trailing)
            Text(usage > 0 ? "\(usage) 个 Profile" : "未使用")
                .font(.system(size: 11))
                .foregroundColor(usage > 1 ? WorkbenchPalette.amber : WorkbenchPalette.muted)
                .frame(width: 70, alignment: .trailing)
                .help(usage > 1 ? "\(usage) 个 Profile 使用这条代理，它们共用出口" : "")
            Menu {
                Button("编辑…") { editing = entry }
                Button("检测") { Task { await checks.check([entry], in: library) } }
                    .disabled(checks.isChecking)
                Divider()
                Button("删除") {
                    picked = [entry.id]
                    confirmingDelete = true
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!workbench.canWrite)
            .accessibilityLabel("代理操作")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("proxy-row-\(entry.id.uuidString)")
    }

    @ViewBuilder
    private func exit(_ entry: ProxyEntry) -> some View {
        let result = checks.results[entry.id]
        VStack(alignment: .trailing, spacing: 3) {
            if checks.checking.contains(entry.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("检测中…")
                }
                .font(.system(size: 11))
                .foregroundColor(WorkbenchPalette.muted)
            } else if let exit = entry.lastExit {
                Text(verbatim: [Self.country(exit.countryCode), exit.timeZone].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12, weight: .medium))
                Text(verbatim: "IP \(exit.ip)" + (result?.latency.map { " · \(Int(($0 * 1000).rounded())) ms" } ?? ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(WorkbenchPalette.muted)
            } else if entry.lastCheckedAt != nil {
                Text(result?.failure ?? "上次检测失败")
                    .font(.system(size: 11))
                    .foregroundColor(WorkbenchPalette.danger)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .help(result?.failure ?? "")
            } else {
                Text("尚未检测")
                    .font(.system(size: 11))
                    .foregroundColor(WorkbenchPalette.muted)
            }
            if let checked = entry.lastCheckedAt, !checks.checking.contains(entry.id) {
                Text(Self.checkedText(checked))
                    .font(.system(size: 10))
                    .foregroundColor(WorkbenchPalette.muted)
            }
        }
        .textSelection(.enabled)
    }

    private static func country(_ code: String) -> String {
        guard !code.isEmpty else { return "" }
        let name = Locale(identifier: "zh_CN").localizedString(forRegionCode: code) ?? code
        return name == code ? code : "\(name) \(code)"
    }

    private static func checkedText(_ date: Date) -> String {
        let now = Date()
        guard now.timeIntervalSince(date) >= 60 else { return "刚刚检测" }
        return relative.localizedString(for: date, relativeTo: now) + "检测"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    private func deletePicked() {
        do {
            try library.remove(Array(picked))
            picked = []
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Edits one library entry.
private struct ProxyEntryEditor: View {
    @ObservedObject var library: ProxyLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var entry: ProxyEntry
    @State private var tags: String
    @State private var error: String?

    init(library: ProxyLibrary, entry: ProxyEntry) {
        self.library = library
        _entry = State(initialValue: entry)
        _tags = State(initialValue: entry.tags.joined(separator: ", "))
    }

    var body: some View {
        WorkbenchSheet(title: "编辑代理", caption: "修改地址后，之前的出口检测结果作废。", width: 460) {
            EditorInput("代理地址", placeholder: "主机:端口", value: $entry.url, identifier: "proxy-edit-url")
            EditorInput("名称", placeholder: "可选", value: $entry.label, identifier: "proxy-edit-label")
            EditorInput("标签", placeholder: "多个标签用逗号分隔", value: $tags, identifier: "proxy-edit-tags")
            VStack(alignment: .leading, spacing: 6) {
                Text("备注")
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
                TextEditor(text: $entry.note)
                    .font(.system(size: 13))
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(WorkbenchPalette.rule, lineWidth: 1)
                    }
                    .accessibilityLabel("备注")
                    .accessibilityIdentifier("proxy-edit-note")
            }
            if let error {
                ErrorLabel(error)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(WorkbenchButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("proxy-edit-save")
            }
        }
    }

    private func save() {
        var value = entry
        value.tags = tags.components(separatedBy: CharacterSet(charactersIn: ",，、"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        do {
            try library.update(value)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
