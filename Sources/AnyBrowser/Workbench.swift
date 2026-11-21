import AnyBrowserCore
import AppKit
import Combine
import SwiftUI

@MainActor
final class Workbench: ObservableObject {
    enum Destination {
        case new, profile(UUID)
        /// A copy of the selected Profile as saved.
        case clone
    }

    struct Notice {
        var text: String
        var isError = false
    }

    let store: ProfileStore?
    let runtime: BrowserRuntime?
    let engineVersion: String?
    let engineError: String?
    @Published var draft: ProfileDraft?
    @Published var notice: Notice?
    @Published var pendingDestination: Destination?
    @Published var showingPasskeyBox = false
    @Published var showingAutomation = false
    @Published var showingBatchCreate = false
    let proxyCenter = ProxyCenter()
    let library = LibraryModel()
    let automation = AutomationController()
    @Published private(set) var launches: Set<UUID> = []
    private var runningConfigurations: [UUID: BrowserProfile] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        let openedStore: ProfileStore?
        var storageError: String?
        do {
            openedStore = try ProfileStore(directory: ProfileStore.defaultDirectory())
        } catch {
            openedStore = nil
            storageError = error.localizedDescription
        }

        let engineResult = Result { try BrowserEngine.bundled() }
        let engine = try? engineResult.get()
        store = openedStore
        if let engine, let openedStore {
            runtime = BrowserRuntime(engine: engine, storage: openedStore.directory)
        } else {
            runtime = nil
        }
        engineVersion = engine?.version
        if case .failure(let error) = engineResult {
            engineError = error.localizedDescription
        } else {
            engineError = nil
        }

        draft = openedStore?.profiles.first.map(ProfileDraft.init)
        if let storageError {
            notice = Notice(text: storageError, isError: true)
        } else if let count = openedStore?.unreadableProfiles, count > 0 {
            notice = Notice(text: "有 \(count) 份 Profile 配置无法读取，已跳过。", isError: true)
        }

        openedStore?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        runtime?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        for model in [proxyCenter.objectWillChange, library.objectWillChange, automation.objectWillChange] {
            model.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        automation.attach(to: self)
    }

    static let storeUnavailable = "本机 Profile 数据库不可用。"

    var profiles: [BrowserProfile] { store?.profiles ?? [] }
    var selectedID: UUID? { draft?.profile.id }
    var saved: BrowserProfile? { profiles.first { $0.id == selectedID } }

    var hasChanges: Bool {
        guard let draft else { return false }
        return saved.map(ProfileDraft.init) != draft
    }

    func state(for id: UUID) -> BrowserRunState {
        runtime?.status(for: id) ?? .stopped
    }

    func isBusy(_ id: UUID) -> Bool {
        launches.contains(id) || library.removing.contains(id) || state(for: id) == .starting || state(for: id) == .stopping
    }

    func hasPendingRestart(_ id: UUID) -> Bool {
        guard case .running(_, let port, _) = state(for: id),
              let stored = profiles.first(where: { $0.id == id }) else { return false }
        if stored.port != port { return true }
        if let running = runningConfigurations[id] {
            return running.fingerprint != stored.fingerprint || running.proxy != stored.proxy
                || running.launch != stored.launch
                || running.passkeyBox != (stored.passkeyBox ?? store?.passkeyBoxAccount)
        }
        return runtime?.matchesRunningConfiguration(stored) != true
    }

    func refresh() async {
        await runtime?.refresh(profiles)
    }

    func request(_ destination: Destination) {
        if case .profile(let id) = destination, id == selectedID { return }
        if hasChanges {
            pendingDestination = destination
        } else {
            navigate(destination)
        }
    }

    func resolveNavigation(_ destination: Destination, saveChanges: Bool) {
        pendingDestination = nil
        if saveChanges, !save() { return }
        navigate(destination)
    }

    @discardableResult
    func save() -> Bool {
        guard let draft, let store else { return false }
        do {
            let value = try draft.validated()
            try store.save(value)
            self.draft = ProfileDraft(store.profiles.first(where: { $0.id == value.id }) ?? value)
            notice = Notice(text: hasPendingRestart(value.id) ? "配置已保存，重启后应用。" : "配置已保存。")
            return true
        } catch {
            show(error)
            return false
        }
    }

    func remove(_ id: UUID) {
        guard let store, !isBusy(id), !state(for: id).isRunning else { return }
        do {
            try store.remove(id)
            runningConfigurations[id] = nil
            if selectedID == id { draft = store.profiles.first.map(ProfileDraft.init) }
            notice = Notice(text: "已移除 Profile。")
        } catch {
            show(error)
        }
    }

