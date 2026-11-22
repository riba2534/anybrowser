import Combine
import Darwin
import Foundation
import SQLite3

/// SQLITE_TRANSIENT: SQLite copies bound values before the call returns.
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let transient = sqliteTransient

/// A removed Profile in the recycle bin. It keeps its row, id, port and seed until it is purged,
/// so restoring it reconnects its browser data.
public struct TrashedProfile: Identifiable, Equatable, Sendable {
    public var profile: BrowserProfile
    public var deletedAt: Date
    public var id: UUID { profile.id }

    public init(profile: BrowserProfile, deletedAt: Date) {
        self.profile = profile
        self.deletedAt = deletedAt
    }
}

/// A saved row this version cannot use. It stays in the database exactly as written.
public struct UnreadableProfile: Identifiable, Equatable, Sendable {
    /// The row's id column; usually a Profile UUID.
    public var id: String
    public var port: Int
    public var seed: Int
    /// Why the row cannot be read, for the user.
    public var reason: String
    /// The stored JSON, unchanged, for exporting.
    public var payload: Data
}

/// A value that only a newer AnyBrowser knows, such as a font set added later.
struct NewerValue: Error {
    var value: String

    static func known<Value: RawRepresentable>(_ type: Value.Type, _ raw: String) throws -> Value
        where Value.RawValue == String {
        guard let value = Value(rawValue: raw) else { throw NewerValue(value: raw) }
        return value
    }
}

extension KeyedDecodingContainer {
    /// An optional enum value; one written by a newer version throws `NewerValue`.
    func decodeKnown<Value: RawRepresentable>(_ type: Value.Type, forKey key: Key) throws -> Value?
        where Value.RawValue == String {
        try decodeIfPresent(String.self, forKey: key).map { try NewerValue.known(Value.self, $0) }
    }
}

@MainActor
public final class ProfileStore: ObservableObject {
    @Published public private(set) var profiles: [BrowserProfile] = []
    /// Profiles in the recycle bin, most recently removed first. They are not in `profiles`.
    @Published public private(set) var trashed: [TrashedProfile] = []
    /// The Passkey Box account every Profile's extension signs in with.
    @Published public private(set) var passkeyBoxAccount: PasskeyBoxAccount?
    /// Rows that could not be decoded or validated, with the reason. They stay in the database
    /// untouched and keep their port and seed, so new Profiles never collide with them.
    @Published public private(set) var unreadableRows: [UnreadableProfile] = []
    @Published public private(set) var lastLaunched: [UUID: Date] = [:]
    /// The database was written by a newer AnyBrowser: everything reads, every write throws.
    public private(set) var isReadOnly = false
    /// Why the automatic backup made when the store opened failed, or nil.
    public internal(set) var backupFailure: String?
    public let directory: URL
    private(set) var database: OpaquePointer?
    @Published private var pendingResets: Set<UUID> = []
    @Published private var launchFingerprints: [UUID: FingerprintSettings] = [:]
    /// Each saved row's JSON as read or last written. Fields this version does not know are
    /// merged back from it on every save, so a newer version's settings survive an older one.
    private var storedPayloads: [UUID: Data] = [:]
    /// Row order, so a restored Profile returns to its place in creation order.
    private var rowids: [UUID: Int64] = [:]

