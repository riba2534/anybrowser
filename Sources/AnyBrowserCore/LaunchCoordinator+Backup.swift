import Foundation

extension LaunchCoordinator {
    /// Writes a full backup of `ids` (see `ProfileBackup.export`). The Profiles are busy meanwhile,
    /// so nothing starts, stops or edits them while their files are copied.
    public func exportBackup(_ ids: [UUID], to destination: URL,
                             progress: @escaping (ProfileBackup.Progress) -> Void = { _ in }) async throws
        -> ProfileBackup.ExportResult {
        try checkNoBackupConflict()
        if let busy = ids.first(where: isBusy) {
            let name = store.profiles.first { $0.id == busy }?.name ?? "Profile"
            throw ProfileError.invalid("「\(name)」正在执行另一个操作，请稍后再备份。")
        }
        archiving.formUnion(ids)
        defer { archiving.subtract(ids) }
        return try await ProfileBackup.export(ids, to: destination, store: store, runtime: runtime, progress: progress)
    }

    /// Restores a full backup (see `ProfileBackup.restore`). Every Profile it adds stays busy until
    /// it finishes, because their cookies are imported in a headless launch at the end.
    public func restoreBackup(from file: URL, identity: ProfileBackup.IdentityPolicy = .renew,
                              selection: Set<UUID>? = nil,
                              progress: @escaping (ProfileBackup.Progress) -> Void = { _ in }) async throws
        -> ProfileBackup.RestoreResult {
        try checkNoBackupConflict()
        restoreBaseline = Set(store.profiles.map(\.id)).union(store.trashed.map(\.id))
        defer { restoreBaseline = nil }
        return try await ProfileBackup.restore(from: file, store: store, runtime: runtime, identity: identity,
                                               selection: selection, progress: progress)
    }

    private func checkNoBackupConflict() throws {
        guard batch == nil else { throw ProfileError.invalid("批量操作正在进行，请等它完成或取消后再备份或恢复。") }
        guard archiving.isEmpty, restoreBaseline == nil else {
            throw ProfileError.invalid("另一个完整备份或恢复正在进行，请等它完成。")
        }
    }
}
