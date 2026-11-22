import AnyBrowserCore
import AppKit
import SwiftUI

/// Profiles moved to the recycle bin: restore them, or delete them for good.
struct TrashSheet: View {
    @ObservedObject var workbench: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var purging: Set<UUID> = []
    /// What the confirmation asks to delete for good; every entry when it lists them all.
    @State private var confirming: [TrashedProfile]?

    private var entries: [TrashedProfile] { workbench.store?.trashed ?? [] }

    var body: some View {
        WorkbenchSheet(title: "回收站",
                       caption: "移到回收站的 Profile 保留浏览器资料、端口和身份，\(TrashedProfile.retentionDays) 天后自动永久删除。恢复后回到原来的位置，浏览器资料照常使用。",
                       width: 620) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty {
                        Text("回收站是空的。")
                            .font(.system(size: 12))
                            .foregroundColor(WorkbenchPalette.muted)
                            .padding(12)
                    }
                    ForEach(entries) { entry in
                        row(entry)
                        Rectangle().fill(WorkbenchPalette.rule).frame(height: 1)
                    }
                }
            }
            .frame(height: 320)
            .background(WorkbenchPalette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WorkbenchPalette.rule, lineWidth: 1)
            }
            HStack(spacing: 10) {
                Button("清空回收站…") { confirming = entries }
                    .buttonStyle(WorkbenchButtonStyle(.quiet))
                    .disabled(entries.isEmpty || !purging.isEmpty || workbench.coordinator == nil || !workbench.canWrite)
                    .accessibilityIdentifier("trash-empty")
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .alert(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { doomed in
            Button("永久删除", role: .destructive) { purge(doomed.map(\.id)) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("配置、Cookie、登录状态、历史记录和扩展数据都会删除，无法恢复。")
        }
    }

    private var confirmTitle: String {
        guard let confirming else { return "" }
        if confirming.count == 1 { return "永久删除「\(confirming[0].profile.name)」？" }
        return "永久删除回收站中的 \(confirming.count) 个 Profile？"
    }

    private func row(_ entry: TrashedProfile) -> some View {
        let days = entry.daysRemaining(retention: TrashedProfile.retentionDays)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.profile.name.isEmpty ? "未命名 Profile" : entry.profile.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(verbatim: ([entry.profile.group.isEmpty ? nil : entry.profile.group,
                                 "127.0.0.1:\(entry.profile.port)",
                                 "移除于 \(Self.date.string(from: entry.deletedAt))"] as [String?])
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundColor(WorkbenchPalette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(days > 0 ? "\(days) 天后删除" : "即将删除")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(days <= 3 ? WorkbenchPalette.amber : WorkbenchPalette.muted)
                .monospacedDigit()
            if purging.contains(entry.id) {
                ProgressView().controlSize(.small)
            }
            Button("恢复") { workbench.restoreFromTrash(entry.id) }
                .buttonStyle(WorkbenchButtonStyle(.neutral))
                .disabled(purging.contains(entry.id) || !workbench.canWrite)
                .accessibilityIdentifier("trash-restore-\(entry.id.uuidString)")
            Button("永久删除…") { confirming = [entry] }
                .buttonStyle(WorkbenchButtonStyle(.quiet))
                .disabled(purging.contains(entry.id) || workbench.coordinator == nil || !workbench.canWrite)
                .help(workbench.coordinator == nil ? "内置浏览器不可用，无法删除浏览器资料。" : "删除配置和浏览器资料")
                .accessibilityIdentifier("trash-purge-\(entry.id.uuidString)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private func purge(_ ids: [UUID]) {
        purging.formUnion(ids)
        Task {
            await workbench.purge(ids)
            purging.subtract(ids)
        }
    }

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Rows the store could not read, and browser data directories no row owns.
struct RepairSheet: View {
    @ObservedObject var workbench: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var sizes: [UUID: Int64] = [:]
    @State private var confirmingRow: UnreadableProfile?
    @State private var confirmingOrphan: UUID?
    @State private var deleting: Set<UUID> = []

    private var rows: [UnreadableProfile] { workbench.store?.unreadableRows ?? [] }
    private var orphans: [UUID] { workbench.library.orphans }

    var body: some View {
        WorkbenchSheet(title: "资料库检查",
                       caption: "无法读取的配置原样留在数据库里，继续占用端口和种子，直到删除。未关联的资料目录是浏览器资料还在、但没有 Profile 使用的目录，例如以前「仅移除记录」留下的。",
                       width: 640) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("无法读取的配置", count: rows.count,
                            empty: "没有无法读取的配置。") {
                        ForEach(rows) { row in unreadable(row) }
                    }
                    section("未关联的资料目录", count: orphans.count,
                            empty: "没有未关联的资料目录。") {
                        ForEach(orphans, id: \.self) { id in orphan(id) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 340)
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onAppear {
            workbench.library.refreshOrphans(workbench.store)
            measure()
        }
        .onChange(of: orphans) { _ in measure() }
        .alert("删除这份无法读取的配置？", isPresented: Binding(get: { confirmingRow != nil },
                                                      set: { if !$0 { confirmingRow = nil } }),
               presenting: confirmingRow) { row in
            Button("删除", role: .destructive) { workbench.deleteUnreadable(row) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("数据库里的这一行会被删除，无法恢复；需要时先导出原始 JSON。它的浏览器资料目录保留。")
        }
        .alert("删除这个资料目录？", isPresented: Binding(get: { confirmingOrphan != nil },
                                                 set: { if !$0 { confirmingOrphan = nil } }),
               presenting: confirmingOrphan) { id in
            Button("删除", role: .destructive) {
                deleting.insert(id)
                Task {
                    await workbench.deleteOrphan(id)
                    deleting.remove(id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("目录里的 Cookie、登录状态、历史记录和扩展数据都会删除，无法恢复。")
        }
    }

    private func section<Content: View>(_ title: String, count: Int, empty: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(count.formatted())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(WorkbenchPalette.muted)
            }
            if count == 0 {
                Text(empty)
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
            }
            content()
        }
    }

    private func unreadable(_ row: UnreadableProfile) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: row.id)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "端口 \(row.port) · 种子 \(row.seed)")
                    .font(.system(size: 11))
                    .foregroundColor(WorkbenchPalette.muted)
                Text(row.reason)
                    .font(.system(size: 11))
                    .foregroundColor(WorkbenchPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("导出原始 JSON…") { workbench.exportUnreadable(row) }
                .buttonStyle(WorkbenchButtonStyle(.neutral))
            Button("删除…") { confirmingRow = row }
                .buttonStyle(WorkbenchButtonStyle(.quiet))
                .disabled(!workbench.canWrite)
        }
        .padding(12)
        .background(WorkbenchPalette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unreadable-\(row.id)")
    }

    private func orphan(_ id: UUID) -> some View {
        let folder = directory(id)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: id.uuidString.lowercased())
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sizes[id].map { "约 \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "正在计算大小…")
                    .font(.system(size: 11))
                    .foregroundColor(WorkbenchPalette.muted)
            }
            .textSelection(.enabled)
            Spacer(minLength: 8)
            if deleting.contains(id) {
                ProgressView().controlSize(.small)
            }
            Button {
                if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(WorkbenchButtonStyle(.quiet))
            .help("在 Finder 中显示")
            .accessibilityLabel("在 Finder 中显示")
            Button("沿用此目录新建 Profile") { workbench.adoptOrphan(id) }
                .buttonStyle(WorkbenchButtonStyle(.neutral))
                .disabled(!workbench.canWrite || deleting.contains(id))
                .help("新建一个使用这个资料目录的 Profile：保留目录里的 Cookie 和登录状态，端口和身份重新生成")
                .accessibilityIdentifier("orphan-adopt-\(id.uuidString)")
            Button("删除…") { confirmingOrphan = id }
                .buttonStyle(WorkbenchButtonStyle(.quiet))
                .disabled(workbench.runtime == nil || deleting.contains(id))
                .accessibilityIdentifier("orphan-delete-\(id.uuidString)")
        }
        .padding(12)
        .background(WorkbenchPalette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func directory(_ id: UUID) -> URL? {
        workbench.store?.directory.appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Adds up the directories' sizes off the main thread; browser data can run to gigabytes.
    private func measure() {
        let targets = orphans.filter { sizes[$0] == nil }.compactMap { id in directory(id).map { (id, $0) } }
        guard !targets.isEmpty else { return }
        Task {
            let measured = await Task.detached(priority: .utility) {
                targets.map { ($0.0, Self.size(of: $0.1)) }
            }.value
            for (id, size) in measured { sizes[id] = size }
        }
    }

    private nonisolated static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
