import AnyBrowserCore
import SwiftUI

/// The Profile's proxy address and where its traffic leaves for the internet.
struct ProxyCard: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench

    private var center: ProxyCenter { workbench.proxyCenter }
    private var check: ProxyCenter.Check? { center.check(for: draft.profile.id, proxy: draft.profile.proxy) }

    var body: some View {
        WorkbenchCard {
            CardHeading(title: "代理", icon: "network")
            EditorInput("代理地址", placeholder: "留空使用系统网络设置",
                        value: $draft.profile.proxy, identifier: "profile-proxy")
            Text("主机:端口默认为 HTTP，也可指定 HTTPS 或 SOCKS5。HTTP 和 HTTPS 代理可带账号密码，写成 http://用户名:密码@主机:端口；SOCKS5 不支持账号密码。保存并重启后生效。")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    Task { await center.check(draft.profile) }
                } label: {
                    Label("检测", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(WorkbenchButtonStyle(.neutral))
                .accessibilityIdentifier("check-proxy")
                .help("通过当前填写的代理查询出口 IP")
                Button {
                    Task { await fillFromExit() }
                } label: {
                    Label("按出口 IP 填写时区和语言", systemImage: "globe")
                }
                .buttonStyle(WorkbenchButtonStyle(.quiet))
                .accessibilityIdentifier("fill-from-exit")
                Spacer(minLength: 0)
            }
            .disabled(check == .checking)
            result
        }
        .onChange(of: draft.profile.proxy) { center.proxyChanged(draft.profile.id, to: $0) }
    }

    @ViewBuilder private var result: some View {
        switch check {
        case .checking?:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在查询出口 IP…")
            }
            .font(.system(size: 12))
            .foregroundColor(WorkbenchPalette.muted)
        case .succeeded(let exit)?:
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "出口 IP \(exit.ip)")
                    .font(.system(size: 12, weight: .semibold))
                if !summary(exit).isEmpty {
                    Text(summary(exit))
                        .font(.system(size: 12))
                        .foregroundColor(WorkbenchPalette.muted)
                }
            }
            .textSelection(.enabled)
            .accessibilityIdentifier("proxy-exit")
        case .failed(let message)?:
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.danger)
                .textSelection(.enabled)
                .accessibilityIdentifier("proxy-exit-error")
        case nil:
            EmptyView()
        }
    }

    private func summary(_ exit: ProxyExit) -> String {
        let country = exit.countryCode.isEmpty ? ""
            : Locale(identifier: "zh_CN").localizedString(forRegionCode: exit.countryCode) ?? exit.countryCode
        var places: [String] = []
        for place in [exit.city, exit.region, country] where !place.isEmpty && !places.contains(place) {
            places.append(place)
        }
        var parts = places.isEmpty ? [] : [places.joined(separator: "，")]
        if !exit.timeZone.isEmpty { parts.append("时区 \(exit.timeZone)") }
        if let language = exit.languages.first { parts.append("语言 \(language)") }
        return parts.joined(separator: " · ")
    }

    /// Uses the shown exit, or looks it up first.
    private func fillFromExit() async {
        let profile = draft.profile
        let found: ProxyExit?
        if case .succeeded(let exit) = check {
            found = exit
        } else {
            found = await center.check(profile)
        }
        // A failed lookup is shown under the buttons; the editor may also have moved on meanwhile.
        guard let exit = found, draft.profile.id == profile.id, draft.profile.proxy == profile.proxy else { return }
        guard !exit.timeZone.isEmpty || !exit.languages.isEmpty else {
            workbench.notice = .init(text: "出口信息里没有时区和语言，请手动填写。", isError: true)
            return
        }
        exit.apply(to: &draft.profile.fingerprint)
        workbench.notice = .init(text: "已按出口 IP 填写时区和语言，保存后生效。")
    }
}
