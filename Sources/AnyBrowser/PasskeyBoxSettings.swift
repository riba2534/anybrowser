import AnyBrowserCore
import SwiftUI

/// The Passkey Box account the built-in extension of every Profile signs in with.
struct PasskeyBoxSettings: View {
    @ObservedObject var workbench: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var account: PasskeyBoxAccount
    @State private var error: String?
    /// The verification in flight; cancelling the sheet cancels it, and nothing is saved.
    @State private var saving: Task<Void, Never>?

    init(workbench: Workbench) {
        self.workbench = workbench
        _account = State(initialValue: workbench.passkeyBoxAccount ?? PasskeyBoxAccount())
    }

    var body: some View {
        WorkbenchSheet(title: "Passkey Box 账号",
                       caption: "每个 Profile 启动时，内置的 Passkey Box 扩展会用这个账号自动登录。网站请求通行密钥时直接完成注册或登录，不需要点击确认。这个账号里的通行密钥对所有使用它的 Profile 可见，但自动登录只使用本 Profile 注册或用过的那个；需要彻底分开的 Profile，在它的「Passkey Box 身份」里单独设置账号。",
                       width: 440) {
            EditorInput("服务器地址", placeholder: PasskeyBoxAccount.defaultServerURL,
                        value: $account.serverURL, identifier: "passkey-box-server")
            EditorInput("用户名", placeholder: "Passkey Box 用户名",
                        value: $account.username, identifier: "passkey-box-username")
            EditorInput("密码", placeholder: "Passkey Box 密码",
                        value: $account.password, identifier: "passkey-box-password", secure: true)
            if let error {
                ErrorLabel(error)
            }
            HStack(spacing: 10) {
                if workbench.passkeyBoxAccount != nil {
                    Button("移除账号", role: .destructive) {
                        error = workbench.clearPasskeyBox()
                        if error == nil { dismiss() }
                    }
                    .buttonStyle(WorkbenchButtonStyle(.quiet))
                    .disabled(saving != nil)
                    .accessibilityIdentifier("passkey-box-remove")
                }
                Spacer()
                Button("取消") { cancel() }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("passkey-box-cancel")
                Button(saving == nil ? "验证并保存" : "正在验证…") { save() }
                    .buttonStyle(WorkbenchButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving != nil)
                    .accessibilityIdentifier("passkey-box-save")
            }
        }
        // Closed some other way while verifying: the account must not be saved behind the user's back.
        .onDisappear { saving?.cancel() }
    }

    private func save() {
        error = nil
        let candidate = account
        saving = Task { @MainActor in
            let failure = await workbench.savePasskeyBox(candidate)
            guard !Task.isCancelled else { return }
            saving = nil
            error = failure
            if failure == nil { dismiss() }
        }
    }

    private func cancel() {
        saving?.cancel()
        saving = nil
        dismiss()
    }
}
