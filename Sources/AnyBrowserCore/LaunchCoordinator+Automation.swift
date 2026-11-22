import Combine
import Foundation

/// The local automation API's settings and the server that answers it.
@MainActor
public final class AutomationHost: ObservableObject {
    public enum Status: Equatable, Sendable {
        case stopped, starting
        case listening(Int)
        case failed(String)
    }

    @Published public private(set) var configuration: AutomationConfiguration?
    @Published public private(set) var status: Status = .stopped
    private let store: ProfileStore
    weak var backend: AutomationBackend?
    private var server: AutomationServer?
    /// Bumped on every change so an outdated start or failure cannot overwrite a newer state.
    private var generation = 0

    init(store: ProfileStore) {
        self.store = store
    }

    /// Reads the saved settings and starts listening when they say so.
    public func load() async {
        do {
            let configuration = try store.automationConfiguration()
            self.configuration = configuration
            if configuration.enabled { await run(configuration) }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Saves the settings and restarts or stops the server to match. Returns an error message
    /// when the settings cannot be saved; a server that fails to listen shows up in `status`.
    public func save(_ draft: AutomationConfiguration) async -> String? {
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
    public func regenerateToken() async -> String? {
        guard var value = configuration else { return "自动化接口的设置尚未读取。" }
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
        guard let backend else {
            status = .failed("AnyBrowser 正在退出。")
            return
        }
        let server = AutomationServer(port: configuration.port, token: configuration.token, backend: backend) {
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
}