    func randomize(_ fields: Set<FingerprintField>) -> Bool {
        guard var draft, let store else { return false }
        do {
            var profile = draft.profile
            if let seed = Int(draft.seedText.trimmingCharacters(in: .whitespaces)) {
                profile.fingerprint.seed = seed
            }
            profile.fingerprint = try store.randomize(profile, fields: fields).fingerprint
            draft.profile = profile
            if fields.contains(.seed) { draft.seedText = String(profile.fingerprint.seed) }
            if fields.contains(.cpuCount) {
                draft.cpuText = profile.fingerprint.cpuCount.map(String.init) ?? ""
            }
            self.draft = draft
            notice = Notice(text: "已生成预览，保存后应用。")
            return true
        } catch {
            show(error)
            return false
        }
    }

    func launch(restart: Bool = false) async {
        guard runtime != nil, let id = selectedID, !isBusy(id) else { return }
        if hasChanges, !save() { return }
        guard let profile = saved else { return }
        notice = nil
        do {
            try await start(profile, restart: restart)
        } catch {
            show(error)
        }
    }

    /// Starts a saved Profile; also used by batch actions and the automation API.
    /// Returns the proxy warning it showed, if any; the browser starts regardless.
    @discardableResult
    func start(_ profile: BrowserProfile, restart: Bool = false) async throws -> String? {
        guard let runtime else { throw ProfileError.invalid("内置浏览器不可用。") }
        let id = profile.id
        guard !isBusy(id) else { throw ProfileError.invalid("「\(profile.name)」正在执行另一个操作。") }
        launches.insert(id)
        defer { launches.remove(id) }
        let warning = await ProxyProbe.preflight(profile.proxy)
        if restart {
            try await runtime.stop(id)
            runningConfigurations[id] = nil
        }
        var launched = profile
        launched.passkeyBox = profile.passkeyBox ?? store?.passkeyBoxAccount
        // A browser that was already running keeps whatever configuration it was started with.
        guard try await runtime.start(profile, passkeyBox: launched.passkeyBox) else { return warning }
        runningConfigurations[id] = launched
        store?.recordLaunch(id)
        if let warning { notice = Notice(text: warning, isError: true) }
        return warning
    }

    func stop(_ id: UUID) async {
        guard runtime != nil, !isBusy(id) else { return }
        notice = nil
        do {
            try await stopProfile(id)
        } catch {
            show(error)
        }
    }

    /// Stops a Profile's browser; also used by batch actions and the automation API.
    func stopProfile(_ id: UUID) async throws {
        guard let runtime else { throw ProfileError.invalid("内置浏览器不可用。") }
        guard !isBusy(id) else { throw ProfileError.invalid("该 Profile 正在执行另一个操作。") }
        launches.insert(id)
        defer { launches.remove(id) }
        try await runtime.stop(id)
        runningConfigurations[id] = nil
    }

    var passkeyBoxAccount: PasskeyBoxAccount? { store?.passkeyBoxAccount }

    /// Verifies the account with the server, then saves it. Returns an error message on failure.
    func savePasskeyBox(_ account: PasskeyBoxAccount) async -> String? {
        guard let store else { return Self.storeUnavailable }
        do {
            let value = try account.validated()
            try await value.verify()
            try store.savePasskeyBoxAccount(value)
            notice = Notice(text: profiles.contains { state(for: $0.id).isRunning }
                ? "Passkey Box 账号已保存，正在运行的 Profile 重启后生效。"
                : "Passkey Box 账号已保存，启动 Profile 后自动登录。")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func clearPasskeyBox() -> String? {
        do {
            try store?.savePasskeyBoxAccount(nil)
            notice = Notice(text: "已移除 Passkey Box 账号。之后新建的 Profile 不再自动登录；已登录过的 Profile 仍保留扩展里的账号，需要时在扩展里退出。")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func copyAddress(_ port: Int) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString("http://127.0.0.1:\(port)", forType: .string) {
            notice = Notice(text: "调试地址已复制。")
        }
    }

    private func navigate(_ destination: Destination) {
        notice = nil
        do {
            switch destination {
            case .new:
                draft = try store.map { try ProfileDraft($0.makeDraft()) }
            case .profile(let id):
                draft = profiles.first { $0.id == id }.map(ProfileDraft.init)
            case .clone:
                cloneSaved()
            }
        } catch {
            show(error)
        }
    }

    func show(_ error: Error) {
        notice = Notice(text: error.localizedDescription, isError: true)
    }
}

extension BrowserRunState {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