    /// Kept for callers that only show a count.
    public var unreadableProfiles: Int { unreadableRows.count }

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
            let version = try userVersion()
            if version > Self.schemaVersion {
                // Rewriting rows or tables of a newer schema could destroy what that version stored.
                openedSchemaVersion = version
                isReadOnly = true
                guard sqlite3_exec(database, "PRAGMA query_only = 1", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
            } else {
                // A migration is the one write that touches every table; keep the database as it was first.
                if version < Self.schemaVersion, try hasTables() {
                    try backup(reason: "upgrade")
                }
                try migrate()
            }
            try load()
            if !isReadOnly { backupIfDue() }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    /// Reads every table into memory, assigning each published value once.
    private func load() throws {
        var readable: [BrowserProfile] = []
        var bin: [TrashedProfile] = []
        var unreadable: [UnreadableProfile] = []
        let read = try statement("SELECT rowid, id, port, seed, payload, deleted_at FROM profiles ORDER BY rowid")
        defer { sqlite3_finalize(read) }
        var status = sqlite3_step(read)
        while status == SQLITE_ROW {
            let id = sqlite3_column_text(read, 1).map { String(cString: $0) } ?? ""
            let port = Int(sqlite3_column_int64(read, 2))
            let seed = Int(sqlite3_column_int64(read, 3))
            let count = Int(sqlite3_column_bytes(read, 4))
            let payload = sqlite3_column_blob(read, 4).map { Data(bytes: $0, count: count) } ?? Data()
            switch Self.decodeRow(payload, id: id, port: port, seed: seed) {
            case .success(let profile):
                rowids[profile.id] = sqlite3_column_int64(read, 0)
                storedPayloads[profile.id] = payload
                if sqlite3_column_type(read, 5) == SQLITE_NULL {
                    readable.append(profile)
                } else {
                    bin.append(TrashedProfile(profile: profile,
                                              deletedAt: Date(timeIntervalSince1970: sqlite3_column_double(read, 5))))
                }
            case .failure(let failure):
                unreadable.append(UnreadableProfile(id: id, port: port, seed: seed, reason: failure.reason, payload: payload))
            }
            status = sqlite3_step(read)
        }
        guard status == SQLITE_DONE else { throw databaseError() }
        profiles = readable
        trashed = bin.sorted { $0.deletedAt > $1.deletedAt }
        unreadableRows = unreadable

        var launched: [UUID: Date] = [:]
        let usage = try statement("SELECT id, last_launched_at FROM profile_usage")
        defer { sqlite3_finalize(usage) }
        status = sqlite3_step(usage)
        while status == SQLITE_ROW {
            if let text = sqlite3_column_text(usage, 0), let id = UUID(uuidString: String(cString: text)) {
                launched[id] = Date(timeIntervalSince1970: sqlite3_column_double(usage, 1))
            }
            status = sqlite3_step(usage)
        }
        guard status == SQLITE_DONE else { throw databaseError() }
        lastLaunched = launched

        var resets: Set<UUID> = []
        var fingerprints: [UUID: FingerprintSettings] = [:]
        let bookkeeping = try statement("SELECT key, value FROM settings WHERE key LIKE ? OR key LIKE ?")
        defer { sqlite3_finalize(bookkeeping) }
        guard sqlite3_bind_text(bookkeeping, 1, Self.pendingResetPrefix + "%", -1, transient) == SQLITE_OK,
              sqlite3_bind_text(bookkeeping, 2, Self.launchFingerprintPrefix + "%", -1, transient) == SQLITE_OK else {
            throw databaseError()
        }
        status = sqlite3_step(bookkeeping)
        while status == SQLITE_ROW {
            let key = sqlite3_column_text(bookkeeping, 0).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_bytes(bookkeeping, 1))
            let value = sqlite3_column_blob(bookkeeping, 1).map { Data(bytes: $0, count: count) } ?? Data()
            if key.hasPrefix(Self.pendingResetPrefix),
               let id = UUID(uuidString: String(key.dropFirst(Self.pendingResetPrefix.count))),
               (try? JSONDecoder().decode(Bool.self, from: value)) == true {
                resets.insert(id)
            } else if key.hasPrefix(Self.launchFingerprintPrefix),
                      let id = UUID(uuidString: String(key.dropFirst(Self.launchFingerprintPrefix.count))),
                      let fingerprint = try? JSONDecoder().decode(FingerprintSettings.self, from: value) {
                fingerprints[id] = fingerprint
            }
            status = sqlite3_step(bookkeeping)
        }
        guard status == SQLITE_DONE else { throw databaseError() }
        pendingResets = resets
        launchFingerprints = fingerprints
        passkeyBoxAccount = try? setting(PasskeyBoxAccount.self, forKey: Self.passkeyBoxKey)?.validated()
    }

    struct ReadFailure: Error {
        var reason: String
    }

    /// The Profile stored in a row, or why it cannot be used. Nothing is repaired here: a row
    /// fixed up in memory would be written back the next time it is saved.
    nonisolated static func decodeRow(_ payload: Data, id: String, port: Int, seed: Int) -> Result<BrowserProfile, ReadFailure> {
        let profile: BrowserProfile
        do {
            profile = try JSONDecoder().decode(BrowserProfile.self, from: payload)
        } catch {
            return .failure(ReadFailure(reason: readFailure(error)))
        }
        guard id == profile.id.uuidString, port == profile.port, seed == profile.fingerprint.seed else {
            return .failure(ReadFailure(reason: "数据库中的 id、端口或种子与配置不一致。"))
        }
        do {
            _ = try profile.validated()
        } catch {
            return .failure(ReadFailure(reason: "配置未通过校验：\(error.localizedDescription)"))
        }
        return .success(profile)
    }

