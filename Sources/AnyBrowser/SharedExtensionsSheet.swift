import AnyBrowserCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The shared extension library and which extensions each Profile cannot load, as last checked.
/// Every file operation runs off the main thread: copying, unpacking, deleting, and the checks of
/// extension folders, which may sit on a slow or disconnected volume.
@MainActor
final class ExtensionShelf: ObservableObject {
    /// Extension directories and shared extensions a Profile lists that cannot be loaded.
    struct Availability: Equatable {
        var directories: [String]
        var shared: [String]
        var missingDirectories: Set<String>
        var missingShared: Set<String>
    }

    @Published private(set) var entries: [SharedExtension] = []
    @Published private(set) var loaded = false
    @Published private(set) var working = false
    @Published private(set) var availability: [UUID: Availability] = [:]
    let storage: URL?

    init(storage: URL?) {
        self.storage = storage
    }

    func reload() async {
        guard let storage else { return }
        entries = await Task.detached { SharedExtensions.list(in: storage) }.value
        loaded = true
    }

    /// What the Profile's lists could not load at the last check; nil until a check of exactly
    /// these lists is in, so a path just added is not shown as missing meanwhile.
    func missing(for options: LaunchOptions, id: UUID) -> Availability? {
        guard let found = availability[id], found.directories == options.extensionDirectories,
              found.shared == options.sharedExtensions else { return nil }
        return found
    }

    /// Checks the Profile's extension directories and shared extensions in the background.
    func check(_ profile: BrowserProfile) {
        let id = profile.id
        let options = profile.launch
        let storage = self.storage
        Task {
            let found = await Task.detached { () -> Availability in
                Availability(directories: options.extensionDirectories, shared: options.sharedExtensions,
                             missingDirectories: Set(options.unavailableExtensionDirectories()),
                             missingShared: Set(storage.map { SharedExtensions.unavailable(options.sharedExtensions, in: $0) }
                                 ?? options.sharedExtensions))
            }.value
            availability[id] = found
        }
    }

