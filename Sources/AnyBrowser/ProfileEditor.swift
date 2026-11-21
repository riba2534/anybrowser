import AnyBrowserCore
import SwiftUI

/// The Profile form: each card owns one area of the Profile.
struct ProfileEditor: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkbenchCard {
                CardHeading(title: "基本设置", icon: "macwindow")
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    EditorInput("Profile 名称", placeholder: "例如 工作环境",
                                value: $draft.profile.name, identifier: "profile-name")
                    EditorInput("调试端口", placeholder: "9222",
                                value: $draft.portText, identifier: "debug-port", numeric: true)
                }
                Divider()
                debugRow
            }
            OrganizationCard(draft: $draft, workbench: workbench)
            IdentityCard(draft: $draft, workbench: workbench)
            FingerprintCard(draft: $draft, workbench: workbench)
            ProxyCard(draft: $draft, workbench: workbench)
            LaunchOptionsCard(draft: $draft, workbench: workbench)
        }
    }

    private var state: BrowserRunState { workbench.state(for: draft.profile.id) }
    private var pendingRestart: Bool { workbench.hasPendingRestart(draft.profile.id) }
    private func copyAddress(_ port: Int) { workbench.copyAddress(port) }

    private var debugRow: some View {
        let session: (port: Int, ready: Bool)?
        if case .running(_, let port, let ready) = state {
            session = (port, ready)
        } else {
            session = nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(state.indicator).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(state.statusTitle)
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(WorkbenchPalette.iconSurface, in: Capsule())
                .accessibilityIdentifier("browser-status")
                if pendingRestart {
                    Text("等待重启")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(WorkbenchPalette.amber)
                }
                Spacer(minLength: 0)
                if let session, session.ready {
                    Text(verbatim: "http://127.0.0.1:\(session.port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(WorkbenchPalette.muted)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("debug-address")
                    Button {
                        copyAddress(session.port)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(WorkbenchButtonStyle(.quiet))
                    .accessibilityLabel("复制调试地址")
                    .accessibilityIdentifier("copy-debug-address")
                    .help("复制调试地址")
                } else {
                    Text(session == nil ? "调试地址仅在本机可用" : "调试端口未就绪")
                        .font(.system(size: 11))
                        .foregroundColor(WorkbenchPalette.muted)
                }
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.danger)
                    .textSelection(.enabled)
            }
        }
    }

}

struct CardHeading: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

struct EditorInput: View {
    let label: String
    let placeholder: String
    @Binding var value: String
    let identifier: String
    var numeric = false
    var secure = false
    @FocusState private var focused: Bool

    init(_ label: String, placeholder: String, value: Binding<String>, identifier: String,
         numeric: Bool = false, secure: Bool = false) {
        self.label = label
        self.placeholder = placeholder
        self._value = value
        self.identifier = identifier
        self.numeric = numeric
        self.secure = secure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .accessibilityHidden(true)
            field
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: numeric ? .monospaced : .default))
                .focused($focused)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(WorkbenchPalette.field, in: fieldShape)
                .overlay { fieldShape.strokeBorder(focused ? Color.accentColor : WorkbenchPalette.rule, lineWidth: 1) }
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var field: some View {
        let prompt = Text(placeholder).foregroundColor(WorkbenchPalette.muted)
        if secure {
            SecureField(label, text: $value, prompt: prompt)
        } else {
            TextField(label, text: $value, prompt: prompt)
        }
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }
}

struct EditorPicker<Value: Hashable>: View {
    let title: String
    let identifier: String
    @Binding var selection: Value
    let choices: [(value: Value, title: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .accessibilityHidden(true)
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(choices.indices, id: \.self) { index in
                        let choice = choices[index]
                        Text(choice.title).tag(choice.value)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(choices.first { $0.value == selection }?.title ?? "")
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(WorkbenchPalette.field, in: fieldShape)
            .overlay { fieldShape.strokeBorder(WorkbenchPalette.rule, lineWidth: 1) }
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
        }
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }
}