    /// Why a stored or imported Profile could not be decoded, for the user. `below` drops that many
    /// leading coding keys, the place of the Profile within a larger file.
    nonisolated static func readFailure(_ error: Error, below depth: Int = 0) -> String {
        func field(_ path: [CodingKey]) -> String {
            path.dropFirst(depth).map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case let newer as NewerValue:
            return "由更新版本写入：未知取值 \(newer.value.prefix(64))"
        case DecodingError.keyNotFound(let key, let context):
            return "缺少字段 \(field(context.codingPath + [key]))。"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            if context.codingPath.count <= depth {
                return context.underlyingError == nil ? "不是 Profile 配置。" : "配置不是有效的 JSON。"
            }
            return "字段 \(field(context.codingPath)) 的取值无效。"
        default:
            return error.localizedDescription
        }
    }

    /// Debug ports in use, including those of trashed Profiles and of rows that could not be read.
    public var takenPorts: Set<Int> {
        Set(profiles.map(\.port)).union(trashed.map(\.profile.port)).union(unreadableRows.map(\.port))
    }
    /// Fingerprint seeds in use, including those of trashed Profiles and of rows that could not be read.
    public var takenSeeds: Set<Int> {
        Set(profiles.map(\.fingerprint.seed)).union(trashed.map(\.profile.fingerprint.seed))
            .union(unreadableRows.map(\.seed))
    }

    public func makeDraft() throws -> BrowserProfile {
        let port = try ProfileLibrary.freePort(excluding: takenPorts)
        let names = Set(profiles.map(\.name))
        let index = (1...(names.count + 1)).first { !names.contains("Profile \($0)") }!
        let fingerprint = IdentitySampler.sample(seed: FingerprintSettings.newSeed(excluding: takenSeeds))
        return BrowserProfile(name: "Profile \(index)", port: port, fingerprint: fingerprint)
    }

    /// A new identity for an existing Profile, keeping its name, port, proxy, account and launch options.
    /// The caller decides whether to save it; the UI uses this for "整套重新生成".
    public func regenerateIdentity(_ profile: BrowserProfile, preset: IdentityPreset? = nil,
                                   locale: IdentitySampler.LocaleHint? = nil) throws -> BrowserProfile {
        var value = profile
        let seeds = takenSeeds.union([profile.fingerprint.seed])
        let platforms = profile.fingerprint.platform.map { [$0] }
        value.fingerprint = IdentitySampler.sample(
            seed: FingerprintSettings.newSeed(excluding: seeds),
            constraints: .init(platforms: platforms, preset: preset, locale: locale))
        return try value.validated()
    }

    public func save(_ profile: BrowserProfile) throws {
        try saveAll([profile])
    }

