import Darwin
import Foundation
import SQLite3

/// Held for as long as this process uses a data directory. A second AnyBrowser on the same
/// directory would overwrite this one's edits with its own stale copy of the Profiles.
public final class InstanceLock {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        // Closing the only descriptor of the open file releases the lock.
        close(descriptor)
    }
}

extension ProfileStore {
    /// How many backups `Backups/` keeps; older ones are deleted after each new one.
    public nonisolated static let keptBackups = 10
    static let backupInterval: TimeInterval = 24 * 60 * 60

    /// Locks `<directory>/.instance.lock` for this process. Throws when another process holds it.
    public nonisolated static func acquireInstanceLock(in directory: URL) throws -> InstanceLock {
        try PrivateDirectory.ensure(directory, failure: "无法锁定本机 Profile 资料目录。")
        // Close-on-exec: browsers started by this process must not keep the lock after it quits.
        let fd = open(directory.appendingPathComponent(".instance.lock").path,
                      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProfileError.invalid("无法锁定本机 Profile 资料目录。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            close(fd)
            throw ProfileError.invalid(busy ? "AnyBrowser 已经在运行，同一份 Profile 资料不能由两个 AnyBrowser 同时打开。"
                                            : "无法锁定本机 Profile 资料目录。")
        }
        return InstanceLock(descriptor: fd)
    }

    /// Copies the database into `Backups/` (readable only by the current user) and keeps the
    /// newest `keptBackups` copies. `reason` becomes part of the file name.
    @discardableResult
    public func backup(reason: String) throws -> URL {
        let folder = try Self.backupFolder(in: directory)
        let target = Self.newBackupURL(in: folder, reason: reason)
        guard let database else { throw ProfileError.invalid("本机 Profile 数据库不可用。") }
        try Self.copy(database, to: target)
        Self.pruneBackups(in: folder)
        return target
    }

    /// Backups of this store's database, newest first.
    public func backups() -> [URL] {
        Self.backups(in: directory)
    }

    /// Makes the daily backup when the newest one is a day old, or there is none yet.
    func backupIfDue(now: Date = Date()) {
        guard (try? hasData()) == true else { return }
        if let newest = backups().first.flatMap(Self.backupDate) {
            let age = now.timeIntervalSince(newest)
            if age >= 0, age < Self.backupInterval { return }
        }
        do {
            try backup(reason: "daily")
        } catch {
            backupFailure = error.localizedDescription
        }
    }

    private func hasData() throws -> Bool {
        let read = try statement("SELECT EXISTS(SELECT 1 FROM profiles) OR EXISTS(SELECT 1 FROM settings)")
        defer { sqlite3_finalize(read) }
        guard sqlite3_step(read) == SQLITE_ROW else { throw databaseError() }
        return sqlite3_column_int(read, 0) != 0
    }

    /// Replaces the database in `directory` with `backup` in one rename. The database it replaces is
    /// first kept as another backup, even when it is damaged. Nothing is replaced when the backup is
    /// unusable or the current database cannot be kept. The caller makes sure no store has the
    /// directory open.
    public nonisolated static func restoreBackup(_ backup: URL, into directory: URL) throws {
        guard let canonical = realpath(directory.path, nil) else {
            throw ProfileError.invalid("无法定位本机 Profile 资料目录。")
        }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        let database = root.appendingPathComponent("profiles.sqlite3")
        let unusable = ProfileError.invalid("备份文件「\(backup.lastPathComponent)」不是可用的 AnyBrowser 数据库。")

        var source: OpaquePointer?
        defer { sqlite3_close(source) }
        guard sqlite3_open_v2(backup.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let source, check(source) else { throw unusable }

        let folder = try backupFolder(in: root)
        if FileManager.default.fileExists(atPath: database.path) {
            try keep(database, in: folder)
        }
        // A journal left by the replaced database would be rolled into the restored one.
        for suffix in ["-journal", "-wal", "-shm"] {
            let companion = database.path + suffix
            guard unlink(companion) == 0 || errno == ENOENT else {
                throw ProfileError.invalid("无法替换本机 Profile 数据库。")
            }
        }
        try copy(source, to: database)
        pruneBackups(in: folder)
    }

    /// Keeps the database about to be replaced byte for byte, with its journal, so even a damaged
    /// one is not lost and SQLite never gets to touch it first. No store has it open, so the
    /// files are not changing.
    private nonisolated static func keep(_ database: URL, in folder: URL) throws {
        let target = newBackupURL(in: folder, reason: "replaced")
        let failure = "无法保留当前的本机 Profile 数据库，没有恢复备份。"
        for suffix in ["", "-journal", "-wal"] {
            let file = URL(fileURLWithPath: database.path + suffix)
            guard suffix.isEmpty || FileManager.default.fileExists(atPath: file.path) else { continue }
            guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { throw ProfileError.invalid(failure) }
            try PrivateFile.write(data, to: URL(fileURLWithPath: target.path + suffix), failure: failure)
        }
    }

    /// Whether `database` is intact and has the Profiles table.
    private nonisolated static func check(_ database: OpaquePointer) -> Bool {
        var read: OpaquePointer?
        defer { sqlite3_finalize(read) }
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &read, nil) == SQLITE_OK,
              sqlite3_step(read) == SQLITE_ROW, let text = sqlite3_column_text(read, 0),
              String(cString: text) == "ok" else { return false }
        var table: OpaquePointer?
        defer { sqlite3_finalize(table) }
        return sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='profiles'",
                                  -1, &table, nil) == SQLITE_OK && sqlite3_step(table) == SQLITE_ROW
    }