    /// Adds folders and CRX files; returns what to tell the user. Entries the library already
    /// holds are reported as such.
    func add(_ urls: [URL]) async -> (message: String, isError: Bool) {
        guard let storage else { return (Workbench.storeUnavailable, true) }
        working = true
        defer { working = false }
        let before = Set(entries.map(\.name))
        var added: [String] = []
        var present: [String] = []
        var failures: [String] = []
        for url in urls {
            let result = await Task.detached { () -> Result<SharedExtension, Error> in
                Result {
                    url.pathExtension.lowercased() == "crx"
                        ? try SharedExtensions.add(crx: url, in: storage)
                        : try SharedExtensions.add(folder: url, in: storage)
                }
            }.value
            switch result {
            case .success(let entry) where before.contains(entry.name) || added.contains(entry.name):
                present.append(entry.name)
            case .success(let entry):
                added.append(entry.name)
            case .failure(let error):
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        await reload()
        var parts: [String] = []
        if !added.isEmpty { parts.append("已添加 " + added.map { "「\($0)」" }.joined(separator: "、") + "。") }
        if !present.isEmpty { parts.append(present.map { "「\($0)」" }.joined(separator: "、") + "已在扩展库中，没有重复添加。") }
        parts += failures
        return (parts.joined(separator: "\n"), !failures.isEmpty)
    }

    func remove(_ name: String) async -> String? {
        guard let storage else { return Workbench.storeUnavailable }
        working = true
        defer { working = false }
        let result = await Task.detached { Result { try SharedExtensions.remove(name, in: storage) } }.value
        await reload()
        if case .failure(let error) = result { return error.localizedDescription }
        return nil
    }
}

/// Adds extensions to the shared library and deletes them.
struct SharedExtensionsSheet: View {
    @ObservedObject var workbench: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var message: (text: String, isError: Bool)?
    @State private var removal: SharedExtension?

    private var shelf: ExtensionShelf { workbench.extensionShelf }

    var body: some View {
        WorkbenchSheet(title: "共享扩展库",
                       caption: "扩展库里的扩展可以在各个 Profile 的「启动选项」里勾选加载。扩展数据（登录状态、钱包等）保存在各个 Profile 自己的浏览器资料里，Profile 之间不共享。扩展库里的扩展不会自动更新：更新时先删除旧版本，再添加新版本。",
                       width: 560) {
            entryList
            if let message {
                if message.isError {
                    ErrorLabel(message.text)
                } else {
                    Text(message.text)
                        .font(.system(size: 12))
                        .foregroundColor(WorkbenchPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 10) {
                Button {
                    pick(folders: true)
                } label: {
                    Label("添加文件夹…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(WorkbenchButtonStyle(.neutral))
                .accessibilityIdentifier("shared-extensions-add-folder")
                Button {
                    pick(folders: false)
                } label: {
                    Label("添加 CRX…", systemImage: "shippingbox")
                }
                .buttonStyle(WorkbenchButtonStyle(.neutral))
                .accessibilityIdentifier("shared-extensions-add-crx")
                if shelf.working {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(WorkbenchButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(shelf.storage == nil)
        }
        .task { await shelf.reload() }
        .alert("删除共享扩展？", isPresented: showRemoval, presenting: removal) { entry in
            Button("删除", role: .destructive) {
                Task { await remove(entry) }
            }
            Button("取消", role: .cancel) {}
        } message: { entry in
            Text(removalWarning(entry))
        }
    }

    @ViewBuilder private var entryList: some View {
        if shelf.entries.isEmpty {
            Text(shelf.loaded ? "扩展库是空的。可以添加未打包的扩展文件夹（顶层有 manifest.json），或 CRX3 格式的 .crx 文件。" : "正在读取扩展库…")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shelf.entries) { entry in
                        row(entry)
                        if entry.id != shelf.entries.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 280)
            .fieldSurface()
        }
    }

    private func row(_ entry: SharedExtension) -> some View {
        let users = workbench.profiles.filter { $0.launch.sharedExtensions.contains(entry.name) }
        return HStack(spacing: 10) {
            Image(systemName: entry.isValid ? "puzzlepiece.extension" : "exclamationmark.triangle")
                .foregroundColor(entry.isValid ? WorkbenchPalette.muted : WorkbenchPalette.danger)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if !entry.version.isEmpty {
                        Text(verbatim: entry.version)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(WorkbenchPalette.muted)
                    }
                }
                Text(detail(entry, users: users.count))
                    .font(.system(size: 11))
                    .foregroundColor(entry.isValid ? WorkbenchPalette.muted : WorkbenchPalette.danger)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                removal = entry
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(WorkbenchButtonStyle(.quiet))
            .disabled(shelf.working)
            .help("从扩展库删除")
            .accessibilityLabel("删除 \(entry.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityIdentifier("shared-extension-\(entry.name)")
    }

    private func detail(_ entry: SharedExtension, users: Int) -> String {
        guard entry.isValid else { return "无效：缺少 manifest.json 或无法读取。勾选它的 Profile 不能启动，请删除后重新添加。" }
        let name = entry.manifestName == entry.name || entry.manifestName.isEmpty ? "" : entry.manifestName + " · "
        return name + (users == 0 ? "没有 Profile 使用" : "\(users) 个 Profile 使用")
    }

    private func removalWarning(_ entry: SharedExtension) -> String {
        let users = workbench.profiles.filter { $0.launch.sharedExtensions.contains(entry.name) }
        let running = users.filter { workbench.state(for: $0.id).isRunning }
        var text = "「\(entry.name)」将从扩展库删除。"
        if !running.isEmpty {
            let names = running.prefix(3).map { "「\($0.name)」" }.joined(separator: "、")
            text += "正在运行的 \(names)\(running.count > 3 ? " 等 \(running.count) 个 Profile" : "")在使用它，浏览器里的这个扩展会失效，重启后也无法加载。"
        }
        if !users.isEmpty {
            text += "勾选它的 \(users.count) 个 Profile 在取消勾选或重新添加之前不能启动。"
        }
        return text + "各 Profile 里的扩展数据保留。"
    }

    private func pick(folders: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = true
        if folders {
            panel.message = "选择顶层有 manifest.json 的扩展文件夹"
        } else {
            panel.message = "选择 CRX3 格式的扩展文件"
            panel.allowedContentTypes = [UTType(filenameExtension: "crx") ?? .data]
        }
        panel.prompt = "添加"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        message = nil
        Task {
            let result = await shelf.add(urls)
            message = (result.message, result.isError)
            if let draft = workbench.draft { shelf.check(draft.profile) }
        }
    }

    private func remove(_ entry: SharedExtension) async {
        if let error = await shelf.remove(entry.name) {
            message = (error, true)
        } else {
            message = ("已删除「\(entry.name)」。", false)
        }
        if let draft = workbench.draft { shelf.check(draft.profile) }
    }

    private var showRemoval: Binding<Bool> {
        Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    }
}