    /// Saves several Profiles in one transaction: either all of them are saved or none is.
    /// Returns them as written.
    @discardableResult
    public func saveAll(_ values: [BrowserProfile]) throws -> [BrowserProfile] {
        guard !values.isEmpty else { return [] }
        var holders = self.holders()
        let rows = try transaction { try values.map { try insert($0, holders: &holders) } }
        // Only now is the write final; `profiles` is assigned once however many rows were saved.
        var saved = profiles
        var positions = Dictionary(saved.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows {
            storedPayloads[row.profile.id] = row.payload
            if rowids[row.profile.id] == nil { rowids[row.profile.id] = row.rowid }
            if let position = positions[row.profile.id] {
                saved[position] = row.profile
            } else {
                positions[row.profile.id] = saved.count
                saved.append(row.profile)
            }
        }
        profiles = saved
        return rows.map(\.profile)
    }

    /// Applies `change` to each saved Profile in `ids` and saves the ones it changed in one
    /// transaction. If `change` or validation fails for any of them, nothing is saved and the
    /// error names that Profile. Ids that are not saved Profiles, for example ones moved to the
    /// recycle bin meanwhile, are skipped. Returns the changed Profiles as written.
    @discardableResult
    public func update(_ ids: [UUID], _ change: (inout BrowserProfile) throws -> Void) throws -> [BrowserProfile] {
        try requireWritable()
        let saved = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<UUID> = []
        var changed: [BrowserProfile] = []
        for id in ids where seen.insert(id).inserted {
            guard let original = saved[id] else { continue }
            var value = original
            do {
                try change(&value)
                value.id = id
                _ = try value.validated()
            } catch {
                throw ProfileError.invalid("\(original.name)：\(error.localizedDescription)")
            }
            if value != original { changed.append(value) }
        }
        return try saveAll(changed)
    }

    /// Who holds a port or seed, so a save can name the Profile it collides with.
    private enum Holder {
        case profile(UUID, String), trashed(UUID, String), unreadable

        func owns(_ id: UUID) -> Bool {
            switch self {
            case .profile(let owner, _), .trashed(let owner, _): return owner == id
            case .unreadable: return false
            }
        }
    }

    /// Built once per write, so saving a large import stays linear.
    private func holders() -> (ports: [Int: Holder], seeds: [Int: Holder]) {
        var ports: [Int: Holder] = [:]
        var seeds: [Int: Holder] = [:]
        for row in unreadableRows {
            ports[row.port] = .unreadable
            seeds[row.seed] = .unreadable
        }
        for entry in trashed {
            ports[entry.profile.port] = .trashed(entry.id, entry.profile.name)
            seeds[entry.profile.fingerprint.seed] = .trashed(entry.id, entry.profile.name)
        }
        for profile in profiles {
            ports[profile.port] = .profile(profile.id, profile.name)
            seeds[profile.fingerprint.seed] = .profile(profile.id, profile.name)
        }
        return (ports, seeds)
    }

    private struct WrittenRow {
        var profile: BrowserProfile
        var payload: Data
        var rowid: Int64
    }

    /// Validates and writes one row; the caller updates what is kept in memory once the write is final.
    private func insert(_ profile: BrowserProfile, holders: inout (ports: [Int: Holder], seeds: [Int: Holder])) throws -> WrittenRow {
        let profile = try profile.validated()
        if trashed.contains(where: { $0.id == profile.id }) {
            throw ProfileError.invalid("「\(profile.name)」在回收站中，恢复后才能修改。")
        }
        // An upsert would overwrite a row this version cannot read with what it can.
        if unreadableRows.contains(where: { UUID(uuidString: $0.id) == profile.id }) {
            throw ProfileError.invalid("已保存的这份 Profile 配置无法读取，不能覆盖。")
        }
        try checkForConflicts(profile, holders: holders)
        let payload = try payload(for: profile)
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
        holders.ports[profile.port] = .profile(profile.id, profile.name)
        holders.seeds[profile.fingerprint.seed] = .profile(profile.id, profile.name)
        // Only read for new rows; an upsert that updates leaves it at an older insert.
        return WrittenRow(profile: profile, payload: payload, rowid: sqlite3_last_insert_rowid(database))
    }

    /// The row to write: the Profile's encoding plus the fields of its stored row this version
    /// does not know. A field is unknown when it disappears from the stored row once that row is
    /// decoded and encoded again; fields the user cleared are not unknown and stay cleared.
    private func payload(for profile: BrowserProfile) throws -> Data {
        let encoded = try JSONEncoder().encode(profile)
        guard let stored = storedPayloads[profile.id],
              let original = try? JSONDecoder().decode(BrowserProfile.self, from: stored),
              let known = try? JSONEncoder().encode(original),
              let unknown = UnknownFields(stored: stored, known: known) else {
            return encoded
        }
        return try unknown.merged(into: encoded)
    }

    /// Removes a Profile's row and its bookkeeping for good, whether it is saved or in the recycle bin.
    public func remove(_ id: UUID) throws {
        try transaction { try deleteRows(id.uuidString, bookkeepingOf: id) }
        forget(id)
    }

    // MARK: Recycle bin

    /// Moves a saved Profile to the recycle bin. Its row, port, seed and browser data stay.
    public func trash(_ id: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileError.invalid("找不到要移到回收站的 Profile。")
        }
        // Rounded the way the column stores it, so the entry equals what a reopened store reads.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970)
        try run("UPDATE profiles SET deleted_at=? WHERE id=?", .real(now.timeIntervalSince1970), .text(id.uuidString))
        let profile = profiles.remove(at: index)
        trashed.insert(TrashedProfile(profile: profile, deletedAt: now), at: 0)
    }

