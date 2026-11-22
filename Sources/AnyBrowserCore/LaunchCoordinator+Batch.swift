import Foundation

/// How far a batch action has come, for a progress bar and its Cancel button.
public struct BatchProgress: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case start, stop
    }

    public var action: Action
    /// Profiles done, skipped or cancelled so far.
    public var completed: Int
    public var total: Int
    /// False once cancelled: Profiles already starting or stopping finish, the rest are skipped.
    public var canCancel: Bool
}

/// The outcome of a batch action. Cancelled Profiles are counted apart from skipped ones.
public struct BatchReport: Equatable, Sendable {
    public var outcome = ProfileLibrary.BatchOutcome()
    public var cancelled = 0

    public init() {}

    /// One notice for the whole batch, e.g. "已启动 2 个 Profile，跳过 1 个。已取消其余 3 个。"
    public func summary(verb: String) -> String {
        outcome.summary(verb: verb) + (cancelled > 0 ? "已取消其余 \(cancelled) 个。" : "")
    }
}

extension LaunchCoordinator {
    /// Starts the Profiles that are neither running nor busy, `maximumConcurrentLaunches` at a time,
    /// checking each proxy once for the whole batch. Each Profile is looked up again right before
    /// its turn. A changed fingerprint only adds a warning, as on the API.
    public func startBatch(_ ids: [UUID]) async throws -> BatchReport {
        let preflight = PreflightCache()
        return try await runBatch(.start, ids, applies: { !self.state(for: $0.id).isRunning && !self.isBusy($0.id) }) { profile in
            try await self.launch(profile.id, restarting: false, overrides: LaunchOverrides(), fingerprintChange: .warn,
                                  preflight: preflight).warnings
        }
    }

    /// Stops the running Profiles that are not busy, `maximumConcurrentLaunches` at a time.
    public func stopBatch(_ ids: [UUID]) async throws -> BatchReport {
        try await runBatch(.stop, ids, applies: { self.state(for: $0.id).isRunning && !self.isBusy($0.id) }) { profile in
            try await self.stop(profile.id)
            return []
        }
    }

    /// Lets the Profiles already starting or stopping finish and skips the rest.
    public func cancelBatch() {
        batch?.canCancel = false
    }

    private func runBatch(_ action: BatchProgress.Action, _ ids: [UUID], applies: @escaping (BrowserProfile) -> Bool,
                          perform: @escaping (BrowserProfile) async throws -> [String]) async throws -> BatchReport {
        guard batch == nil else { throw ProfileError.invalid("另一个批量操作正在进行，请等它完成或取消。") }
        guard archiving.isEmpty, restoreBaseline == nil else {
            throw ProfileError.invalid("完整备份或恢复正在进行，请等它完成。")
        }
        var seen: Set<UUID> = []
        let ids = ids.filter { seen.insert($0).inserted }
        batch = BatchProgress(action: action, completed: 0, total: ids.count, canCancel: true)
        defer { batch = nil }
        let run = BatchRun(ids)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(max(1, maximumConcurrentLaunches), ids.count) {
                group.addTask { @MainActor in
                    while let (position, id) = run.next() {
                        await self.runItem(id, at: position, in: run, applies: applies, perform: perform)
                        self.batch?.completed += 1
                    }
                }
            }
        }
        return run.report()
    }

    private func runItem(_ id: UUID, at position: Int, in run: BatchRun, applies: (BrowserProfile) -> Bool,
                         perform: (BrowserProfile) async throws -> [String]) async {
        guard batch?.canCancel != false else {
            run.cancelled += 1
            return
        }
        guard let profile = profile(id), applies(profile) else {
            run.outcome.skipped += 1
            return
        }
        do {
            for warning in try await perform(profile) { run.warn(warning, for: profile.name, at: position) }
            run.outcome.succeeded += 1
        } catch {
            run.outcome.failures.append("\(profile.name)：\(error.localizedDescription)")
        }
    }
}

/// The shared state of one batch's workers.
@MainActor
private final class BatchRun {
    private let ids: [UUID]
    private var position = 0
    var outcome = ProfileLibrary.BatchOutcome()
    var cancelled = 0
    /// Each warning once, with the Profiles it concerns and their places in the batch: a proxy
    /// that is down is reported once for all of the Profiles that use it.
    private var warnings: [(text: String, names: [(position: Int, name: String)])] = []

    init(_ ids: [UUID]) {
        self.ids = ids
    }

    func next() -> (position: Int, id: UUID)? {
        guard position < ids.count else { return nil }
        defer { position += 1 }
        return (position, ids[position])
    }

    func warn(_ text: String, for name: String, at position: Int) {
        if let index = warnings.firstIndex(where: { $0.text == text }) {
            warnings[index].names.append((position, name))
        } else {
            warnings.append((text, [(position, name)]))
        }
    }

    func report() -> BatchReport {
        var report = BatchReport()
        report.outcome = outcome
        // Launches finish in any order; the names follow the batch's.
        report.outcome.warnings = warnings.map { warning in
            let names = warning.names.sorted { $0.position < $1.position }.map(\.name)
            return "\(names.joined(separator: "、"))：\(warning.text)"
        }
        report.cancelled = cancelled
        return report
    }
}
