@testable import AnyBrowserCore
import Darwin
import Foundation
import SQLite3

import Testing

// MARK: Raw database access, as another version or process would see the file

private func databaseURL(_ directory: URL) -> URL { directory.appendingPathComponent("profiles.sqlite3") }

private func withDatabase<Value>(_ directory: URL, _ body: (OpaquePointer) throws -> Value) throws -> Value {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL(directory).path, &database) == SQLITE_OK, let database else {
        throw ProfileError.invalid("open")
    }
    defer { sqlite3_close(database) }
    return try body(database)
}

private func exec(_ sql: String, in directory: URL) throws {
    try withDatabase(directory) { database in
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw ProfileError.invalid(String(cString: sqlite3_errmsg(database)))
        }
    }
}

private func scalar(_ sql: String, in directory: URL) throws -> Int64 {
    try withDatabase(directory) { database in
        var read: OpaquePointer?
        defer { sqlite3_finalize(read) }
        guard sqlite3_prepare_v2(database, sql, -1, &read, nil) == SQLITE_OK, sqlite3_step(read) == SQLITE_ROW else {
            throw ProfileError.invalid("scalar")
        }
        return sqlite3_column_int64(read, 0)
    }
}

private func columns(_ table: String, in directory: URL) throws -> [String] {
    try withDatabase(directory) { database in
        var read: OpaquePointer?
        defer { sqlite3_finalize(read) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &read, nil) == SQLITE_OK else {
            throw ProfileError.invalid("columns")
        }
        var names: [String] = []
        while sqlite3_step(read) == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(read, 1))) }
        return names
    }
}

private func insertRow(_ id: String, port: Int, seed: Int, payload: Data, in directory: URL) throws {
    try withDatabase(directory) { database in
        var write: OpaquePointer?
        defer { sqlite3_finalize(write) }
        guard sqlite3_prepare_v2(database, "INSERT INTO profiles(id, port, seed, payload) VALUES(?, ?, ?, ?)", -1, &write, nil) == SQLITE_OK,
              sqlite3_bind_text(write, 1, id, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_bind_int64(write, 2, Int64(port)) == SQLITE_OK,
              sqlite3_bind_int64(write, 3, Int64(seed)) == SQLITE_OK,
              payload.withUnsafeBytes({ sqlite3_bind_blob(write, 4, $0.baseAddress, Int32($0.count), sqliteTransient) }) == SQLITE_OK,
              sqlite3_step(write) == SQLITE_DONE else { throw ProfileError.invalid("insert") }
    }
}

private func storedPayload(_ id: String, in directory: URL) throws -> Data {
    try withDatabase(directory) { database in
        var read: OpaquePointer?
        defer { sqlite3_finalize(read) }
        guard sqlite3_prepare_v2(database, "SELECT payload FROM profiles WHERE id=?", -1, &read, nil) == SQLITE_OK,
              sqlite3_bind_text(read, 1, id, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_step(read) == SQLITE_ROW else { throw ProfileError.invalid("payload") }
        return Data(bytes: sqlite3_column_blob(read, 0), count: Int(sqlite3_column_bytes(read, 0)))
    }
}

private func storedObject(_ id: UUID, in directory: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: storedPayload(id.uuidString, in: directory)) as? [String: Any])
}

