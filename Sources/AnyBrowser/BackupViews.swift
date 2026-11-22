import AnyBrowserCore
import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

/// Writes or restores a full backup (`.anybrowser`), showing how far it has come and what
/// happened to each Profile.
struct FullBackupSheet: View {
    enum Mode {
        /// The picked Profiles; every Profile when empty.
        case export([UUID])
        case restore(URL)
    }

    @ObservedObject var workbench: Workbench
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var everything = false
    @State private var identity = ProfileBackup.IdentityPolicy.renew
    @State private var progress: ProfileBackup.Progress?
    @State private var running = false
    @State private var exported: ProfileBackup.ExportResult?
    @State private var restored: ProfileBackup.RestoreResult?
    @State private var error: String?

    var body: some View {
        WorkbenchSheet(title: title, caption: caption, width: 560) {
            if !running && exported == nil && restored == nil {
                options
            }
            if let progress, running {
                VStack(alignment: .leading, spacing: 6) {
                    if progress.total > 0 {
                        ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(progress.total > 0 ? "\(progress.message)（\(progress.completed)/\(progress.total)）" : progress.message)
                        .font(.system(size: 12))
                        .foregroundColor(WorkbenchPalette.muted)
                }
                .accessibilityIdentifier("backup-progress")
            }
            if let exported {
                results(exported.profiles.map { entry in
                    (entry.name.isEmpty ? entry.id.uuidString : entry.name, entry.skipped,
                     "Cookie \(entry.cookies) 个 · \(entry.browserData ? "含浏览器资料" : "不含浏览器资料")", entry.warnings)
                }, warnings: [])
            }
            if let restored {
                results(restored.profiles.map { entry in
                    var summary = entry.profile.map { "恢复为「\($0.name)」· 端口 \($0.port)" } ?? ""
                    summary += entry.browserData ? " · 含浏览器资料" : " · 没有浏览器资料"
                    summary += " · 导入 Cookie \(entry.importedCookies) 个"
                    if entry.skippedCookies > 0 { summary += "（\(entry.skippedCookies) 个未导入）" }
                    return (entry.name, entry.skipped, summary, entry.warnings)
                }, warnings: restored.warnings)
            }
            if let error {
                ErrorLabel(error)
            }
            HStack(spacing: 10) {
                Spacer()
                if exported != nil || restored != nil {
                    Button("完成") { dismiss() }
                        .buttonStyle(WorkbenchButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("取消") { dismiss() }
                        .buttonStyle(WorkbenchButtonStyle(.neutral))
                        .keyboardShortcut(.cancelAction)
                        .disabled(running)
                    Button(actionTitle) { start() }
                        .buttonStyle(WorkbenchButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || !canStart)
                        .accessibilityIdentifier("backup-start")
                }
            }
        }
    }

    private var title: String {
        switch mode {
        case .export: return "导出完整备份"
        case .restore(let file): return "从「\(file.lastPathComponent)」恢复"
        }
    }

    private var caption: String {
        switch mode {
        case .export:
            return "备份包含配置（含代理和 Passkey Box 的账号密码）、全部 Cookie 和浏览器资料（不含缓存），可以在另一台 Mac 上恢复登录状态。文件没有加密，请妥善保管。"
        case .restore:
            return "恢复的 Profile 加入列表，浏览器资料放回原处，Cookie 在后台以无窗口方式启动一次后导入。端口或种子已被占用时重新分配。"
        }
    }

    private var actionTitle: String {
        switch mode {
        case .export: return running ? "正在备份…" : "选择位置并备份…"
        case .restore: return running ? "正在恢复…" : "开始恢复"
        }
    }

    private var canStart: Bool {
        guard workbench.coordinator != nil else { return false }
        switch mode {
        case .export: return !targets.isEmpty
        case .restore: return workbench.canWrite
        }
    }

    /// The Profiles the export covers, in creation order.
    private var targets: [UUID] {
        guard case .export(let picked) = mode else { return [] }
        let all = workbench.profiles.map(\.id)
        guard !everything, !picked.isEmpty else { return all }
        return all.filter(Set(picked).contains)
    }

    @ViewBuilder private var options: some View {
        switch mode {
        case .export(let picked):
            if !picked.isEmpty, picked.count < workbench.profiles.count {
                Picker("备份范围", selection: $everything) {
                    Text("所选的 \(targets.count) 个 Profile").tag(false)
                    Text("全部 \(workbench.profiles.count) 个 Profile").tag(true)
                }
                .pickerStyle(.radioGroup)
                .font(.system(size: 12))
                .accessibilityIdentifier("backup-scope")
            } else {
                Text("将备份全部 \(workbench.profiles.count) 个 Profile。")
                    .font(.system(size: 12, weight: .medium))
            }
            Text("已停止的 Profile 会以无窗口方式短暂启动，读出 Cookie 后停止，再复制浏览器资料。正在运行的 Profile 只备份 Cookie，不含浏览器资料；先停止它可得到完整备份。备份期间这些 Profile 不能启动或修改。")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        case .restore:
            Picker("Profile ID", selection: $identity) {
                Text("作为新 Profile 恢复（新 ID）").tag(ProfileBackup.IdentityPolicy.renew)
                Text("保留原 ID，已被占用时换新 ID").tag(ProfileBackup.IdentityPolicy.keepOriginalOrRenew)
                Text("保留原 ID，已被占用时跳过").tag(ProfileBackup.IdentityPolicy.keepOriginal)
            }
            .pickerStyle(.radioGroup)
            .font(.system(size: 12))
            .accessibilityIdentifier("restore-identity")
            Text("保留原 ID 时，自动化脚本里记下的 Profile ID 继续有效。恢复期间新加入的 Profile 不能启动或修改。")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func results(_ rows: [(name: String, skipped: String?, summary: String, warnings: [String])],
                         warnings: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundColor(WorkbenchPalette.amber)
                }
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: row.skipped == nil ? (row.warnings.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                                                                 : "xmark.circle")
                                .foregroundColor(row.skipped == nil ? (row.warnings.isEmpty ? WorkbenchPalette.green : WorkbenchPalette.amber)
                                                                    : WorkbenchPalette.danger)
                                .accessibilityHidden(true)
                            Text(row.name)
                                .font(.system(size: 13, weight: .medium))
                        }
                        Text(row.skipped.map { "未处理：\($0)" } ?? row.summary)
                            .font(.system(size: 11))
                            .foregroundColor(row.skipped == nil ? WorkbenchPalette.muted : WorkbenchPalette.danger)
                        ForEach(row.warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.system(size: 11))
                                .foregroundColor(WorkbenchPalette.amber)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)
        .accessibilityIdentifier("backup-results")
    }

    private func start() {
        guard let coordinator = workbench.coordinator else { return }
        error = nil
        switch mode {
        case .export:
            let ids = targets
            guard let destination = BackupPanels.saveLocation() else { return }
            running = true
            Task { @MainActor in
                defer { running = false }
                do {
                    let result = try await coordinator.exportBackup(ids, to: destination) { progress = $0 }
                    exported = result
                    workbench.backedUp(result)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        case .restore(let file):
            running = true
            let policy = identity
            Task { @MainActor in
                defer { running = false }
                do {
                    let result = try await coordinator.restoreBackup(from: file, identity: policy) { progress = $0 }
                    restored = result
                    workbench.restored(result)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

enum BackupPanels {
    static let type = UTType(filenameExtension: ProfileBackup.fileExtension) ?? .data

    static func saveLocation() -> URL? {
        FilePanels.saveLocation(title: "导出完整备份", prompt: "备份", message: "文件包含账号密码和 Cookie，没有加密，请存放在安全的位置。",
                                name: "AnyBrowser 备份 \(FilePanels.today).\(ProfileBackup.fileExtension)", types: [type])
    }

    static func backupFile() -> URL? {
        FilePanels.file(title: "从完整备份恢复", prompt: "选择", message: "选择 AnyBrowser 导出的 .\(ProfileBackup.fileExtension) 备份文件。",
                        types: [type])
    }
}

extension Workbench {
    /// "导出完整备份…": the picked Profiles, or every Profile when none is picked.
    func requestFullBackup() {
        library.sheet = .backupExport(batchSelection.map(\.id))
    }

    func requestFullRestore() {
        guard let file = BackupPanels.backupFile() else { return }
        library.sheet = .backupRestore(file)
    }

    fileprivate func backedUp(_ result: ProfileBackup.ExportResult) {
        let done = result.profiles.filter { $0.skipped == nil }
        let incomplete = done.filter { !$0.warnings.isEmpty || !$0.browserData }.count
        var text = "已备份 \(done.count) 个 Profile 到「\(result.file.lastPathComponent)」。"
        if incomplete > 0 { text += "其中 \(incomplete) 个不完整，详见备份窗口。" }
        notice = Notice(text: text, isError: incomplete > 0 || done.count < result.profiles.count)
    }

    fileprivate func restored(_ result: ProfileBackup.RestoreResult) {
        let done = result.profiles.compactMap(\.profile)
        let skipped = result.profiles.count - done.count
        var text = "已从备份恢复 \(done.count) 个 Profile。"
        if skipped > 0 { text += "\(skipped) 个没有恢复，详见恢复窗口。" }
        notice = Notice(text: text, isError: skipped > 0 || !result.warnings.isEmpty)
        if draft == nil, let first = done.first { draft = ProfileDraft(first) }
    }
}

// MARK: Database backups

/// The copies of the Profile database in `Backups/`. Restoring one replaces the database, which
/// only works while no store has it open, so AnyBrowser quits and the next launch restores it
/// before opening the database.
struct DatabaseBackupsSheet: View {
    @ObservedObject var workbench: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var backups: [DatabaseBackup] = []
    @State private var confirming: DatabaseBackup?
    @State private var error: String?

    private var directory: URL? { workbench.store?.directory ?? DatabaseRestore.dataDirectory() }

    var body: some View {
        WorkbenchSheet(title: "资料库备份",
                       caption: "AnyBrowser 每天和每次升级前自动备份一次 Profile 数据库，保留最近 \(ProfileStore.keptBackups) 份。备份里含代理和 Passkey Box 的账号密码，只有当前用户可读。恢复只替换 Profile 配置，不动浏览器资料。",
                       width: 600) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if backups.isEmpty {
                        Text("还没有备份。")
                            .font(.system(size: 12))
                            .foregroundColor(WorkbenchPalette.muted)
                            .padding(12)
                    }
                    ForEach(backups) { backup in
                        row(backup)
                        Rectangle().fill(WorkbenchPalette.rule).frame(height: 1)
                    }
                }
            }
            .frame(height: 280)
            .listPanel()
            if let blocker = restoreBlocker {
                Text(blocker)
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                ErrorLabel(error)
            }
            HStack(spacing: 10) {
                Button("立即备份") { backUpNow() }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .disabled(workbench.store == nil)
                    .accessibilityIdentifier("database-backup-now")
                Button("在 Finder 中显示") {
                    if let directory {
                        NSWorkspace.shared.activateFileViewerSelecting([directory.appendingPathComponent("Backups", isDirectory: true)])
                    }
                }
                .buttonStyle(WorkbenchButtonStyle(.quiet))
                .disabled(directory == nil)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onAppear(perform: reload)
        .alert("恢复这份数据库备份？", isPresented: Binding(showing: $confirming),
               presenting: confirming) { backup in
            Button("恢复并重新启动 AnyBrowser", role: .destructive) { restore(backup) }
            Button("取消", role: .cancel) {}
        } message: { backup in
            Text("AnyBrowser 会退出，用 \(Self.date.string(from: backup.createdAt)) 的备份替换当前的 Profile 数据库，再重新打开。当前数据库先另存为一份备份，可以再恢复回来。这份备份之后新建或修改的配置会丢失；回收站里的 Profile 从恢复时起重新保留 30 天，浏览器资料不受影响。")
        }
    }

    /// Why a backup cannot be restored right now, or nil.
    private var restoreBlocker: String? {
        if workbench.store?.isReadOnly == true {
            return "当前数据库由更新版本的 AnyBrowser 写入，请用那个版本恢复备份。"
        }
        if workbench.hasChanges { return "恢复前请先保存或放弃当前编辑。" }
        if workbench.profiles.contains(where: { workbench.state(for: $0.id).isRunning || workbench.isBusy($0.id) })
            || workbench.library.batchRunning {
            return "恢复前请先停止所有正在运行的浏览器，并等其他操作完成。"
        }
        return nil
    }

    private func row(_ backup: DatabaseBackup) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.date.string(from: backup.createdAt))
                    .font(.system(size: 13, weight: .medium))
                Text(backup.title)
                    .font(.system(size: 11))
                    .foregroundColor(WorkbenchPalette.muted)
            }
            Spacer(minLength: 8)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([backup.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(WorkbenchButtonStyle(.quiet))
            .help("在 Finder 中显示")
            .accessibilityLabel("在 Finder 中显示")
            Button("恢复…") { confirming = backup }
                .buttonStyle(WorkbenchButtonStyle(.neutral))
                .disabled(restoreBlocker != nil)
                .accessibilityIdentifier("database-restore-\(backup.url.lastPathComponent)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private func reload() {
        backups = directory.map { ProfileStore.backups(in: $0).compactMap(DatabaseBackup.init) } ?? []
    }

    private func backUpNow() {
        do {
            try workbench.store?.backup(reason: "manual")
            error = nil
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restore(_ backup: DatabaseBackup) {
        if let blocker = restoreBlocker {
            error = blocker
            return
        }
        do {
            try DatabaseRestore.relaunch(restoring: backup.url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// Restoring a database backup across a relaunch: this run quits, a small shell waits for it to
/// exit and starts AnyBrowser again with the backup to restore, and that run puts it in place
/// while it holds the instance lock and before it opens the database.
@MainActor
enum DatabaseRestore {
    static let argumentPrefix = "--restore-database="
    /// What the restore asked for by the previous run did, for the window to show.
    private(set) static var outcome: String?

    /// The data directory as `SingleInstance` locks it, for when the database could not be opened.
    static func dataDirectory() -> URL? {
        guard let located = try? ProfileStore.defaultDirectory() else { return nil }
        return ProcessInspection.canonicalURL(located, isDirectory: true)
    }

    /// Restores the backup named on the command line, if any. Runs before the store opens.
    static func performRequested(in claim: SingleInstance.Claim?) {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(argumentPrefix) }) else { return }
        let backup = URL(fileURLWithPath: String(argument.dropFirst(argumentPrefix.count)))
        guard let claim, claim.lock != nil else {
            outcome = "未能恢复数据库备份：无法锁定本机 Profile 资料目录。"
            return
        }
        // Only a backup this data directory made: the argument is not a way to load any file.
        let folder = claim.directory.appendingPathComponent("Backups", isDirectory: true)
        guard let parent = ProcessInspection.canonicalURL(backup.deletingLastPathComponent(), isDirectory: true),
              parent.path == ProcessInspection.canonicalURL(folder)?.path,
              let described = DatabaseBackup(backup) else {
            outcome = "未能恢复数据库备份：「\(backup.lastPathComponent)」不是本机资料目录里的备份。"
            return
        }
        do {
            // SQLite refuses a path through a symbolic link, such as /tmp.
            try ProfileStore.restoreBackup(parent.appendingPathComponent(backup.lastPathComponent), into: claim.directory)
            outcome = "已恢复 \(DatabaseBackupsSheet.date.string(from: described.createdAt)) 的 Profile 数据库备份。恢复前的数据库已另存为一份备份，需要时可在「资料库备份」里恢复回去。"
        } catch {
            outcome = "未能恢复数据库备份：\(error.localizedDescription)当前数据库没有改动。"
        }
    }

    /// Starts the waiting shell, then quits. The shell gives up after a minute, in case quitting
    /// was cancelled.
    static func relaunch(restoring backup: URL) throws {
        guard let executable = Bundle.main.executableURL else {
            throw ProfileError.invalid("找不到 AnyBrowser 的可执行文件，无法重新启动。")
        }
        let script = """
            pid="$1"; shift
            i=0
            while kill -0 "$pid" 2>/dev/null; do
                i=$((i + 1))
                [ "$i" -gt 600 ] && exit 1
                sleep 0.1
            done
            exec "$@"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Run directly rather than through `open`, so the new process keeps this one's environment.
        process.arguments = ["-c", script, "anybrowser-restore", String(getpid()), executable.path,
                             argumentPrefix + backup.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ProfileError.invalid("无法重新启动 AnyBrowser：\(error.localizedDescription)")
        }
        NSApp.terminate(nil)
    }
}
