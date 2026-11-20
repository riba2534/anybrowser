import AnyBrowserCore
import AppKit
import Combine
import SwiftUI

@main
@MainActor
struct AnyBrowserApp: App {
    @StateObject private var workbench = Workbench()

    var body: some Scene {
        WindowGroup("AnyBrowser") {
            Workspace(workbench: workbench)
                .frame(minWidth: 880, idealWidth: 1080, minHeight: 620, idealHeight: 756)
                .task {
                    while !Task.isCancelled {
                        await workbench.refresh()
                        do {
                            try await Task.sleep(nanoseconds: 3_000_000_000)
                        } catch {
                            break
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建 Profile") { workbench.request(.new) }
                    .keyboardShortcut("n")
                    .disabled(workbench.store == nil)
            }
            CommandGroup(after: .newItem) {
                Button("保存 Profile") { workbench.save() }
                    .keyboardShortcut("s")
                    .disabled(!workbench.hasChanges)
            }
        }
    }
}

struct ProfileDraft: Equatable {
    var profile: BrowserProfile
    var portText: String
    var seedText: String
    var cpuText: String

    init(_ profile: BrowserProfile) {
        self.profile = profile
        portText = String(profile.port)
        seedText = String(profile.fingerprint.seed)
        cpuText = profile.fingerprint.cpuCount.map(String.init) ?? ""
    }

    func validated() throws -> BrowserProfile {
        var value = profile
        value.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fingerprint.platformVersion = value.fingerprint.platformVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fingerprint.brandVersion = value.fingerprint.brandVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fingerprint.language = value.fingerprint.language.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fingerprint.timeZone = value.fingerprint.timeZone.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.name.isEmpty else { throw DraftError("请输入 Profile 名称。") }
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(port) else {
            throw DraftError("调试端口必须为 1024–65535 之间的整数。")
        }
        guard let seed = Int(seedText.trimmingCharacters(in: .whitespaces)), (1...Int(Int32.max)).contains(seed) else {
            throw DraftError("指纹种子必须为 1–2147483647 之间的整数。")
        }
        value.port = port
        value.fingerprint.seed = seed
        let cpu = cpuText.trimmingCharacters(in: .whitespaces)
        if cpu.isEmpty {
            value.fingerprint.cpuCount = nil
        } else {
            guard let count = Int(cpu), (1...256).contains(count) else {
                throw DraftError("逻辑 CPU 数必须为 1–256 之间的整数。")
            }
            value.fingerprint.cpuCount = count
        }
        return value
    }
}

private struct DraftError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

@MainActor
final class Workbench: ObservableObject {
    enum Destination {
        case new, profile(UUID)
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
        }

        openedStore?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        runtime?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }

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
        launches.contains(id) || state(for: id) == .starting || state(for: id) == .stopping
    }

    func hasPendingRestart(_ id: UUID) -> Bool {
        guard case .running(_, let port, _) = state(for: id),
              let stored = profiles.first(where: { $0.id == id }) else { return false }
        if stored.port != port { return true }
        if let running = runningConfigurations[id] {
            return running.fingerprint != stored.fingerprint
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
        guard let runtime, let id = selectedID, !isBusy(id) else { return }
        if hasChanges, !save() { return }
        guard let profile = saved else { return }
        launches.insert(id)
        defer { launches.remove(id) }
        notice = nil
        do {
            if restart {
                try await runtime.stop(id)
                runningConfigurations[id] = nil
            }
            try await runtime.start(profile)
            runningConfigurations[id] = profile
        } catch {
            show(error)
        }
    }

    func stop(_ id: UUID) async {
        guard let runtime, !isBusy(id) else { return }
        launches.insert(id)
        defer { launches.remove(id) }
        notice = nil
        do {
            try await runtime.stop(id)
            runningConfigurations[id] = nil
        } catch {
            show(error)
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
            }
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        notice = Notice(text: error.localizedDescription, isError: true)
    }
}

extension BrowserRunState {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
