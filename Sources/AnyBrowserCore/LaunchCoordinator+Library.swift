import Foundation

extension LaunchCoordinator {
    /// Why the Profile cannot be removed or moved to the recycle bin right now, or nil.
    public func removalBlocker(_ id: UUID) -> String? {
        ProfileLibrary.removalBlocker(state: runtime.status(for: id), busy: isBusy(id), batchRunning: batch != nil)
    }

    /// Removes the record for good, then the extension directory holding the passwords AnyBrowser
    /// wrote for the Profile, and with `deletingBrowserData` its browser data and cache too. Throws
    /// when nothing was removed. Once the record is gone, a directory that could not be deleted is
    /// reported by the returned message. `recordRemoved` runs as soon as the record is gone.
    public func remove(_ id: UUID, deletingBrowserData: Bool, recordRemoved: () -> Void = {}) async throws -> String? {
        if let blocker = removalBlocker(id) { throw ProfileError.invalid(blocker) }
        var removed = false
        defer { removing.remove(id) }
        do {
            try await runtime.removeData(for: id, keepingBrowserData: !deletingBrowserData) {
                try store.remove(id)
                try? proxyLibrary.forgetExit(forProfile: id)
                removed = true
                removing.insert(id)
                recordRemoved()
            }
            return nil
        } catch where removed {
            return error.localizedDescription
        }
    }

    /// Moves a stopped Profile to the recycle bin. Its browser data stays until it is purged.
    public func trash(_ id: UUID) throws {
        if let blocker = removalBlocker(id) { throw ProfileError.invalid(blocker) }
        try store.trash(id)
    }

    /// Takes a Profile out of the recycle bin, unless a purge is deleting its data right now.
    public func restore(_ id: UUID) throws {
        guard !isBusy(id) else { throw ProfileError.invalid("该 Profile 正在执行另一个操作，请稍后再恢复。") }
        try store.restore(id)
    }

    /// Deletes a trashed Profile's browser data, cache and extension directories, then its record.
    /// The record stays when a directory cannot be deleted, so purging again picks up the rest.
    public func purge(_ id: UUID) async throws {
        guard store.trashed.contains(where: { $0.id == id }) else {
            throw ProfileError.invalid("回收站中没有这个 Profile。")
        }
        guard !isBusy(id) else { throw ProfileError.invalid("该 Profile 正在执行另一个操作，请稍后再删除。") }
        removing.insert(id)
        defer { removing.remove(id) }
        try await runtime.removeData(for: id)
        try store.purge(id)
        try? proxyLibrary.forgetExit(forProfile: id)
    }

    /// Housekeeping when AnyBrowser starts: purges Profiles 30 days in the recycle bin, then
    /// deletes cache directories under ~/Library/Caches no saved, trashed or unreadable Profile
    /// owns. Returns the problems, which are logged and stop nothing.
    @discardableResult
    public func performLaunchMaintenance(now: Date = Date()) async -> [String] {
        // A newer version's database: its rows may mean more than this version can tell.
        guard !store.isReadOnly else { return [] }
        var problems: [String] = []
        for id in store.expiredTrash(now: now) {
            do {
                try await purge(id)
            } catch {
                problems.append("未能清理回收站中过期的 Profile \(id.uuidString)：\(error.localizedDescription)")
            }
        }
        var known = Set(store.profiles.map(\.id)).union(store.trashed.map(\.id))
        known.formUnion(store.unreadableRows.compactMap { UUID(uuidString: $0.id) })
        do {
            try await runtime.removeOrphanCacheDirectories(knownProfiles: known)
        } catch {
            problems.append(error.localizedDescription)
        }
        for problem in problems { NSLog("AnyBrowser: %@", problem) }
        return problems
    }
}
