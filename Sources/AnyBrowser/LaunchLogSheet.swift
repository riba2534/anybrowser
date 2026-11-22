import AnyBrowserCore
import AppKit
import SwiftUI

/// What the Profile's browser printed during its latest launch from this AnyBrowser, up to the
/// last 64 KB, for diagnosing a launch that failed.
struct LaunchLogSheet: View {
    @ObservedObject var workbench: Workbench
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var copied = false

    private var name: String { workbench.profiles.first { $0.id == id }?.name ?? "Profile" }

    var body: some View {
        WorkbenchSheet(title: "启动日志：\(name)",
                       caption: "浏览器在这次启动中输出的内容（最多保留最后 64 KB），以及 AnyBrowser 记下的退出状态。反馈启动问题时可以附上。",
                       width: 680) {
            Group {
                if let text, !text.isEmpty {
                    ScrollView {
                        Text(verbatim: text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                } else {
                    Text("这个 Profile 在本次打开 AnyBrowser 后没有启动过，或浏览器没有任何输出。")
                        .font(.system(size: 12))
                        .foregroundColor(WorkbenchPalette.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                }
            }
            .frame(height: 360)
            .fieldSurface()
            .accessibilityIdentifier("launch-log-text")
            HStack(spacing: 10) {
                Button("刷新") { reload() }
                    .buttonStyle(WorkbenchButtonStyle(.quiet))
                Button(copied ? "已复制" : "复制全部") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(text ?? "", forType: .string)
                }
                .buttonStyle(WorkbenchButtonStyle(.neutral))
                .disabled((text ?? "").isEmpty)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(WorkbenchButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        text = workbench.launchLogText(id)
        copied = false
    }
}
