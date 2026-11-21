import AnyBrowserCore
import SwiftUI

/// The Passkey Box account this Profile signs in with.
struct IdentityCard: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench

    private enum Verification: Equatable {
        case checking, passed, failed(String)
    }

    @State private var verification: Verification?

    var body: some View {
        WorkbenchCard {
            CardHeading(title: "Passkey Box 身份", icon: "key")
            EditorPicker(title: "登录账号", identifier: "identity-mode", selection: ownAccount,
                         choices: [(false, "使用 AnyBrowser 账号"), (true, "此 Profile 单独使用账号")])
            if draft.profile.passkeyBox == nil {
                sharedAccount
            } else {
                ownAccountFields
            }
            Text("账号在保存并重启 Profile 后生效。")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
        }
        .onChange(of: draft.profile.passkeyBox) { _ in verification = nil }
    }

    private var ownAccount: Binding<Bool> {
        Binding {
            draft.profile.passkeyBox != nil
        } set: { own in
            guard own != (draft.profile.passkeyBox != nil) else { return }
            draft.profile.passkeyBox = own ? PasskeyBoxAccount() : nil
        }
    }

    /// Writes only while the Profile has its own account, so a field committing late cannot
    /// bring back an account the user just switched off.
    private var account: Binding<PasskeyBoxAccount> {
        Binding {
            draft.profile.passkeyBox ?? PasskeyBoxAccount()
        } set: { value in
            if draft.profile.passkeyBox != nil { draft.profile.passkeyBox = value }
        }
    }

    private var sharedAccount: some View {
        HStack(spacing: 8) {
            Text("AnyBrowser 账号")
                .font(.system(size: 12, weight: .medium))
            Text(workbench.passkeyBoxAccount?.username ?? "未设置")
                .font(.system(size: 12))
                .foregroundColor(workbench.passkeyBoxAccount == nil ? WorkbenchPalette.amber : WorkbenchPalette.muted)
                .lineLimit(1)
                .textSelection(.enabled)
                .accessibilityIdentifier("identity-shared-account")
            Spacer(minLength: 0)
            Button("修改…") { workbench.showingPasskeyBox = true }
                .buttonStyle(WorkbenchButtonStyle(.quiet))
                .accessibilityIdentifier("identity-edit-shared")
        }
    }

    private var ownAccountFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorInput("服务器地址", placeholder: PasskeyBoxAccount.defaultServerURL,
                        value: account.serverURL, identifier: "identity-server")
            LazyVGrid(columns: EditorInput.columns, alignment: .leading, spacing: 12) {
                EditorInput("用户名", placeholder: "Passkey Box 用户名",
                            value: account.username, identifier: "identity-username")
                EditorInput("密码", placeholder: "Passkey Box 密码",
                            value: account.password, identifier: "identity-password", secure: true)
            }
            HStack(spacing: 10) {
                Button(verification == .checking ? "正在验证…" : "验证账号") { verify() }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .disabled(verification == .checking)
                    .accessibilityIdentifier("identity-verify")
                verificationResult
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var verificationResult: some View {
        switch verification {
        case .passed:
            Label("账号可用", systemImage: "checkmark.circle")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.green)
        case .failed(let message):
            ErrorLabel(message)
        case .checking, nil:
            EmptyView()
        }
    }

    private func verify() {
        guard let candidate = draft.profile.passkeyBox else { return }
        verification = .checking
        Task {
            let result: Verification
            do {
                try await candidate.verify()
                result = .passed
            } catch {
                result = .failed(error.localizedDescription)
            }
            // A result for fields the user has since edited would be misleading.
            if draft.profile.passkeyBox == candidate { verification = result }
        }
    }
}