    /// Copies a whole database into a new 0600 file at `target`, staged next to it and renamed into place.
    private nonisolated static func copy(_ source: OpaquePointer, to target: URL) throws {
        let failure = ProfileError.invalid("无法备份本机 Profile 数据库。")
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).sqlite3")
        // Created as 0600 first, so the copy is never readable by anyone else, even briefly.
        let fd = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure }
        let restricted = fchmod(fd, 0o600) == 0
        close(fd)
        var copied = false
        defer { if !copied { unlink(staging.path) } }
        var destination: OpaquePointer?
        guard restricted, sqlite3_open_v2(staging.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let destination, let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            sqlite3_close(destination)
            throw failure
        }
        let stepped = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        let closed = sqlite3_close(destination)
        guard stepped == SQLITE_DONE, finished == SQLITE_OK, closed == SQLITE_OK,
              rename(staging.path, target.path) == 0 else { throw failure }
        copied = true
    }

    private nonisolated static func backupFolder(in directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent("Backups", isDirectory: true)
        try PrivateDirectory.ensure(folder, failure: "无法创建本机 Profile 数据库的备份目录。")
        return folder
    }

    nonisolated static func backups(in directory: URL) -> [URL] {
        let folder = directory.appendingPathComponent("Backups", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".sqlite3") && backupDate(folder.appendingPathComponent($0)) != nil }
            .sorted(by: >)
            .map { folder.appendingPathComponent($0) }
    }

    /// `profiles-<UTC time>-<reason>.sqlite3`; names sort in the order the backups were made.
    private nonisolated static func newBackupURL(in folder: URL, reason: String) -> URL {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        var label = String(reason.lowercased().map { allowed.contains($0) ? $0 : "-" }.prefix(32))
        if label.isEmpty { label = "manual" }
        var date = Date()
        while true {
            let url = folder.appendingPathComponent("profiles-\(backupStamp.string(from: date))-\(label).sqlite3")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            date.addTimeInterval(0.001)
        }
    }

    /// When a backup was made, read from its name.
    nonisolated static func backupDate(_ url: URL) -> Date? {
        let name = url.lastPathComponent
        guard name.hasPrefix("profiles-") else { return nil }
        return backupStamp.date(from: String(name.dropFirst(9).prefix(19)))
    }

    private nonisolated static var backupStamp: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }

    /// Deletes all but the newest `keptBackups` backups, and the staging files of interrupted ones.
    private nonisolated static func pruneBackups(in folder: URL) {
        for old in backups(in: folder.deletingLastPathComponent()).dropFirst(keptBackups) {
            for suffix in ["", "-journal", "-wal"] { unlink(old.path + suffix) }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if let modified, Date().timeIntervalSince(modified) > 600 { unlink(url.path) }
        }
    }
}
