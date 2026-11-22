import AnyBrowserCore
import SwiftUI

/// Where Profiles created or edited together get their proxies.
struct ProxySource: Equatable {
    enum Kind: Hashable {
        case single
        case library(ProxyAssignment.Order)
    }

    var kind: Kind = .single
    var address = BrowserProfile.defaultProxy
    /// Library entries with this tag only; empty for the whole library.
    var tag = ""

    static let choices: [(value: Kind, title: String)] = [
        (.single, "单个地址"),
        (.library(.sequential), ProxyAssignment.Order.sequential.title),
        (.library(.randomUnique), ProxyAssignment.Order.randomUnique.title),
    ]
}

extension Workbench {
    /// The library entries a source with `tag` draws from, in library order.
    func proxyPool(tag: String) -> [ProxyEntry] {
        let entries = proxyLibrary?.entries ?? []
        guard !tag.isEmpty else { return entries }
        return entries.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    }

    /// The proxy for each of `count` Profiles. Profiles in `replacing` are getting new proxies, so
    /// the ones they use now count as free.
    func plannedProxies(_ count: Int, from source: ProxySource, replacing ids: Set<UUID> = []) throws -> [String] {
        switch source.kind {
        case .single:
            return Array(repeating: source.address.trimmingCharacters(in: .whitespacesAndNewlines), count: count)
        case .library(let order):
            let pool = proxyPool(tag: source.tag)
            let usage = ProxyAssignment.usage(of: pool, users: proxyUsers, excluding: ids)
            return try ProxyAssignment.pick(count, from: pool, order: order, usage: usage)
        }
    }

    /// Looks up the exits of `proxies`, keeping what `previous` already found, so that a retry only
    /// asks again for the ones that failed. An exit found within the last minute is reused.
    func lookUpExits(_ proxies: [String], keeping previous: [String: ProxyAssignment.Lookup],
                     progress: (Int, Int) -> Void) async -> [String: ProxyAssignment.Lookup] {
        let missing = proxies.filter { previous[ProxyAssignment.normalized($0)]?.exit == nil }
        let found = await ProxyAssignment.lookUpExits(missing, limit: 4, lookup: { endpoint in
            try await ProxyProbe.lookupExit(through: endpoint, maxAge: 60)
        }, progress: progress)
        return previous.merging(found) { _, new in new }
    }
}

