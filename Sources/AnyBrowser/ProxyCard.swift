import AnyBrowserCore
import SwiftUI

/// The Profile's proxy address.
struct ProxyCard: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench

    var body: some View {
        WorkbenchCard {
            CardHeading(title: "代理", icon: "network")
            EditorInput("代理地址", placeholder: "留空使用系统网络设置",
                        value: $draft.profile.proxy, identifier: "profile-proxy")
            Text("主机:端口默认为 HTTP，也可指定 HTTPS 或 SOCKS5。保存并重启后生效。")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
        }
    }
}
