import AnyBrowserCore
import SwiftUI

/// The Passkey Box account the built-in extension of every Profile signs in with.
struct PasskeyBoxSettings: View {
    @ObservedObject var workbench: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var account: PasskeyBoxAccount
    @State private var error: String?
    @State private var saving = false

    init(workbench: Workbench) {
        self.workbench = workbench
        _account = State(initialValue: workbench.passkeyBoxAccount ?? PasskeyBoxAccount())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Passkey Box 账号")
                    .font(.system(size: 18, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("每个 Profile 启动时，内置的 Passkey Box 扩展会用这个账号自动登录。网站请求通行密钥时直接完成注册或登录，不需要点击确认。")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            EditorInput("服务器地址", placeholder: PasskeyBoxAccount.defaultServerURL,
                        value: $account.serverURL, identifier: "passkey-box-server")
            EditorInput("用户名", placeholder: "Passkey Box 用户名",
                        value: $account.username, identifier: "passkey-box-username")
            EditorInput("密码", placeholder: "Passkey Box 密码",
                        value: $account.password, identifier: "passkey-box-password", secure: true)
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if workbench.passkeyBoxAccount != nil {
                    Button("移除账号", role: .destructive) {
                        error = workbench.clearPasskeyBox()
                        if error == nil { dismiss() }
                    }
                    .buttonStyle(WorkbenchButtonStyle(.quiet))
                    .disabled(saving)
                    .accessibilityIdentifier("passkey-box-remove")
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "正在验证…" : "验证并保存") {
                    saving = true
                    error = nil
                    Task {
                        error = await workbench.savePasskeyBox(account)
                        saving = false
                        if error == nil { dismiss() }
                    }
                }
                .buttonStyle(WorkbenchButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
                .accessibilityIdentifier("passkey-box-save")
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(WorkbenchPalette.workspace)
        .foregroundColor(WorkbenchPalette.ink)
    }
}
