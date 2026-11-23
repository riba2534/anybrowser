import AnyBrowserCore
import AppKit
import SwiftUI

/// Start pages, session restore, window placement, Passkey Box and extensions.
struct LaunchOptionsCard: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench
    @State private var window: WindowText

    init(draft: Binding<ProfileDraft>, workbench: Workbench) {
        _draft = draft
        self.workbench = workbench
        _window = State(initialValue: WindowText(draft.wrappedValue.profile.launch.window))
    }

    private var shelf: ExtensionShelf { workbench.extensionShelf }

    var body: some View {
        WorkbenchCard {
            CardHeading(title: "启动选项", icon: "play.rectangle")
            startPages
            VStack(alignment: .leading, spacing: 6) {
                Toggle("无痕启动", isOn: $draft.profile.launch.incognito)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("launch-incognito")
                Text(draft.profile.launch.incognito
                     ? "启动时打开无痕窗口：Cookie 与站点数据不写入磁盘，页面读到的存储配额按内存压缩，自检会按无痕值检查配额。无痕窗口同样经过代理。"
                     : "关闭时按普通窗口启动，资料保存在这个 Profile 自己的目录里。")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("恢复上次会话", isOn: $draft.profile.launch.restoreSession)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("launch-restore-session")
                Text("启动时重新打开上次退出时的标签页，启动网址照常打开。")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
            }
            LazyVGrid(columns: EditorInput.columns, alignment: .leading, spacing: 12) {
                EditorInput("窗口宽度", placeholder: "默认", value: $window.width,
                            identifier: "launch-window-width", numeric: true)
                EditorInput("窗口高度", placeholder: "默认", value: $window.height,
                            identifier: "launch-window-height", numeric: true)
                EditorInput("窗口位置 X", placeholder: "默认", value: $window.x,
                            identifier: "launch-window-x", numeric: true)
                EditorInput("窗口位置 Y", placeholder: "默认", value: $window.y,
                            identifier: "launch-window-y", numeric: true)
            }
            Divider()
            passkeyBox
            Divider()
            sharedExtensions
            Divider()
            extensions
            Text("除启动网址外，修改在保存并重启 Profile 后生效。")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
        }
        // Folder checks never run in `body`: they may block on a slow or disconnected volume.
        .onAppear { shelf.check(draft.profile) }
        .onChange(of: draft.profile.launch.extensionDirectories) { _ in shelf.check(draft.profile) }
        .onChange(of: draft.profile.launch.sharedExtensions) { _ in shelf.check(draft.profile) }
        .onChange(of: window) { text in
            if draft.profile.launch.window != text.layout { draft.profile.launch.window = text.layout }
        }
        .onChange(of: draft.profile.launch.window) { layout in
            // Reloaded or saved from elsewhere: show what the Profile now holds.
            if window.layout != layout { window = WindowText(layout) }
        }
    }

    private var startURLText: Binding<String> {
        Binding {
            draft.profile.launch.startURLs.joined(separator: "\n")
        } set: { text in
            // Lines are kept as typed; validated() trims them and drops blanks on save.
            draft.profile.launch.startURLs = text.isEmpty ? [] : text.components(separatedBy: "\n")
        }
    }

    private var startPages: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("启动网址")
                .font(.system(size: 12, weight: .medium))
                .accessibilityHidden(true)
            TextEditor(text: startURLText)
                .font(.system(size: 13, design: .monospaced))
                .modifier(HiddenEditorBackground())
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .frame(height: 84)
                .fieldSurface()
                .overlay(alignment: .topLeading) {
                    if draft.profile.launch.startURLs.isEmpty {
                        Text("每行一个，例如 https://example.com")
                            .font(.system(size: 13))
                            .foregroundColor(WorkbenchPalette.muted)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("启动网址")
                .accessibilityIdentifier("launch-start-urls")
            Text("只支持 http 和 https，最多 \(LaunchOptions.maximumStartURLs) 个。留空打开浏览器默认页面。修改后不需要重启，下次启动时打开。")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
        }
    }

    private var passkeyBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("加载 Passkey Box", isOn: $draft.profile.launch.loadPasskeyBox)
                .toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .medium))
                .accessibilityIdentifier("launch-load-passkey-box")
            Text(draft.profile.launch.loadPasskeyBox
                 ? "内置的 Passkey Box 扩展用于网站的通行密钥注册和登录。不用通行密钥的 Profile 可以关闭。"
                 : "不加载 Passkey Box：网页里没有它改写的 WebAuthn 接口；下次启动时删除这个 Profile 的扩展副本和其中的账号配置。")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Extensions from the shared library this Profile loads, in the order they were ticked.
    private var sharedExtensions: some View {
        let picked = draft.profile.launch.sharedExtensions
        let missing = shelf.missing(for: draft.profile.launch, id: draft.profile.id)?.missingShared ?? []
        let listed = Set(shelf.entries.map(\.name))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("共享扩展")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Button {
                    workbench.showingSharedExtensions = true
                } label: {
                    Label("管理共享扩展…", systemImage: "puzzlepiece.extension")
                }
                .buttonStyle(WorkbenchButtonStyle(.neutral))
                .disabled(shelf.storage == nil)
                .accessibilityIdentifier("launch-manage-shared-extensions")
            }
            if shelf.entries.isEmpty && picked.isEmpty {
                Text(shelf.loaded ? "扩展库是空的。在「管理共享扩展…」里添加扩展后，可以在这里勾选。" : "正在读取扩展库…")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
            }
            LazyVGrid(columns: EditorInput.columns, alignment: .leading, spacing: 8) {
                ForEach(shelf.entries) { entry in
                    Toggle(isOn: sharedBinding(entry.name)) {
                        HStack(spacing: 4) {
                            Text(entry.name)
                                .lineLimit(1)
                            if let order = picked.firstIndex(of: entry.name), picked.count > 1 {
                                Text(verbatim: "#\(order + 1)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(WorkbenchPalette.muted)
                            }
                            if !entry.isValid || missing.contains(entry.name) {
                                Text("无效")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(WorkbenchPalette.danger)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .help(entry.manifestName.isEmpty ? entry.name : "\(entry.manifestName) \(entry.version)")
                    .accessibilityIdentifier("launch-shared-\(entry.name)")
                }
            }
            // Ticked, but gone from the library: the Profile does not start until it is unticked or added again.
            ForEach(picked.filter { shelf.loaded && !listed.contains($0) }, id: \.self) { name in
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 12))
                        .foregroundColor(WorkbenchPalette.danger)
                    Text("已不在扩展库中")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(WorkbenchPalette.danger)
                    Spacer(minLength: 0)
                    Button("取消勾选") { draft.profile.launch.sharedExtensions.removeAll { $0 == name } }
                        .buttonStyle(WorkbenchButtonStyle(.quiet))
                }
            }
            if !picked.isEmpty {
                Text("按勾选的顺序加载，在 Passkey Box 之后、下面的扩展目录之前。扩展数据保存在这个 Profile 自己的浏览器资料里。")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sharedBinding(_ name: String) -> Binding<Bool> {
        Binding {
            draft.profile.launch.sharedExtensions.contains(name)
        } set: { isOn in
            if isOn {
                if !draft.profile.launch.sharedExtensions.contains(name) { draft.profile.launch.sharedExtensions.append(name) }
            } else {
                draft.profile.launch.sharedExtensions.removeAll { $0 == name }
            }
        }
    }

    private var extensions: some View {
        let directories = draft.profile.launch.extensionDirectories
        let unavailable = shelf.missing(for: draft.profile.launch, id: draft.profile.id)?.missingDirectories ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("扩展目录")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Button {
                    addExtensions()
                } label: {
                    Label("添加目录…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(WorkbenchButtonStyle(.neutral))
                .disabled(directories.count >= LaunchOptions.maximumExtensionDirectories)
                .accessibilityIdentifier("launch-add-extension")
            }
            ForEach(directories, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundColor(WorkbenchPalette.muted)
                        .accessibilityHidden(true)
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(unavailable.contains(path) ? WorkbenchPalette.danger : WorkbenchPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                    if unavailable.contains(path) {
                        Text("不可用")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(WorkbenchPalette.danger)
                            .help("目录不存在，或其中没有 manifest.json。")
                    }
                    Spacer(minLength: 0)
                    Button {
                        draft.profile.launch.extensionDirectories.removeAll { $0 == path }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(WorkbenchButtonStyle(.quiet))
                    .accessibilityLabel("移除 \(path)")
                    .help("移除")
                }
            }
            Text(directories.isEmpty
                 ? "可加载这个 Profile 自己的未打包扩展目录（含 manifest.json），最多 \(LaunchOptions.maximumExtensionDirectories) 个。多个 Profile 共用的扩展可以放进共享扩展库。"
                 : "按列表顺序在共享扩展之后加载；与共享扩展是同一个扩展时以这里的目录为准。")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
        }
    }

    private func addExtensions() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择包含 manifest.json 的扩展目录"
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !draft.profile.launch.extensionDirectories.contains(url.path) {
            draft.profile.launch.extensionDirectories.append(url.path)
        }
    }
}

/// The window fields as typed. Blank means unset; anything that is not an integer maps to a
/// value LaunchOptions.validated() rejects, so the mistake is reported on save.
private struct WindowText: Equatable {
    var width = ""
    var height = ""
    var x = ""
    var y = ""

    init(_ layout: WindowLayout?) {
        guard let layout else { return }
        width = layout.width == 0 ? "" : String(layout.width)
        height = layout.height == 0 ? "" : String(layout.height)
        x = layout.x.map(String.init) ?? ""
        y = layout.y.map(String.init) ?? ""
    }

    var layout: WindowLayout? {
        let fields = [width, height, x, y].map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.contains(where: { !$0.isEmpty }) else { return nil }
        func number(_ text: String) -> Int? { text.isEmpty ? nil : Int(text) ?? Int.min }
        return WindowLayout(width: number(fields[0]) ?? 0, height: number(fields[1]) ?? 0,
                            x: number(fields[2]), y: number(fields[3]))
    }
}

private struct HiddenEditorBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}
