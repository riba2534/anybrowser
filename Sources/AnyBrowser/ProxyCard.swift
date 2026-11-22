import AnyBrowserCore
import SwiftUI

/// The Profile's proxy address and where its traffic leaves for the internet.
struct ProxyCard: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench

    private var center: ProxyCenter { workbench.proxyCenter }
    private var check: ProxyCenter.Check? { center.check(for: draft.profile.id, proxy: draft.profile.proxy) }
    private var proxyLibrary: ProxyLibrary? { workbench.coordinator?.proxyLibrary }

    var body: some View {
        WorkbenchCard {
            CardHeading(title: "代理", icon: "network")
            EditorInput("代理地址", placeholder: "留空使用系统网络设置",
                        value: $draft.profile.proxy, identifier: "profile-proxy")
            Text("主机:端口默认为 HTTP，也可指定 HTTPS 或 SOCKS5。三种代理都可以带账号密码，写成 socks5://用户名:密码@主机:端口，或代理商常用的 主机:端口:用户名:密码。带账号密码的代理经本机中继连接，普通窗口、无痕窗口和自动化新建的上下文都经过它。保存并重启后生效。")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    Task { await checkAndRecord(draft.profile) }
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
                libraryMenu
            }
            .disabled(check == .checking)
            result
            sharedExit
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
            if let record = recordedExit {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "最近出口 IP \(record.exit.ip)")
                        .font(.system(size: 12, weight: .semibold))
                    Text(([summary(record.exit)].filter { !$0.isEmpty } + ["检测于 \(Self.when(record.checkedAt))"])
                        .joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundColor(WorkbenchPalette.muted)
                }
                .textSelection(.enabled)
                .accessibilityIdentifier("proxy-last-exit")
            }
        }
    }

    /// The exit recorded for the saved Profile, by a launch or an earlier check, while the draft
    /// keeps the saved proxy.
    private var recordedExit: (exit: ProxyExit, checkedAt: Date)? {
        guard let saved = workbench.saved, Workbench.sameProxy(saved.proxy, draft.profile.proxy) else { return nil }
        return workbench.coordinator?.lastExit(for: draft.profile.id)
    }

    @ViewBuilder private var sharedExit: some View {
        let names = workbench.consistencyContext(for: draft.profile.id).profilesSharingExit
        if !names.isEmpty, workbench.saved.map({ Workbench.sameProxy($0.proxy, draft.profile.proxy) }) == true {
            let listed = names.prefix(3).map { "「\($0)」" }.joined(separator: "、")
            Label("与 \(listed)\(names.count > 3 ? " 等 \(names.count) 个 Profile" : "")使用同一个出口 IP，网站可以据此把它们关联起来。",
                  systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundColor(WorkbenchPalette.amber)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("proxy-shared-exit")
        }
    }

    /// Proxies from the library; picking one fills in its address.
    @ViewBuilder private var libraryMenu: some View {
        let entries = proxyLibrary?.entries ?? []
        Menu {
            ForEach(entries) { entry in
                Button(Self.title(entry)) { draft.profile.proxy = entry.url }
            }
        } label: {
            Label("从代理库选择", systemImage: "list.bullet.rectangle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(entries.isEmpty)
        .help(entries.isEmpty ? "代理库是空的" : "用代理库里的代理")
        .accessibilityIdentifier("proxy-from-library")
    }

    /// The entry's name and server, never its credentials, with the exit it was last seen at.
    private static func title(_ entry: ProxyEntry) -> String {
        let server = entry.endpoint.map { "\($0.host):\($0.port)" } ?? ""
        var title = entry.label.isEmpty ? server : "\(entry.label)（\(server)）"
        if let exit = entry.lastExit {
            title += " · " + ([exit.countryCode, exit.ip].filter { !$0.isEmpty }.joined(separator: " "))
        }
        return title
    }

    private static func when(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
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

    /// Looks up the exit; one found through the saved proxy is recorded for the Profile, as a
    /// launch would, so it shows after AnyBrowser restarts and counts for shared exits.
    @discardableResult
    private func checkAndRecord(_ profile: BrowserProfile) async -> ProxyExit? {
        let exit = await center.check(profile)
        if let exit, let saved = workbench.profiles.first(where: { $0.id == profile.id }),
           Workbench.sameProxy(saved.proxy, profile.proxy) {
            try? proxyLibrary?.recordExit(exit, forProfile: profile.id)
            if let entry = proxyLibrary?.entry(matching: profile.proxy) { try? proxyLibrary?.recordCheck(entry.id, exit: exit) }
        }
        return exit
    }

    /// Uses the shown exit, or looks it up first.
    private func fillFromExit() async {
        let profile = draft.profile
        let found: ProxyExit?
        if case .succeeded(let exit) = check {
            found = exit
        } else {
            found = await checkAndRecord(profile)
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
