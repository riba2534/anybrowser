import AnyBrowserCore
import AppKit
import SwiftUI

/// Start pages, window placement and extra extensions.
struct LaunchOptionsCard: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench
    @State private var window: WindowText
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    init(draft: Binding<ProfileDraft>, workbench: Workbench) {
        _draft = draft
        self.workbench = workbench
        _window = State(initialValue: WindowText(draft.wrappedValue.profile.launch.window))
    }

    var body: some View {
        WorkbenchCard {
            CardHeading(title: "启动选项", icon: "play.rectangle")
            startPages
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
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
            extensions
            Text("保存并重启 Profile 后生效。")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
        }
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
                .background(WorkbenchPalette.field, in: fieldShape)
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
                .overlay { fieldShape.strokeBorder(WorkbenchPalette.rule, lineWidth: 1) }
                .accessibilityLabel("启动网址")
                .accessibilityIdentifier("launch-start-urls")
            Text("只支持 http 和 https，最多 \(LaunchOptions.maximumStartURLs) 个。留空打开浏览器默认页面。")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
        }
    }

    private var extensions: some View {
        let directories = draft.profile.launch.extensionDirectories
        let unavailable = Set(draft.profile.launch.unavailableExtensionDirectories())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("额外扩展")
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
                 ? "可加载未打包的扩展目录（含 manifest.json），最多 \(LaunchOptions.maximumExtensionDirectories) 个。Passkey Box 始终加载。"
                 : "按列表顺序在 Passkey Box 之后加载。")
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

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
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