    /// Puts a trashed Profile back in its place among the saved ones.
    public func restore(_ id: UUID) throws {
        guard let index = trashed.firstIndex(where: { $0.id == id }) else {
            throw ProfileError.invalid("回收站中没有这个 Profile。")
        }
        try run("UPDATE profiles SET deleted_at=NULL WHERE id=?", .text(id.uuidString))
        let profile = trashed.remove(at: index).profile
        let order = rowids[id] ?? .max
        let position = profiles.firstIndex { (rowids[$0.id] ?? .max) > order } ?? profiles.endIndex
        profiles.insert(profile, at: position)
    }

    /// Deletes a trashed Profile's row and bookkeeping. Its browser data is the caller's to delete,
    /// with `BrowserRuntime.removeData`.
    public func purge(_ id: UUID) throws {
        guard trashed.contains(where: { $0.id == id }) else {
            throw ProfileError.invalid("回收站中没有这个 Profile。")
        }
        try remove(id)
    }

    /// Trashed Profiles removed at least `days` days before `now`, for the caller to purge.
    public func expiredTrash(olderThan days: Int = 30, now: Date = Date()) -> [UUID] {
        trashed.filter { now.timeIntervalSince($0.deletedAt) >= Double(days) * 86400 }.map(\.id)
    }

    // MARK: Unreadable rows and orphaned data

    /// Deletes a row that could not be read. Export its payload first if it may still be needed.
    public func deleteUnreadable(_ id: String) throws {
        guard unreadableRows.contains(where: { $0.id == id }) else {
            throw ProfileError.invalid("找不到这份无法读取的 Profile。")
        }
        // Bookkeeping keyed by the same UUID belongs to the row unless a readable Profile has that id.
        let uuid = UUID(uuidString: id).flatMap { uuid in
            profiles.contains { $0.id == uuid } || trashed.contains { $0.id == uuid } ? nil : uuid
        }
        try transaction { try deleteRows(id, bookkeepingOf: uuid) }
        unreadableRows.removeAll { $0.id == id }
        if let uuid { forget(uuid) }
    }