/// Picks the proxy source of a batch, and says how the library covers it.
struct ProxySourceFields: View {
    @ObservedObject var workbench: Workbench
    @Binding var source: ProxySource
    /// How many Profiles get a proxy; nil while the count is not a number.
    let count: Int?
    /// Profiles being given new proxies; their current ones count as free.
    var replacing: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: EditorInput.columns, alignment: .leading, spacing: 12) {
                EditorPicker(title: "代理来源", identifier: "proxy-source", selection: $source.kind,
                             choices: ProxySource.choices)
                if source.kind != .single {
                    EditorPicker(title: "代理库范围", identifier: "proxy-pool", selection: $source.tag,
                                 choices: [("", "全部代理")] + libraryTags.map { ($0, "标签：\($0)") })
                }
            }
            if source.kind == .single {
                EditorInput("代理地址", placeholder: "留空使用系统网络设置", value: $source.address, identifier: "batch-proxy")
            } else {
                poolSummary
            }
        }
    }

    private var libraryTags: [String] {
        LibraryIndex.tags(in: workbench.proxyLibrary?.entries.map(\.tags) ?? [])
    }

    @ViewBuilder private var poolSummary: some View {
        let pool = workbench.proxyPool(tag: source.tag)
        let usage = ProxyAssignment.usage(of: pool, users: workbench.proxyUsers, excluding: replacing)
        let free = pool.filter { (usage[$0.id] ?? 0) == 0 }.count
        VStack(alignment: .leading, spacing: 4) {
            Text(pool.isEmpty ? "代理库里没有\(source.tag.isEmpty ? "" : "带这个标签的")代理，请先在代理库添加。"
                              : "可用 \(pool.count) 条，其中 \(free) 条还没有 Profile 使用，优先分配。")
                .font(.system(size: 12))
                .foregroundColor(pool.isEmpty ? WorkbenchPalette.danger : WorkbenchPalette.muted)
            if let count, !pool.isEmpty, count > pool.count {
                if source.kind == .library(.randomUnique) {
                    Text("代理不够 \(count) 个 Profile 各用一条，请减少数量或改为按顺序分配。")
                        .font(.system(size: 12))
                        .foregroundColor(WorkbenchPalette.danger)
                } else {
                    Text("代理比 Profile 少，第 \(pool.count + 1) 个起重复使用，这些 Profile 会共用出口。")
                        .font(.system(size: 12))
                        .foregroundColor(WorkbenchPalette.amber)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("proxy-pool-summary")
    }
}

/// The proxies whose exit could not be looked up, each once with how many Profiles use it.
struct ExitFailureList: View {
    let failures: [(proxy: String, count: Int, reason: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(failures.reduce(0) { $0 + $1.count }) 个 Profile 的代理出口检测失败", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(WorkbenchPalette.amber)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(failures.indices, id: \.self) { index in
                        let failure = failures[index]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(ProxyText.masked(failure.proxy))（\(failure.count) 个 Profile）")
                                .font(.system(size: 11, design: .monospaced))
                            Text(failure.reason)
                                .font(.system(size: 11))
                                .foregroundColor(WorkbenchPalette.danger)
                        }
                        .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
        .padding(12)
        .background(WorkbenchPalette.iconSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("exit-failures")
    }

    /// The failures among `proxies` once `lookups` are in, grouped by proxy in first-use order.
    static func failures(_ proxies: [String], _ lookups: [String: ProxyAssignment.Lookup])
        -> (locales: [IdentitySampler.LocaleHint?], failures: [(proxy: String, count: Int, reason: String)]) {
        var locales: [IdentitySampler.LocaleHint?] = []
        var failures: [(proxy: String, count: Int, reason: String)] = []
        for proxy in proxies {
            let result = ProxyAssignment.locale(for: proxy, in: lookups)
            locales.append(result.hint)
            guard let reason = result.failure else { continue }
            if let index = failures.firstIndex(where: { $0.proxy == proxy }) {
                failures[index].count += 1
            } else {
                failures.append((proxy, 1, reason))
            }
        }
        return (locales, failures)
    }
}

enum ProxyText {
    /// The address with its password hidden, for lists and notices.
    static func masked(_ proxy: String) -> String {
        guard let endpoint = try? ProxyEndpoint.parse(proxy, allowingSOCKSCredentials: true) else {
            return proxy.isEmpty ? "系统网络设置" : proxy
        }
        guard let username = endpoint.username else { return endpoint.server }
        return "\(endpoint.scheme)://\(username):••••@\(endpoint.host):\(endpoint.port)"
    }
}

/// Creates several Profiles at once, each aligned with its own proxy exit.
struct BatchCreateSheet: View {
    @ObservedObject var workbench: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var countText = "5"
    @State private var prefix = "Profile"
    @State private var group = ""
    @State private var presetID: String?
    @State private var source = ProxySource()
    @State private var error: String?
    @State private var phase = Phase.form
    @State private var proxies: [String] = []
    @State private var lookups: [String: ProxyAssignment.Lookup] = [:]
    @State private var failures: [(proxy: String, count: Int, reason: String)] = []
    @State private var task: Task<Void, Never>?
    @State private var created: [BrowserProfile] = []
    @State private var unaligned = 0

    private enum Phase: Equatable {
        case form
        case looking(done: Int, total: Int)
        /// Some exits could not be looked up; the user decides.
        case review
    }

    var body: some View {
        WorkbenchSheet(title: "批量新建 Profile",
                       caption: "名称按前缀自动编号，每个 Profile 使用新的指纹种子和调试端口。新建前逐个检测代理出口，语言和时区与各自的出口对齐。",
                       width: 500) {
            Group {
                LazyVGrid(columns: EditorInput.columns, alignment: .leading, spacing: 12) {
                    EditorInput("数量", placeholder: "1–\(ProfileLibrary.maxBatch)", value: $countText,
                                identifier: "batch-count", numeric: true)
                    EditorInput("名称前缀", placeholder: "Profile", value: $prefix, identifier: "batch-prefix")
                    GroupField(text: $group, groups: workbench.profileGroups, identifier: "batch-group-field")
                    EditorPicker(title: "身份模板", identifier: "batch-identity", selection: $presetID,
                                 choices: [(nil, "保持默认")] + IdentityPreset.all.map { (Optional($0.id), $0.title) })
                }
                ProxySourceFields(workbench: workbench, source: $source, count: count)
            }
            .disabled(phase != .form)
            if case .looking(let done, let total) = phase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检测代理出口 \(done)/\(total)…")
                        .font(.system(size: 12))
                        .foregroundColor(WorkbenchPalette.muted)
                        .monospacedDigit()
                }
                .accessibilityIdentifier("batch-lookup-progress")
            }
            if phase == .review {
                ExitFailureList(failures: failures)
                Text("可以重试，或仍然新建：这些 Profile 的语言和时区为随机值，之后可在编辑器里按出口对齐。")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                ErrorLabel(error)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    task?.cancel()
                    dismiss()
                }
                .buttonStyle(WorkbenchButtonStyle(.neutral))
                .keyboardShortcut(.cancelAction)
                if phase == .review {
                    Button("重试失败的") { lookUp() }
                        .buttonStyle(WorkbenchButtonStyle(.neutral))
                        .accessibilityIdentifier("batch-retry")
                    Button("仍然新建") { save() }
                        .buttonStyle(WorkbenchButtonStyle(.primary))
                        .accessibilityIdentifier("batch-create-anyway")
                } else {
                    Button(phase == .form ? "新建" : "新建中…") { start() }
                        .buttonStyle(WorkbenchButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(phase != .form || !workbench.canWrite)
                        .accessibilityIdentifier("batch-create")
                }
            }
        }
        // Selecting a new Profile may ask about unsaved edits, which needs the sheet gone first.
        .onDisappear { workbench.showCreated(created, unaligned: unaligned) }
    }

    private var count: Int? {
        Int(countText.trimmingCharacters(in: .whitespaces))
    }

    private var request: ProfileLibrary.BatchRequest? {
        guard let count else { return nil }
        return .init(count: count, prefix: prefix, group: group, preset: IdentityPreset.all.first { $0.id == presetID })
    }

    private func start() {
        guard let count, (1...ProfileLibrary.maxBatch).contains(count) else {
            error = "数量须为 1–\(ProfileLibrary.maxBatch) 的整数。"
            return
        }
        do {
            proxies = try workbench.plannedProxies(count, from: source)
            for proxy in proxies where !proxy.isEmpty { _ = try ProxyEndpoint.parse(proxy, allowingSOCKSCredentials: true) }
        } catch {
            self.error = error.localizedDescription
            return
        }
        lookups = [:]
        lookUp()
    }

    private func lookUp() {
        error = nil
        phase = .looking(done: 0, total: 0)
        task = Task { @MainActor in
            lookups = await workbench.lookUpExits(proxies, keeping: lookups) { done, total in
                phase = .looking(done: done, total: total)
            }
            guard !Task.isCancelled else { return }
            failures = ExitFailureList.failures(proxies, lookups).failures
            if failures.isEmpty {
                save()
            } else {
                phase = .review
            }
        }
    }

    private func save() {
        guard let store = workbench.store, let request else { return }
        do {
            let locales = ExitFailureList.failures(proxies, lookups).locales
            created = try store.saveBatch(request, proxies: proxies, locales: locales)
            unaligned = locales.filter { $0 == nil }.count
            workbench.recordExits(lookups, for: created)
            dismiss()
        } catch {
            phase = .form
            self.error = error.localizedDescription
        }
    }
}

/// Gives the picked Profiles proxies from one address or the library, aligning each one's language
/// and time zone with its new exit.
struct BatchProxySheet: View {
    @ObservedObject var workbench: Workbench
    let ids: [UUID]
    @Environment(\.dismiss) private var dismiss
    @State private var source = ProxySource(kind: .library(.sequential))
    @State private var aligning = true
    @State private var error: String?
    @State private var looking: (done: Int, total: Int)?
    @State private var reviewing = false
    @State private var proxies: [String] = []
    @State private var lookups: [String: ProxyAssignment.Lookup] = [:]
    @State private var failures: [(proxy: String, count: Int, reason: String)] = []
    @State private var task: Task<Void, Never>?

    private var targets: [UUID] {
        workbench.profiles.map(\.id).filter(Set(ids).contains)
    }

    var body: some View {
        WorkbenchSheet(title: "为 \(targets.count) 个 Profile 设置代理",
                       caption: "按所选 Profile 的创建顺序分配。正在运行的 Profile 重启后使用新代理。",
                       width: 500) {
            Group {
                ProxySourceFields(workbench: workbench, source: $source, count: targets.count, replacing: Set(targets))
                Toggle("按各自的新出口对齐语言和时区", isOn: $aligning)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("batch-proxy-align")
            }
            .disabled(looking != nil || reviewing)
            if let looking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检测代理出口 \(looking.done)/\(looking.total)…")
                        .font(.system(size: 12))
                        .foregroundColor(WorkbenchPalette.muted)
                        .monospacedDigit()
                }
            }
            if reviewing {
                ExitFailureList(failures: failures)
                Text("可以重试，或仍然应用：这些 Profile 只换代理，语言和时区保持不变。")
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                ErrorLabel(error)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    task?.cancel()
                    dismiss()
                }
                .buttonStyle(WorkbenchButtonStyle(.neutral))
                .keyboardShortcut(.cancelAction)
                if reviewing {
                    Button("重试失败的") { lookUp() }
                        .buttonStyle(WorkbenchButtonStyle(.neutral))
                    Button("仍然应用") { apply() }
                        .buttonStyle(WorkbenchButtonStyle(.primary))
                        .accessibilityIdentifier("batch-proxy-anyway")
                } else {
                    Button(looking == nil ? "应用" : "检测中…") { start() }
                        .buttonStyle(WorkbenchButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(looking != nil || targets.isEmpty || !workbench.canWrite)
                        .accessibilityIdentifier("batch-proxy-apply")
                }
            }
        }
    }

    private func start() {
        do {
            proxies = try workbench.plannedProxies(targets.count, from: source, replacing: Set(targets))
            for proxy in proxies where !proxy.isEmpty { _ = try ProxyEndpoint.parse(proxy, allowingSOCKSCredentials: true) }
        } catch {
            self.error = error.localizedDescription
            return
        }
        lookups = [:]
        if aligning {
            lookUp()
        } else {
            apply()
        }
    }

    private func lookUp() {
        error = nil
        reviewing = false
        looking = (0, 0)
        task = Task { @MainActor in
            lookups = await workbench.lookUpExits(proxies, keeping: lookups) { done, total in looking = (done, total) }
            looking = nil
            guard !Task.isCancelled else { return }
            failures = ExitFailureList.failures(proxies, lookups).failures
            if failures.isEmpty {
                apply()
            } else {
                reviewing = true
            }
        }
    }

    private func apply() {
        let locales = aligning ? ExitFailureList.failures(proxies, lookups).locales : Array(repeating: nil, count: proxies.count)
        do {
            let targets = self.targets
            try workbench.assignProxies(targets, proxies: proxies, locales: locales, aligning: aligning)
            workbench.recordExits(lookups, for: workbench.profiles.filter { targets.contains($0.id) })
            dismiss()
        } catch {
            reviewing = false
            self.error = error.localizedDescription
        }
    }
}
