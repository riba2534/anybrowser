import Combine
import Darwin
import Foundation
import SQLite3

/// SQLITE_TRANSIENT: SQLite copies bound values before the call returns.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@MainActor
public final class ProfileStore: ObservableObject {
    @Published public private(set) var profiles: [BrowserProfile] = []
    /// The Passkey Box account every Profile's extension signs in with.
    @Published public private(set) var passkeyBoxAccount: PasskeyBoxAccount?
    /// Rows that could not be decoded or validated. They stay in the database untouched.
    @Published public private(set) var unreadableProfiles = 0
    @Published public private(set) var lastLaunched: [UUID: Date] = [:]
    public let directory: URL
    private var database: OpaquePointer?
    // Unreadable rows keep their port and seed so new Profiles never collide with them.
    private var unreadablePorts: Set<Int> = []
    private var unreadableSeeds: Set<Int> = []

    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("AnyBrowser", isDirectory: true)
    }

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard let canonical = realpath(directory.path, nil) else {
            throw ProfileError.invalid("无法定位本机 Profile 资料目录。")
        }
        defer { free(canonical) }
        self.directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        let path = self.directory.appendingPathComponent("profiles.sqlite3")
        var opened: OpaquePointer?
        guard sqlite3_open_v2(path.path, &opened, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let opened else {
            sqlite3_close(opened)
            throw ProfileError.invalid("无法打开本机 Profile 数据库。")
        }
        database = opened
        sqlite3_busy_timeout(database, 2000)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            guard sqlite3_exec(database, """
                CREATE TABLE IF NOT EXISTS profiles (
                    id TEXT PRIMARY KEY NOT NULL,
                    port INTEGER NOT NULL UNIQUE,
                    seed INTEGER NOT NULL UNIQUE,
                    payload BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY NOT NULL,
                    value BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS profile_usage (
                    id TEXT PRIMARY KEY NOT NULL,
                    last_launched_at REAL NOT NULL
                )
                """, nil, nil, nil) == SQLITE_OK else {
                throw databaseError()
            }
            let read = try statement("SELECT id, port, seed, payload FROM profiles ORDER BY rowid")
            defer { sqlite3_finalize(read) }
            var status = sqlite3_step(read)
            while status == SQLITE_ROW {
                let count = Int(sqlite3_column_bytes(read, 3))
                if let bytes = sqlite3_column_blob(read, 3),
                   let profile = try? JSONDecoder().decode(BrowserProfile.self, from: Data(bytes: bytes, count: count)),
                   let id = sqlite3_column_text(read, 0), String(cString: id) == profile.id.uuidString,
                   sqlite3_column_int64(read, 1) == profile.port, sqlite3_column_int64(read, 2) == profile.fingerprint.seed,
                   (try? profile.validated()) != nil {
                    profiles.append(profile)
                } else {
                    unreadableProfiles += 1
                    unreadablePorts.insert(Int(sqlite3_column_int64(read, 1)))
                    unreadableSeeds.insert(Int(sqlite3_column_int64(read, 2)))
                }
                status = sqlite3_step(read)
            }
            guard status == SQLITE_DONE else { throw databaseError() }
            let usage = try statement("SELECT id, last_launched_at FROM profile_usage")
            defer { sqlite3_finalize(usage) }
            status = sqlite3_step(usage)
            while status == SQLITE_ROW {
                if let text = sqlite3_column_text(usage, 0), let id = UUID(uuidString: String(cString: text)) {
                    lastLaunched[id] = Date(timeIntervalSince1970: sqlite3_column_double(usage, 1))
                }
                status = sqlite3_step(usage)
            }
            guard status == SQLITE_DONE else { throw databaseError() }
            passkeyBoxAccount = try? setting(PasskeyBoxAccount.self, forKey: Self.passkeyBoxKey)?.validated()
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    /// Debug ports in use, including those of rows that could not be read.
    public var takenPorts: Set<Int> { Set(profiles.map(\.port)).union(unreadablePorts) }
    /// Fingerprint seeds in use, including those of rows that could not be read.
    public var takenSeeds: Set<Int> { Set(profiles.map(\.fingerprint.seed)).union(unreadableSeeds) }

    public func makeDraft() throws -> BrowserProfile {
        let port = try ProfileLibrary.freePort(excluding: takenPorts)
        let names = Set(profiles.map(\.name))
        let index = (1...(names.count + 1)).first { !names.contains("Profile \($0)") }!
        let fingerprint = FingerprintSettings(seed: FingerprintSettings.newSeed(excluding: takenSeeds))
        return BrowserProfile(name: "Profile \(index)", port: port, fingerprint: fingerprint)
    }

    public func save(_ profile: BrowserProfile) throws {
        keep(try insert(profile))
    }

    /// Saves several Profiles in one transaction: either all of them are saved or none is.
    public func saveAll(_ values: [BrowserProfile]) throws {
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
        let written: [BrowserProfile]
        do {
            written = try values.map(insert)
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
        written.forEach(keep)
    }

    private func keep(_ profile: BrowserProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// Validates and writes one row; `profiles` is updated by the caller once the write is final.
    private func insert(_ profile: BrowserProfile) throws -> BrowserProfile {
        let profile = try profile.validated()
        try checkForConflicts(profile)
        let payload = try JSONEncoder().encode(profile)
        let write = try statement("""
            INSERT INTO profiles(id, port, seed, payload) VALUES(?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET port=excluded.port, seed=excluded.seed, payload=excluded.payload
            """)
        defer { sqlite3_finalize(write) }
        guard sqlite3_bind_text(write, 1, profile.id.uuidString, -1, transient) == SQLITE_OK,
              sqlite3_bind_int(write, 2, Int32(profile.port)) == SQLITE_OK,
              sqlite3_bind_int(write, 3, Int32(profile.fingerprint.seed)) == SQLITE_OK,
              payload.withUnsafeBytes({
                sqlite3_bind_blob(write, 4, $0.baseAddress, Int32($0.count), transient)
              }) == SQLITE_OK else {
            throw databaseError()
        }
        guard sqlite3_step(write) == SQLITE_DONE else {
            if sqlite3_errcode(database) == SQLITE_CONSTRAINT {
                throw ProfileError.invalid("调试端口或指纹种子与已有 Profile 重复。")
            }
            throw databaseError()
        }
        return profile
    }

    public func remove(_ id: UUID) throws {
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
        do {
            for sql in ["DELETE FROM profiles WHERE id=?", "DELETE FROM profile_usage WHERE id=?"] {
                let delete = try statement(sql)
                defer { sqlite3_finalize(delete) }
                guard sqlite3_bind_text(delete, 1, id.uuidString, -1, transient) == SQLITE_OK,
                      sqlite3_step(delete) == SQLITE_DONE else {
                    throw databaseError()
                }
            }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
        profiles.removeAll { $0.id == id }
        lastLaunched[id] = nil
    }

    public func randomize(_ profile: BrowserProfile, fields: Set<FingerprintField>) throws -> BrowserProfile {
        if fields.contains(.platformVersion), !fields.contains(.platform), profile.fingerprint.platform == nil {
            throw ProfileError.invalid("先选择平台，或同时勾选平台与平台版本。")
        }
        if fields.contains(.brandVersion), !fields.contains(.brand), profile.fingerprint.brand == nil {
            throw ProfileError.invalid("先选择浏览器品牌，或同时勾选品牌与品牌版本。")
        }
        var draft = profile
        draft.fingerprint.randomize(fields, excluding: Set(profiles.map(\.fingerprint.seed)))
        return draft
    }

    /// Saves the Passkey Box account, or removes it when `account` is nil.
    public func savePasskeyBoxAccount(_ account: PasskeyBoxAccount?) throws {
        let value = try account?.validated()
        try saveSetting(value, forKey: Self.passkeyBoxKey)
        passkeyBoxAccount = value
    }

    /// Records that a Profile was just started. Failing to record never affects the launch.
    public func recordLaunch(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        let now = Date()
        guard let write = try? statement("""
            INSERT INTO profile_usage(id, last_launched_at) VALUES(?, ?)
            ON CONFLICT(id) DO UPDATE SET last_launched_at=excluded.last_launched_at
            """) else { return }
        defer { sqlite3_finalize(write) }
        guard sqlite3_bind_text(write, 1, id.uuidString, -1, transient) == SQLITE_OK,
              sqlite3_bind_double(write, 2, now.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(write) == SQLITE_DONE else { return }
        lastLaunched[id] = now
    }

    private static let passkeyBoxKey = "passkeyBox"

    /// An app-wide setting stored as JSON, or nil when it is missing or unreadable.
    public func setting<Value: Decodable>(_ type: Value.Type, forKey key: String) throws -> Value? {
        let read = try statement("SELECT value FROM settings WHERE key=?")
        defer { sqlite3_finalize(read) }
        guard sqlite3_bind_text(read, 1, key, -1, transient) == SQLITE_OK else { throw databaseError() }
        switch sqlite3_step(read) {
        case SQLITE_ROW:
            let count = Int(sqlite3_column_bytes(read, 0))
            guard let bytes = sqlite3_column_blob(read, 0) else { return nil }
            return try? JSONDecoder().decode(Value.self, from: Data(bytes: bytes, count: count))
        case SQLITE_DONE:
            return nil
        default:
            throw databaseError()
        }
    }

    /// Stores an app-wide setting as JSON, or deletes it when `value` is nil.
    public func saveSetting<Value: Encodable>(_ value: Value?, forKey key: String) throws {
        guard let value else {
            let delete = try statement("DELETE FROM settings WHERE key=?")
            defer { sqlite3_finalize(delete) }
            guard sqlite3_bind_text(delete, 1, key, -1, transient) == SQLITE_OK,
                  sqlite3_step(delete) == SQLITE_DONE else {
                throw databaseError()
            }
            return
        }
        let payload = try JSONEncoder().encode(value)
        let write = try statement("""
            INSERT INTO settings(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """)
        defer { sqlite3_finalize(write) }
        guard sqlite3_bind_text(write, 1, key, -1, transient) == SQLITE_OK,
              payload.withUnsafeBytes({
                sqlite3_bind_blob(write, 2, $0.baseAddress, Int32($0.count), transient)
              }) == SQLITE_OK,
              sqlite3_step(write) == SQLITE_DONE else {
            throw databaseError()
        }
    }

    private func checkForConflicts(_ profile: BrowserProfile) throws {
        for other in profiles where other.id != profile.id {
            if other.port == profile.port {
                throw ProfileError.invalid("调试端口 \(profile.port) 已分配给 \(other.name)。")
            }
            if other.fingerprint.seed == profile.fingerprint.seed {
                throw ProfileError.invalid("指纹种子已分配给 \(other.name)。")
            }
        }
        if unreadablePorts.contains(profile.port) {
            throw ProfileError.invalid("调试端口 \(profile.port) 已被一份无法读取的 Profile 占用。")
        }
        if unreadableSeeds.contains(profile.fingerprint.seed) {
            throw ProfileError.invalid("指纹种子已被一份无法读取的 Profile 占用。")
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &value, nil) == SQLITE_OK, let value else {
            throw databaseError()
        }
        return value
    }

    private func databaseError() -> ProfileError {
        .invalid("本机 Profile 数据库操作失败（\(sqlite3_errcode(database))）。")
    }
}
