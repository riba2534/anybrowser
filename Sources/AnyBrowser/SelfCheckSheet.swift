import AnyBrowserCore
import SwiftUI

/// The self-check report: what a page in the running browser reads, item by item against the
/// saved configuration.
struct SelfCheckSheet: View {
    @ObservedObject var workbench: Workbench
    /// The run the sheet opened for; the Workbench holds its progress.
    let opened: Workbench.SelfCheckRun
    @Environment(\.dismiss) private var dismiss

    private var run: Workbench.SelfCheckRun {
        workbench.selfCheck.flatMap { $0.id == opened.id ? $0 : nil } ?? opened
    }

    var body: some View {
        WorkbenchSheet(title: "自检：\(run.name)",
                       caption: "在这个 Profile 的浏览器里打开一个本机回环页面（127.0.0.1），读取网页能看到的值后关闭，再与已保存的配置逐项比对。不访问任何外部网站。",
                       width: 640) {
            content
            HStack(spacing: 10) {
                if case .running = run.phase {} else {
                    Button("重新自检") {
                        Task { await workbench.runSelfCheck(run.id) }
                    }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .disabled(!workbench.state(for: run.id).isRunning)
                    .accessibilityIdentifier("self-check-again")
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(WorkbenchButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch run.phase {
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在浏览器里运行自检…")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        case .failed(let message):
            ErrorLabel("自检没有完成：\(message)")
        case .finished(let report):
            summary(report)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(report.items, id: \.id) { item in
                        row(item)
                        if item.id != report.items.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 420)
            .fieldSurface()
            .accessibilityIdentifier("self-check-items")
        }
    }

    private func summary(_ report: SelfCheckReport) -> some View {
        let failed = report.items.filter { $0.status == .fail }.count
        let hints = report.items.filter { $0.status == .info }.count
        let time = DateFormatter.localizedString(from: report.checkedAt, dateStyle: .none, timeStyle: .medium)
        return VStack(alignment: .leading, spacing: 4) {
            Label(failed == 0 ? "全部通过" : "\(failed) 项失败",
                  systemImage: failed == 0 ? "checkmark.seal" : "xmark.octagon")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(failed == 0 ? WorkbenchPalette.green : WorkbenchPalette.danger)
            Text("共 \(report.items.count) 项，\(hints) 项仅供参考 · \(time)")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
            if run.pendingRestart {
                Text("浏览器仍在使用重启前的配置，与保存的配置不同的项会显示为失败。重启后再自检。")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("self-check-summary")
    }

    private func row(_ item: SelfCheckReport.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon(item.status))
                .foregroundColor(color(item.status))
                .frame(width: 16)
                .accessibilityLabel(statusTitle(item.status))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(statusTitle(item.status))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(color(item.status))
                }
                if let expected = item.expected {
                    Text("配置：\(expected)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(WorkbenchPalette.muted)
                }
                Text("网页读到：\(item.observed.isEmpty ? "（空）" : item.observed)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(WorkbenchPalette.muted)
                if let note = item.note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundColor(item.status == .fail ? WorkbenchPalette.danger : WorkbenchPalette.muted)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("self-check-\(item.id)")
    }

    private func icon(_ status: SelfCheckReport.Status) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        case .info: return "info.circle"
        }
    }

    private func color(_ status: SelfCheckReport.Status) -> Color {
        switch status {
        case .pass: return WorkbenchPalette.green
        case .fail: return WorkbenchPalette.danger
        case .info: return WorkbenchPalette.muted
        }
    }

    private func statusTitle(_ status: SelfCheckReport.Status) -> String {
        switch status {
        case .pass: return "通过"
        case .fail: return "失败"
        case .info: return "提示"
        }
    }
}
