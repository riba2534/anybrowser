import AnyBrowserCore
import AppKit
import Combine
import SwiftUI

/// The local automation API's lifecycle and settings.
@MainActor
final class AutomationController: ObservableObject, AutomationBackend {
    enum Status: Equatable {
        case stopped, starting
        case listening(Int)
        case failed(String)
    }

    @Published private(set) var configuration: AutomationConfiguration?
    @Published private(set) var status: Status = .stopped
    private weak var workbench: Workbench?
    private var server: AutomationServer?
    /// Bumped on every change so an outdated start or failure cannot overwrite a newer state.
    private var generation = 0

    func attach(to workbench: Workbench) {
        self.workbench = workbench
        guard let store = workbench.store else { return }
        do {
            let configuration = try store.automationConfiguration()
            self.configuration = configuration
            if configuration.enabled {
                Task { await run(configuration) }
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Saves the settings and restarts or stops the server to match. Returns an error message
    /// when the settings cannot be saved; a server that fails to listen shows up in `status`.
    func save(_ draft: AutomationConfiguration) async -> String? {
        guard let store = workbench?.store else { return Workbench.storeUnavailable }
        let value: AutomationConfiguration
        do {
            value = try draft.validated()
            try store.saveAutomationConfiguration(value)
        } catch {
            return error.localizedDescription
        }
        configuration = value
        await run(value)
        return nil
    }

    /// Replaces the token right away; the old token stops working immediately.
    func regenerateToken() async -> String? {
        guard var value = configuration else { return Workbench.storeUnavailable }
        do {
            value.token = try AutomationConfiguration.newToken()
        } catch {
            return error.localizedDescription
        }
        return await save(value)
    }

    private func run(_ configuration: AutomationConfiguration) async {
        generation += 1
        let current = generation
        if let server, configuration.enabled, status == .listening(configuration.port) {
            server.update(token: configuration.token)
            return
        }
        let previous = server
        server = nil
        await previous?.stop()
        guard current == generation else { return }
        guard configuration.enabled else {
            status = .stopped
            return
        }
        let server = AutomationServer(port: configuration.port, token: configuration.token, backend: self) {
            [weak self] message in
            guard let self, self.generation == current else { return }
            self.server = nil
            self.status = .failed(message)
        }
        self.server = server
        status = .starting
        do {
            let port = try await server.start()
            guard current == generation else { return }
            status = .listening(port)
        } catch {
            guard current == generation else { return }
            self.server = nil
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: AutomationBackend

    var profiles: [BrowserProfile] { workbench?.profiles ?? [] }

    func state(for id: UUID) -> BrowserRunState { workbench?.state(for: id) ?? .stopped }

    func isBusy(_ id: UUID) -> Bool { workbench?.isBusy(id) ?? false }

    func start(_ profile: BrowserProfile) async throws {
        guard let workbench else { throw ProfileError.invalid("AnyBrowser 正在退出。") }
        try await workbench.start(profile)
    }

    func stop(_ id: UUID) async throws {
        guard let workbench else { throw ProfileError.invalid("AnyBrowser 正在退出。") }
        try await workbench.stopProfile(id)
    }

    func devToolsEndpoint(for id: UUID) async -> URL? {
        await workbench?.runtime?.devToolsEndpoint(for: id)
    }
}

/// Settings for the local automation API.
struct AutomationSettings: View {
    @ObservedObject var workbench: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var portText: String
    @State private var revealed = false
    @State private var confirmingRegeneration = false
    @State private var copied: String?
    @State private var error: String?
    @State private var saving = false

    init(workbench: Workbench) {
        self.workbench = workbench
        let saved = workbench.automation.configuration
        _enabled = State(initialValue: saved?.enabled ?? false)
        _portText = State(initialValue: String(saved?.port ?? AutomationConfiguration.defaultPort))
    }

    private var automation: AutomationController { workbench.automation }

    var body: some View {
        WorkbenchSheet(title: "自动化接口",
                       caption: "本机脚本可以通过 HTTP 接口列出、启动和停止 Profile，并拿到 CDP 调试地址。接口只监听 127.0.0.1，请求必须带访问令牌，网页发起的请求一律拒绝。",
                       width: 500) {
            Toggle("启用自动化接口", isOn: $enabled)
                .toggleStyle(.switch)
                .font(.system(size: 13, weight: .medium))
                .accessibilityIdentifier("automation-enabled")
            EditorInput("端口", placeholder: String(AutomationConfiguration.defaultPort), value: $portText,
                        identifier: "automation-port", numeric: true)
            if let token = automation.configuration?.token {
                tokenRow(token)
            }
            statusRow
            if let configuration = automation.configuration {
                example(configuration)
            }
            if let error {
                ErrorLabel(error)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "正在保存…" : "保存") { save() }
                    .buttonStyle(WorkbenchButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || automation.configuration == nil)
                    .accessibilityIdentifier("automation-save")
            }
        }
        .alert("重新生成访问令牌？", isPresented: $confirmingRegeneration) {
            Button("重新生成", role: .destructive) { regenerate() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("旧令牌立即失效，正在使用它的脚本需要换成新令牌。")
        }
    }

    private func tokenRow(_ token: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("访问令牌")
                .font(.system(size: 12, weight: .medium))
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                Text(revealed ? token : String(repeating: "•", count: 32))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .fieldSurface()
                    .accessibilityLabel("访问令牌")
                    .accessibilityIdentifier("automation-token")
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(WorkbenchButtonStyle(.quiet))
                .help(revealed ? "隐藏令牌" : "显示令牌")
                .accessibilityLabel(revealed ? "隐藏令牌" : "显示令牌")
                .accessibilityIdentifier("automation-reveal")
                Button(copied == "token" ? "已复制" : "复制") { copy(token, as: "token") }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .accessibilityIdentifier("automation-copy-token")
                Button("重新生成") { confirmingRegeneration = true }
                    .buttonStyle(WorkbenchButtonStyle(.neutral))
                    .disabled(saving)
                    .accessibilityIdentifier("automation-regenerate")
            }
        }
    }

    private var statusRow: some View {
        let (text, color): (String, Color) = {
            switch automation.status {
            case .stopped: return ("已停止", WorkbenchPalette.muted.opacity(0.65))
            case .starting: return ("正在启动…", WorkbenchPalette.amber)
            case .listening(let port): return ("监听中 · 127.0.0.1:\(port)", WorkbenchPalette.green)
            case .failed(let message): return ("启动失败：\(message)", WorkbenchPalette.danger)
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("automation-status")
    }

    private func example(_ configuration: AutomationConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("示例")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(copied == "example" ? "已复制" : "复制示例") {
                    copy(exampleText(configuration, token: configuration.token), as: "example")
                }
                .buttonStyle(WorkbenchButtonStyle(.quiet))
                .accessibilityIdentifier("automation-copy-example")
            }
            Text(exampleText(configuration, token: revealed ? configuration.token : "<访问令牌>"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(WorkbenchPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkbenchPalette.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityIdentifier("automation-example")
        }
    }

    /// Uses the saved settings, which are the ones the running server answers to.
    private func exampleText(_ configuration: AutomationConfiguration, token: String) -> String {
        let base = "http://127.0.0.1:\(configuration.port)/api/v1/profiles"
        let id = workbench.saved?.id.uuidString ?? workbench.profiles.first?.id.uuidString ?? "<Profile ID>"
        return """
            curl -H "Authorization: Bearer \(token)" \(base)
            curl -X POST -H "Authorization: Bearer \(token)" \(base)/\(id)/start
            """
    }

    private func copy(_ text: String, as item: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Asks clipboard history tools not to keep the token.
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        guard pasteboard.setString(text, forType: .string) else { return }
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        copied = item
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copied == item { copied = nil }
        }
    }

    private func save() {
        guard let saved = automation.configuration else { return }
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)) else {
            error = "自动化接口端口须为 1024–65535。"
            return
        }
        saving = true
        error = nil
        Task {
            error = await automation.save(AutomationConfiguration(enabled: enabled, port: port, token: saved.token))
            saving = false
        }
    }

    private func regenerate() {
        saving = true
        error = nil
        Task {
            error = await automation.regenerateToken()
            saving = false
        }
    }
}