    /// Browser data directories under `Profiles/` that no saved, trashed or unreadable row owns,
    /// for example ones left by "仅移除记录".
    public func orphanDataDirectories() -> [UUID] {
        let root = directory.appendingPathComponent("Profiles", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var owned = Set(profiles.map(\.id)).union(trashed.map(\.id))
        owned.formUnion(unreadableRows.compactMap { UUID(uuidString: $0.id) })
        return names.sorted().compactMap { name in
            // The runtime names data directories by the lowercase UUID; anything else is not ours.
            guard let id = UUID(uuidString: name), name == id.uuidString.lowercased(), !owned.contains(id) else { return nil }
            var details = stat()
            guard lstat(root.appendingPathComponent(name).path, &details) == 0,
                  details.st_mode & S_IFMT == S_IFDIR else { return nil }
            return id
        }
    }

    /// Saves a new Profile that keeps an orphaned directory's UUID, so it uses that browser data.
    /// Port, seed and identity are new, chosen as for a new Profile.
    public func adoptOrphan(_ id: UUID) throws -> BrowserProfile {
        guard orphanDataDirectories().contains(id) else {
            throw ProfileError.invalid("找不到这个未关联的浏览器资料目录。")
        }
        var profile = try makeDraft()
        profile.id = id
        profile.name = "恢复的 Profile \(id.uuidString.lowercased().prefix(8))"
        return try saveAll([profile])[0]
    }

    // MARK: Identity reset bookkeeping

    static let pendingResetPrefix = "pendingReset:"
    static let launchFingerprintPrefix = "lastLaunchFingerprint:"

    /// Whether a new identity was saved but the old one's site data has not been cleared yet.
    public func pendingIdentityReset(_ id: UUID) -> Bool {
        pendingResets.contains(id)
    }

    public func setPendingIdentityReset(_ id: UUID, _ pending: Bool) throws {
        if pending, !profiles.contains(where: { $0.id == id }) {
            throw ProfileError.invalid("找不到这个 Profile。")
        }
        try saveSetting(pending ? true : nil, forKey: Self.pendingResetPrefix + id.uuidString)
        if pending { pendingResets.insert(id) } else { pendingResets.remove(id) }
    }

    /// The fingerprint the Profile last launched with, or nil before its first recorded launch.
    public func lastLaunchFingerprint(_ id: UUID) -> FingerprintSettings? {
        launchFingerprints[id]
    }

    /// Records the fingerprint a Profile just launched with. Failing to record never affects the launch.
    public func recordLaunchFingerprint(_ id: UUID, _ fingerprint: FingerprintSettings) {
        guard profiles.contains(where: { $0.id == id }),
              (try? saveSetting(fingerprint, forKey: Self.launchFingerprintPrefix + id.uuidString)) != nil else { return }
        launchFingerprints[id] = fingerprint
    }

    // MARK: Rows

    /// Deletes a row by its id column, and the usage, exit and bookkeeping kept for `uuid`.
    private func deleteRows(_ rowID: String, bookkeepingOf uuid: UUID?) throws {
        try run("DELETE FROM profiles WHERE id=?", .text(rowID))
        guard let uuid else { return }
        try run("DELETE FROM profile_usage WHERE id=?", .text(uuid.uuidString))
        try run("DELETE FROM profile_exits WHERE id=?", .text(uuid.uuidString))
        for prefix in [Self.pendingResetPrefix, Self.launchFingerprintPrefix] {
            try run("DELETE FROM settings WHERE key=?", .text(prefix + uuid.uuidString))
        }
    }

    /// Drops everything kept in memory for a Profile whose row is gone.
    private func forget(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        trashed.removeAll { $0.id == id }
        lastLaunched[id] = nil
        pendingResets.remove(id)
        launchFingerprints[id] = nil
        storedPayloads[id] = nil
        rowids[id] = nil
    }

    enum Binding {
        case text(String), real(Double)
    }

    /// Runs one write statement.
    func run(_ sql: String, _ values: Binding...) throws {
        try requireWritable()
        let write = try statement(sql)
        defer { sqlite3_finalize(write) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let bound: Int32
            switch value {
            case .text(let text): bound = sqlite3_bind_text(write, index, text, -1, transient)
            case .real(let number): bound = sqlite3_bind_double(write, index, number)
            }
            guard bound == SQLITE_OK else { throw databaseError() }
        }
        guard sqlite3_step(write) == SQLITE_DONE else { throw databaseError() }
    }

    /// Runs `body` in one transaction: all of its writes are kept or none is.
    func transaction<Value>(_ body: () throws -> Value) throws -> Value {
        try requireWritable()
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
        do {
            let value = try body()
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
            return value
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Throws when the database belongs to a newer AnyBrowser. Every write checks this first.
    func requireWritable() throws {
        guard !isReadOnly else {
            throw ProfileError.invalid("本机 Profile 数据库由更新版本的 AnyBrowser 写入（数据库版本 \(openedSchemaVersion)），"
                + "当前版本只能查看，不能修改。请升级 AnyBrowser。")
        }
    }

    public func randomize(_ profile: BrowserProfile, fields: Set<FingerprintField>) throws -> BrowserProfile {
        if fields.contains(.platformVersion), !fields.contains(.platform), profile.fingerprint.platform == nil {
            throw ProfileError.invalid("先选择平台，或同时勾选平台与平台版本。")
        }
        if fields.contains(.brandVersion), !fields.contains(.brand), profile.fingerprint.brand == nil {
            throw ProfileError.invalid("先选择浏览器品牌，或同时勾选品牌与品牌版本。")
        }
        var draft = profile
        draft.fingerprint.randomize(fields, excluding: takenSeeds)
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
        guard !isReadOnly, profiles.contains(where: { $0.id == id }) else { return }
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
        try requireWritable()
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

    private func checkForConflicts(_ profile: BrowserProfile, holders: (ports: [Int: Holder], seeds: [Int: Holder])) throws {
        if let holder = holders.ports[profile.port], !holder.owns(profile.id) {
            switch holder {
            case .profile(_, let name): throw ProfileError.invalid("调试端口 \(profile.port) 已分配给 \(name)。")
            case .trashed(_, let name): throw ProfileError.invalid("调试端口 \(profile.port) 已分配给回收站中的 \(name)。")
            case .unreadable: throw ProfileError.invalid("调试端口 \(profile.port) 已被一份无法读取的 Profile 占用。")
            }
        }
        if let holder = holders.seeds[profile.fingerprint.seed], !holder.owns(profile.id) {
            switch holder {
            case .profile(_, let name): throw ProfileError.invalid("指纹种子已分配给 \(name)。")
            case .trashed(_, let name): throw ProfileError.invalid("指纹种子已分配给回收站中的 \(name)。")
            case .unreadable: throw ProfileError.invalid("指纹种子已被一份无法读取的 Profile 占用。")
            }
        }
    }

    /// Schema steps in order. `PRAGMA user_version` records the last one applied; databases from
    /// 0.4.0 and earlier report 0 and already have the tables of step 1. Append new steps; never
    /// edit or reorder applied ones.
    static let migrations: [(version: Int32, sql: String)] = [
        (1, """
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
            """),
        // Recycle bin: a removed Profile keeps its row, port and seed until it is purged.
        (2, "ALTER TABLE profiles ADD COLUMN deleted_at REAL"),
        // Proxy library and the last exit seen for each Profile.
        (3, """
            CREATE TABLE IF NOT EXISTS proxies (
                id TEXT PRIMARY KEY NOT NULL,
                url TEXT NOT NULL,
                label TEXT NOT NULL DEFAULT '',
                tags TEXT NOT NULL DEFAULT '',
                note TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                last_exit BLOB,
                last_checked_at REAL
            );
            CREATE TABLE IF NOT EXISTS profile_exits (
                id TEXT PRIMARY KEY NOT NULL,
                exit BLOB NOT NULL,
                checked_at REAL NOT NULL
            )
            """),
    ]
    static var schemaVersion: Int32 { migrations.last!.version }

    /// The schema version the database reported before this store migrated it.
    public private(set) var openedSchemaVersion: Int32 = 0

    private func userVersion() throws -> Int32 {
        let read = try statement("PRAGMA user_version")
        defer { sqlite3_finalize(read) }
        guard sqlite3_step(read) == SQLITE_ROW else { throw databaseError() }
        return sqlite3_column_int(read, 0)
    }

    /// Whether the file already holds a schema, as opposed to having just been created.
    private func hasTables() throws -> Bool {
        let read = try statement("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table')")
        defer { sqlite3_finalize(read) }
        guard sqlite3_step(read) == SQLITE_ROW else { throw databaseError() }
        return sqlite3_column_int(read, 0) != 0
    }

    /// Applies the steps the database has not seen yet, all in one transaction.
    private func migrate() throws {
        let read = try statement("PRAGMA user_version")
        defer { sqlite3_finalize(read) }
        guard sqlite3_step(read) == SQLITE_ROW else { throw databaseError() }
        let current = sqlite3_column_int(read, 0)
        openedSchemaVersion = current
        let pending = Self.migrations.filter { $0.version > current }
        guard !pending.isEmpty else { return }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
        do {
            for step in pending {
                guard sqlite3_exec(database, step.sql, nil, nil, nil) == SQLITE_OK,
                      sqlite3_exec(database, "PRAGMA user_version = \(step.version)", nil, nil, nil) == SQLITE_OK else {
                    throw databaseError()
                }
            }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &value, nil) == SQLITE_OK, let value else {
            throw databaseError()
        }
        return value
    }

    func databaseError() -> ProfileError {
        .invalid("本机 Profile 数据库操作失败（\(sqlite3_errcode(database))）。")
    }
}

/// The fields of a stored row that disappear when this version decodes and encodes it again:
/// fields a newer version added, at the top level or inside nested objects.
struct UnknownFields {
    private var values: [String: Any] = [:]
    private var nested: [String: UnknownFields] = [:]

    /// nil when re-encoding `stored` as `known` loses nothing.
    init?(stored: Data, known: Data) {
        guard let old = try? JSONSerialization.jsonObject(with: stored) as? [String: Any],
              let new = try? JSONSerialization.jsonObject(with: known) as? [String: Any] else { return nil }
        self.init(old, new)
        if values.isEmpty, nested.isEmpty { return nil }
    }

    private init(_ old: [String: Any], _ new: [String: Any]) {
        for (key, value) in old {
            guard let kept = new[key] else {
                values[key] = value
                continue
            }
            if let object = value as? [String: Any], let keptObject = kept as? [String: Any] {
                let inner = UnknownFields(object, keptObject)
                if !inner.values.isEmpty || !inner.nested.isEmpty { nested[key] = inner }
            }
        }
    }

    /// `encoded` with these fields added wherever it has none of its own.
    func merged(into encoded: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return encoded }
        merge(into: &object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func merge(into object: inout [String: Any]) {
        for (key, value) in values where object[key] == nil {
            object[key] = value
        }
        // An object the user cleared stays cleared; only objects that are still there get their fields back.
        for (key, inner) in nested {
            guard var child = object[key] as? [String: Any] else { continue }
            inner.merge(into: &child)
            object[key] = child
        }
    }
}