private func setStoredObject(_ object: [String: Any], for id: UUID, in directory: URL) throws {
    let payload = try JSONSerialization.data(withJSONObject: object)
    try withDatabase(directory) { database in
        var write: OpaquePointer?
        defer { sqlite3_finalize(write) }
        guard sqlite3_prepare_v2(database, "UPDATE profiles SET payload=? WHERE id=?", -1, &write, nil) == SQLITE_OK,
              payload.withUnsafeBytes({ sqlite3_bind_blob(write, 1, $0.baseAddress, Int32($0.count), sqliteTransient) }) == SQLITE_OK,
              sqlite3_bind_text(write, 2, id.uuidString, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_step(write) == SQLITE_DONE else { throw ProfileError.invalid("update") }
    }
}

private func settingKeys(in directory: URL) throws -> [String] {
    try withDatabase(directory) { database in
        var read: OpaquePointer?
        defer { sqlite3_finalize(read) }
        guard sqlite3_prepare_v2(database, "SELECT key FROM settings ORDER BY key", -1, &read, nil) == SQLITE_OK else {
            throw ProfileError.invalid("keys")
        }
        var keys: [String] = []
        while sqlite3_step(read) == SQLITE_ROW { keys.append(String(cString: sqlite3_column_text(read, 0))) }
        return keys
    }
}

/// The tables and rows a 0.4.0 AnyBrowser leaves behind: no user_version, no deleted_at column.
private func legacyDatabase(in directory: URL) throws -> (shop: UUID, old: UUID) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try exec("""
        CREATE TABLE IF NOT EXISTS profiles (id TEXT PRIMARY KEY NOT NULL, port INTEGER NOT NULL UNIQUE,
            seed INTEGER NOT NULL UNIQUE, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS profile_usage (id TEXT PRIMARY KEY NOT NULL, last_launched_at REAL NOT NULL)
        """, in: directory)
    let shop = UUID()
    let old = UUID()
    let shopPayload = #"""
        {"id":"\#(shop.uuidString)","name":"Shop","port":9222,"proxy":"socks5://127.0.0.1:1080","group":"电商","notes":"主账号",
         "fingerprint":{"seed":101,"platform":"windows","platformVersion":"19.0.0","brand":"Chrome","brandVersion":"148.0.7778.215",
           "cpuCount":8,"language":"en-US","languages":["en-US","en"],"timeZone":"America/New_York",
           "adjustments":["canvas","clientrects","gpu"],"screenWidth":1920,"screenHeight":1080,"availWidth":1920,
           "availHeight":1040,"colorDepth":24,"deviceScaleFactor":1,"deviceMemory":8,"touch":false,"fontProfile":"windows11"},
         "launch":{"startURLs":["https://example.com/"],"extensionDirectories":[],"window":{"width":1280,"height":800}}}
        """#
    let oldPayload = #"{"id":"\#(old.uuidString)","name":"Old","port":9223,"fingerprint":{"seed":102,"platformVersion":"","brandVersion":"","language":"","timeZone":"","adjustments":["canvas"]}}"#
    try insertRow(shop.uuidString, port: 9222, seed: 101, payload: Data(shopPayload.utf8), in: directory)
    try insertRow(old.uuidString, port: 9223, seed: 102, payload: Data(oldPayload.utf8), in: directory)
    try exec("""
        INSERT INTO settings(key, value) VALUES('passkeyBox', CAST('{"serverURL":"https://pk.example.com","username":"u","password":"p"}' AS BLOB));
        INSERT INTO profile_usage(id, last_launched_at) VALUES('\(shop.uuidString)', 1700000000)
        """, in: directory)
    return (shop, old)
}

private func message(_ error: Error?) -> String { error?.localizedDescription ?? "" }

@MainActor
struct StoreTests {
    // MARK: Schema

    @Test("A 0.4.0 database is backed up, then upgraded with every row intact")
    func upgradesLegacyDatabase() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids = try legacyDatabase(in: directory)
        let shopBefore = try storedPayload(ids.shop.uuidString, in: directory)

        let store = try ProfileStore(directory: directory)
        #expect(store.openedSchemaVersion == 0)
        #expect(!store.isReadOnly)
        #expect(store.profiles.map(\.id) == [ids.shop, ids.old])
        #expect(store.unreadableRows.isEmpty)
        let shop = store.profiles[0]
        #expect(shop == (try JSONDecoder().decode(BrowserProfile.self, from: shopBefore)))
        #expect(shop.fingerprint.platform == .windows && shop.fingerprint.fontProfile == .windows11)
        #expect(shop.group == "电商" && shop.launch.window == WindowLayout(width: 1280, height: 800))
        #expect(shop.tags.isEmpty && shop.accountStatus == nil && shop.launch.loadPasskeyBox)
        #expect(store.profiles[1].fingerprint.adjustments == [.canvas] && store.profiles[1].proxy == BrowserProfile.defaultProxy)
        #expect(store.passkeyBoxAccount?.serverURL == "https://pk.example.com")
        #expect(store.lastLaunched[ids.shop] == Date(timeIntervalSince1970: 1_700_000_000))

        #expect(try scalar("PRAGMA user_version", in: directory) == Int64(ProfileStore.schemaVersion))
        #expect(try columns("profiles", in: directory).contains("deleted_at"))
        #expect(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('proxies', 'profile_exits')", in: directory) == 2)
        #expect(try storedPayload(ids.shop.uuidString, in: directory) == shopBefore)

        // The backup is the database exactly as 0.4.0 left it.
        let backups = store.backups()
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(backup.lastPathComponent.hasSuffix("-upgrade.sqlite3"))
        #expect(try permissions(backup) == 0o600)
        #expect(try permissions(backup.deletingLastPathComponent()) == 0o700)
        let copy = try scratchDirectory("store-backup")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: backup, to: databaseURL(copy))
        #expect(try scalar("PRAGMA user_version", in: copy) == 0)
        #expect(try !columns("profiles", in: copy).contains("deleted_at"))
        #expect(try scalar("SELECT COUNT(*) FROM profiles", in: copy) == 2)
        #expect(try storedPayload(ids.shop.uuidString, in: copy) == shopBefore)

        // Nothing left to migrate, and today's backup exists: reopening makes no new one.
        let reopened = try ProfileStore(directory: directory)
        #expect(reopened.openedSchemaVersion == ProfileStore.schemaVersion)
        #expect(reopened.profiles == store.profiles)
        #expect(reopened.backups() == backups)
    }

    @Test("A migration that fails part way leaves the database as it was")
    func failedMigrationRollsBack() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids = try legacyDatabase(in: directory)
        // Step 2 adds deleted_at; step 3 then fails on the name the index already took.
        try exec("CREATE INDEX proxies ON profiles(port)", in: directory)
        let before = try storedPayload(ids.shop.uuidString, in: directory)

        #expect(throws: ProfileError.self) { try ProfileStore(directory: directory) }
        #expect(try scalar("PRAGMA user_version", in: directory) == 0)
        #expect(try !columns("profiles", in: directory).contains("deleted_at"))
        #expect(try scalar("SELECT COUNT(*) FROM profiles", in: directory) == 2)
        #expect(try storedPayload(ids.shop.uuidString, in: directory) == before)
        #expect(ProfileStore.backups(in: directory).count == 1)

        try exec("DROP INDEX proxies", in: directory)
        #expect(try ProfileStore(directory: directory).profiles.count == 2)
    }

    @Test("A database written by a newer version is read but never written")
    func newerDatabaseIsReadOnly() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved: BrowserProfile
        do {
            let store = try ProfileStore(directory: directory)
            saved = try store.makeDraft()
            try store.save(saved)
        }
        let backupsBefore = ProfileStore.backups(in: directory)
        try exec("PRAGMA user_version = 9", in: directory)
        let before = try Data(contentsOf: databaseURL(directory))

        let store = try ProfileStore(directory: directory)
        #expect(store.isReadOnly)
        #expect(store.openedSchemaVersion == 9)
        #expect(store.profiles == [saved])
        var edited = saved
        edited.name = "Edited"
        let refusals: [() throws -> Void] = [
            { try store.save(edited) },
            { _ = try store.saveAll([edited]) },
            { _ = try store.update([saved.id]) { $0.group = "G" } },
            { try store.remove(saved.id) },
            { try store.trash(saved.id) },
            { try store.setPendingIdentityReset(saved.id, true) },
            { try store.savePasskeyBoxAccount(PasskeyBoxAccount(username: "u", password: "p")) },
            { try store.saveSetting("x", forKey: "anything") },
            { _ = try store.saveBatch(.init(count: 1)) },
            { _ = try store.saveClone(of: saved.id) },
            { _ = try store.importProfiles(from: ProfileLibrary.export([edited], includeSecrets: false)) },
        ]
        for refusal in refusals {
            #expect(message(#expect(throws: ProfileError.self) { try refusal() }).contains("更新版本"))
        }
        store.recordLaunch(saved.id)
        store.recordLaunchFingerprint(saved.id, saved.fingerprint)
        #expect(store.lastLaunched.isEmpty && store.lastLaunchFingerprint(saved.id) == nil)
        #expect(store.profiles == [saved])

        // SQLite refuses too, for code that writes through the store's connection directly.
        let direct = try store.statement("DELETE FROM profiles")
        defer { sqlite3_finalize(direct) }
        #expect(sqlite3_step(direct) == SQLITE_READONLY)

        #expect(try Data(contentsOf: databaseURL(directory)) == before)
        #expect(ProfileStore.backups(in: directory) == backupsBefore)
    }

    // MARK: Lenient loading

    @Test("Fields a newer version added survive saving here, and cleared fields stay cleared")
    func unknownFieldsSurviveSaving() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        var profile: BrowserProfile
        do {
            let store = try ProfileStore(directory: directory)
            profile = try store.makeDraft()
            profile.launch.window = WindowLayout(width: 1280, height: 800)
            try store.save(profile)
        }
        var object = try storedObject(profile.id, in: directory)
        object["futureTopLevel"] = ["nested": [1, 2]]
        object["accountStatus"] = "warming"
        var fingerprint = try #require(object["fingerprint"] as? [String: Any])
        fingerprint["webglVendor"] = "Vendor"
        object["fingerprint"] = fingerprint
        var launch = try #require(object["launch"] as? [String: Any])
        launch["futureLaunch"] = true
        var window = try #require(launch["window"] as? [String: Any])
        window["maximized"] = true
        launch["window"] = window
        object["launch"] = launch
        try setStoredObject(object, for: profile.id, in: directory)

        let store = try ProfileStore(directory: directory)
        var loaded = try #require(store.profiles.first)
        #expect(loaded.accountStatus == nil)
        loaded.name = "Renamed"
        loaded.notes = "edited"
        try store.save(loaded)
        var written = try storedObject(profile.id, in: directory)
        #expect(written["name"] as? String == "Renamed")
        #expect((written["futureTopLevel"] as? [String: Any])?["nested"] as? [Int] == [1, 2])
        #expect(written["accountStatus"] as? String == "warming")
        #expect((written["fingerprint"] as? [String: Any])?["webglVendor"] as? String == "Vendor")
        let writtenLaunch = try #require(written["launch"] as? [String: Any])
        #expect(writtenLaunch["futureLaunch"] as? Bool == true)
        #expect((writtenLaunch["window"] as? [String: Any])?["maximized"] as? Bool == true)

        // A status set here replaces the newer one; a window removed here does not come back.
        loaded.accountStatus = .banned
        loaded.launch.window = nil
        _ = try store.update([loaded.id]) { $0 = loaded }
        written = try storedObject(profile.id, in: directory)
        #expect(written["accountStatus"] as? String == "banned")
        #expect((written["launch"] as? [String: Any])?["window"] == nil)
        #expect((written["launch"] as? [String: Any])?["futureLaunch"] as? Bool == true)
        #expect(written["futureTopLevel"] != nil)
        #expect(try ProfileStore(directory: directory).profiles == store.profiles)
    }

    @Test("Rows this version cannot use are listed with the reason and kept as written")
    func unreadableRowsKeepReasonAndPayload() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        var good: BrowserProfile
        var rows: [(id: UUID, port: Int, seed: Int, object: [String: Any])] = []
        do {
            let store = try ProfileStore(directory: directory)
            good = try store.makeDraft()
            try store.save(good)
            for port in 9300...9303 {
                let profile = BrowserProfile(name: "P\(port)", port: port, fingerprint: FingerprintSettings(seed: port))
                rows.append((profile.id, port, port, try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])))
            }
        }
        func with(_ index: Int, fingerprint key: String, _ value: Any) -> [String: Any] {
            var object = rows[index].object
            var fingerprint = object["fingerprint"] as! [String: Any]
            fingerprint[key] = value
            object["fingerprint"] = fingerprint
            return object
        }
        let newer = [
            with(0, fingerprint: "adjustments", ["canvas", "webgpu"]),
            with(1, fingerprint: "fontProfile", "macos27"),
            with(2, fingerprint: "platform", "android"),
            with(3, fingerprint: "timeZone", "Mars/Olympus"),
        ]
        for (index, object) in newer.enumerated() {
            try insertRow(rows[index].id.uuidString, port: rows[index].port, seed: rows[index].seed,
                          payload: JSONSerialization.data(withJSONObject: object), in: directory)
        }
        let missingID = UUID().uuidString
        try insertRow(missingID, port: 9310, seed: 9310, payload: Data(#"{"name":"x"}"#.utf8), in: directory)
        try insertRow(UUID().uuidString, port: 9311, seed: 9311, payload: Data([0, 255]), in: directory)
        // Only the seed is required inside the fingerprint: older and newer rows may lack the rest.
        let sparse = UUID()
        try insertRow(sparse.uuidString, port: 9312, seed: 77,
                      payload: Data(#"{"id":"\#(sparse.uuidString)","name":"Sparse","port":9312,"fingerprint":{"seed":77}}"#.utf8),
                      in: directory)
        let payloads = try rows.map { try storedPayload($0.id.uuidString, in: directory) }

        let store = try ProfileStore(directory: directory)
        #expect(store.profiles.map(\.id) == [good.id, sparse])
        #expect(store.profiles[1].fingerprint.adjustments == [.canvas, .clientRects])
        #expect(store.unreadableRows.map(\.reason) == [
            "由更新版本写入：未知取值 webgpu",
            "由更新版本写入：未知取值 macos27",
            "由更新版本写入：未知取值 android",
            "配置未通过校验：输入 IANA 时区，例如 Asia/Shanghai 或 UTC。",
            "缺少字段 id。",
            "配置不是有效的 JSON。",
        ])
        #expect(store.unreadableProfiles == 6)
        #expect(Array(store.unreadableRows.prefix(4).map(\.payload)) == payloads)
        #expect(store.unreadableRows[0].id == rows[0].id.uuidString)
        #expect(store.unreadableRows[0].port == 9300 && store.unreadableRows[0].seed == 9300)
        #expect(store.takenPorts.isSuperset(of: [9300, 9301, 9302, 9303, 9310, 9311]))

        // A Profile with the same id must not overwrite the row this version cannot read.
        var clash = BrowserProfile(id: rows[0].id, name: "Clash", port: 9400, fingerprint: FingerprintSettings(seed: 9400))
        clash.fingerprint.adjustments = [.canvas]
        #expect(message(#expect(throws: ProfileError.self) { try store.save(clash) }).contains("无法读取"))
        #expect(try storedPayload(rows[0].id.uuidString, in: directory) == payloads[0])

        try store.deleteUnreadable(missingID)
        #expect(store.unreadableRows.count == 5 && !store.takenPorts.contains(9310))
        #expect(throws: ProfileError.self) { try store.deleteUnreadable(good.id.uuidString) }
        #expect(throws: ProfileError.self) { try store.deleteUnreadable("nothing") }
        let reopened = try ProfileStore(directory: directory)
        #expect(reopened.unreadableRows == store.unreadableRows)
        #expect(reopened.profiles.map(\.id) == [good.id, sparse])
    }

    // MARK: Recycle bin

    @Test("Trashed Profiles keep their port and seed, restore in place and purge with their bookkeeping")
    func recycleBin() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let created = try store.saveBatch(.init(count: 3))
        let (first, middle, last) = (created[0], created[1], created[2])
        try store.setPendingIdentityReset(middle.id, true)
        store.recordLaunch(middle.id)
        store.recordLaunchFingerprint(middle.id, middle.fingerprint)

        let before = Date()
        try store.trash(middle.id)
        #expect(store.profiles == [first, last])
        #expect(store.trashed.map(\.profile) == [middle])
        let deletedAt = try #require(store.trashed.first?.deletedAt)
        #expect(deletedAt >= before.addingTimeInterval(-1) && deletedAt <= Date().addingTimeInterval(1))
        #expect(store.takenPorts.contains(middle.port) && store.takenSeeds.contains(middle.fingerprint.seed))
        #expect(try store.makeDraft().port != middle.port)
        var taker = try store.makeDraft()
        taker.port = middle.port
        #expect(message(#expect(throws: ProfileError.self) { try store.save(taker) }).contains("回收站"))
        taker = try store.makeDraft()
        taker.fingerprint.seed = middle.fingerprint.seed
        #expect(message(#expect(throws: ProfileError.self) { try store.save(taker) }).contains("回收站"))
        #expect(message(#expect(throws: ProfileError.self) { try store.save(middle) }).contains("回收站"))
        #expect(throws: ProfileError.self) { try store.trash(middle.id) }
        #expect(throws: ProfileError.self) { try store.purge(first.id) }

        let reopened = try ProfileStore(directory: directory)
        #expect(reopened.profiles == [first, last])
        #expect(reopened.trashed == store.trashed)
        #expect(reopened.pendingIdentityReset(middle.id))

        try reopened.restore(middle.id)
        #expect(reopened.profiles == [first, middle, last])
        #expect(reopened.trashed.isEmpty)
        #expect(throws: ProfileError.self) { try reopened.restore(middle.id) }
        #expect(try ProfileStore(directory: directory).profiles == [first, middle, last])

        try reopened.trash(middle.id)
        try reopened.purge(middle.id)
        #expect(reopened.trashed.isEmpty && !reopened.takenPorts.contains(middle.port))
        #expect(!reopened.pendingIdentityReset(middle.id) && reopened.lastLaunchFingerprint(middle.id) == nil)
        #expect(reopened.lastLaunched[middle.id] == nil)
        #expect(try scalar("SELECT COUNT(*) FROM profiles", in: directory) == 2)
        #expect(try scalar("SELECT COUNT(*) FROM profile_usage", in: directory) == 0)
        #expect(try settingKeys(in: directory).isEmpty)
    }

    @Test("Trash expires after the given number of days")
    func expiredTrash() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let created = try store.saveBatch(.init(count: 2))
        try store.trash(created[0].id)
        try store.trash(created[1].id)
        let older = try #require(store.trashed.last)
        let newer = try #require(store.trashed.first)
        #expect(newer.id == created[1].id)
        let day: TimeInterval = 86400
        #expect(store.expiredTrash(now: older.deletedAt.addingTimeInterval(29 * day)).isEmpty)
        #expect(store.expiredTrash(now: newer.deletedAt.addingTimeInterval(30 * day)).count == 2)
        #expect(store.expiredTrash(olderThan: 7, now: older.deletedAt.addingTimeInterval(7 * day)) == [older.id])
        #expect(store.expiredTrash(olderThan: 0).count == 2)
    }

    // MARK: Orphaned data

    @Test("Data directories without a record are found and adopted under their UUID")
    func orphanedDirectories() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let created = try store.saveBatch(.init(count: 2))
        try store.trash(created[1].id)
        let unreadable = UUID()
        try insertRow(unreadable.uuidString, port: 9500, seed: 9500, payload: Data("{}".utf8), in: directory)
        let reopened = try ProfileStore(directory: directory)

        let root = directory.appendingPathComponent("Profiles", isDirectory: true)
        let orphan = UUID()
        for id in [created[0].id, created[1].id, unreadable, orphan] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(id.uuidString.lowercased()),
                                                    withIntermediateDirectories: true)
        }
        // Not data directories the runtime would use: other spellings, files and links.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(UUID().uuidString.lowercased()))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(UUID().uuidString.lowercased()),
                                                   withDestinationURL: root.appendingPathComponent("Notes"))

        #expect(reopened.orphanDataDirectories() == [orphan])
        let taken = (ports: reopened.takenPorts, seeds: reopened.takenSeeds)
        let adopted = try reopened.adoptOrphan(orphan)
        #expect(adopted.id == orphan)
        #expect(adopted.name == "恢复的 Profile \(orphan.uuidString.lowercased().prefix(8))")
        #expect(!taken.ports.contains(adopted.port) && !taken.seeds.contains(adopted.fingerprint.seed))
        #expect(reopened.profiles.last == adopted)
        #expect(reopened.orphanDataDirectories().isEmpty)
        #expect(throws: ProfileError.self) { try reopened.adoptOrphan(orphan) }
        #expect(throws: ProfileError.self) { try reopened.adoptOrphan(created[0].id) }
        #expect(try ProfileStore(directory: directory).profiles.map(\.id) == [created[0].id, orphan])
    }

    // MARK: Bookkeeping

    @Test("Identity reset bookkeeping is kept in settings and goes with the Profile")
    func identityResetBookkeeping() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let profile = try store.makeDraft()
        try store.save(profile)
        #expect(!store.pendingIdentityReset(profile.id) && store.lastLaunchFingerprint(profile.id) == nil)

        try store.setPendingIdentityReset(profile.id, true)
        store.recordLaunchFingerprint(profile.id, profile.fingerprint)
        store.recordLaunchFingerprint(UUID(), profile.fingerprint)
        #expect(throws: ProfileError.self) { try store.setPendingIdentityReset(UUID(), true) }
        #expect(try settingKeys(in: directory) == [
            "lastLaunchFingerprint:\(profile.id.uuidString)", "pendingReset:\(profile.id.uuidString)",
        ])
        let reopened = try ProfileStore(directory: directory)
        #expect(reopened.pendingIdentityReset(profile.id))
        #expect(reopened.lastLaunchFingerprint(profile.id) == profile.fingerprint)

        try reopened.setPendingIdentityReset(profile.id, false)
        #expect(!reopened.pendingIdentityReset(profile.id))
        #expect(try settingKeys(in: directory) == ["lastLaunchFingerprint:\(profile.id.uuidString)"])
        try reopened.setPendingIdentityReset(profile.id, true)
        try reopened.remove(profile.id)
        #expect(try settingKeys(in: directory).isEmpty)
        #expect(!reopened.pendingIdentityReset(profile.id) && reopened.lastLaunchFingerprint(profile.id) == nil)
    }

    // MARK: Transactions

    @Test("Batch updates save every changed Profile or none, and name the one that failed")
    func batchUpdate() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        var created = try store.saveBatch(.init(count: 4))
        try store.trash(created[3].id)
        created[0].group = "Shop"
        try store.save(created[0])

        let updated = try store.update(created.map(\.id) + [UUID(), created[1].id]) {
            $0.group = "Shop"
            $0.tags = [" vip ", "VIP", "new"]
            $0.accountStatus = .verifying
        }
        #expect(updated.map(\.id) == [created[0].id, created[1].id, created[2].id])
        #expect(updated.allSatisfy { $0.group == "Shop" && $0.tags == ["vip", "new"] && $0.accountStatus == .verifying })
        #expect(store.profiles == updated)
        #expect(store.trashed.first?.profile.group == "")
        #expect(try store.update(created.map(\.id)) { $0.group = "Shop" }.isEmpty)

        let before = store.profiles
        let failure = #expect(throws: ProfileError.self) {
            try store.update(before.map(\.id)) { profile in
                if profile.id == before[1].id { profile.tags = ["a,b"] } else { profile.group = "Other" }
            }
        }
        #expect(message(failure).hasPrefix("\(before[1].name)："))
        #expect(store.profiles == before)

        try exec("""
            CREATE TRIGGER third_fails BEFORE UPDATE ON profiles WHEN NEW.id = '\(before[2].id.uuidString)'
            BEGIN SELECT RAISE(ABORT, 'full'); END
            """, in: directory)
        #expect(throws: ProfileError.self) { try store.update(before.map(\.id)) { $0.notes = "changed" } }
        #expect(store.profiles == before)
        #expect(try ProfileStore(directory: directory).profiles == before)
    }

    // MARK: Backups

    @Test("Backups are private, made daily when the store opens and kept to the newest ten")
    func dailyBackupsAndRetention() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try ProfileStore(directory: directory)
            #expect(store.backups().isEmpty)
            try store.save(try store.makeDraft())
        }
        // A day's first opening with data makes one; the next opening the same day does not.
        let first = try ProfileStore(directory: directory).backups()
        try #require(first.count == 1)
        #expect(first[0].lastPathComponent.hasSuffix("-daily.sqlite3"))
        #expect(try ProfileStore(directory: directory).backups() == first)

        let old = first[0].deletingLastPathComponent().appendingPathComponent("profiles-20200101-000000-000-daily.sqlite3")
        try FileManager.default.moveItem(at: first[0], to: old)
        let store = try ProfileStore(directory: directory)
        #expect(store.backups().count == 2 && store.backups().last == old)
        #expect(store.backupFailure == nil)

        var made: [URL] = []
        for index in 0..<12 { made.append(try store.backup(reason: index == 0 ? "手动 Backup!" : "manual")) }
        #expect(made[0].lastPathComponent.hasSuffix("-" + "---backup-.sqlite3"))
        let kept = store.backups()
        #expect(kept.count == ProfileStore.keptBackups)
        #expect(kept == Array(made.suffix(10).reversed()))
        for url in kept { #expect(try permissions(url) == 0o600) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: old.deletingLastPathComponent().path).count == 10)
    }

    @Test("Restoring a backup swaps the database in and keeps the one it replaces")
    func restoreBackup() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first: BrowserProfile
        let backup: URL
        do {
            let store = try ProfileStore(directory: directory)
            first = try store.makeDraft()
            try store.save(first)
            backup = try store.backup(reason: "manual")
            try store.save(try store.makeDraft())
        }
        // A journal of the database being replaced must not be rolled into the restored one.
        try Data(repeating: 0x41, count: 512).write(to: URL(fileURLWithPath: databaseURL(directory).path + "-journal"))
        try ProfileStore.restoreBackup(backup, into: directory)
        #expect(!FileManager.default.fileExists(atPath: databaseURL(directory).path + "-journal"))
        #expect(try permissions(databaseURL(directory)) == 0o600)
        let store = try ProfileStore(directory: directory)
        #expect(store.profiles == [first])
        let replaced = try #require(store.backups().first { $0.lastPathComponent.hasSuffix("-replaced.sqlite3") })
        let copy = try scratchDirectory("store-replaced")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: replaced, to: databaseURL(copy))
        #expect(try scalar("SELECT COUNT(*) FROM profiles", in: copy) == 2)
    }

    @Test("A damaged database is kept byte for byte when a backup replaces it")
    func restoreOverDamagedDatabase() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved: BrowserProfile
        let backup: URL
        do {
            let store = try ProfileStore(directory: directory)
            saved = try store.makeDraft()
            try store.save(saved)
            backup = try store.backup(reason: "manual")
        }
        let damaged = Data(repeating: 0x41, count: 8192)
        try damaged.write(to: databaseURL(directory))
        #expect(throws: ProfileError.self) { try ProfileStore(directory: directory) }

        // A file that is not a database is refused, and nothing changes.
        let bogus = directory.appendingPathComponent("bogus.sqlite3")
        try Data("not a database".utf8).write(to: bogus)
        #expect(throws: ProfileError.self) { try ProfileStore.restoreBackup(bogus, into: directory) }
        #expect(try Data(contentsOf: databaseURL(directory)) == damaged)
        #expect(ProfileStore.backups(in: directory) == [backup])

        // Left by a crash; it goes into the kept copy, not next to the restored database.
        let journal = URL(fileURLWithPath: databaseURL(directory).path + "-journal")
        try Data(repeating: 0x42, count: 512).write(to: journal)
        try ProfileStore.restoreBackup(backup, into: directory)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(try ProfileStore(directory: directory).profiles == [saved])
        let replaced = try #require(ProfileStore.backups(in: directory).first { $0.lastPathComponent.hasSuffix("-replaced.sqlite3") })
        #expect(try Data(contentsOf: replaced) == damaged)
        #expect(try Data(contentsOf: URL(fileURLWithPath: replaced.path + "-journal")) == Data(repeating: 0x42, count: 512))
        #expect(try permissions(replaced) == 0o600)
    }

    // MARK: Single instance

    @Test("Only one holder of the instance lock at a time, and browsers it starts do not inherit it")
    func instanceLock() throws {
        let directory = try scratchDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        var lock: InstanceLock? = try ProfileStore.acquireInstanceLock(in: directory)
        #expect(lock != nil)
        #expect(try permissions(directory.appendingPathComponent(".instance.lock")) == 0o600)
        #expect(message(#expect(throws: ProfileError.self) { try ProfileStore.acquireInstanceLock(in: directory) })
            .contains("已经在运行"))

        // A child started while the lock is held must not keep it once this holder lets go.
        var pid: pid_t = 0
        let arguments = ["/bin/sleep", "30"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        #expect(posix_spawn(&pid, "/bin/sleep", nil, nil, &argv, &environment) == 0)
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        lock = nil
        lock = try ProfileStore.acquireInstanceLock(in: directory)
        #expect(lock != nil)
    }
}
