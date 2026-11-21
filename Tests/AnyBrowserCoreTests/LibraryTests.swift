@testable import AnyBrowserCore
import Darwin
import Foundation
import SQLite3
import Testing

/// Every test works in its own directory under /tmp/library.
private func scratchDirectory() throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return ProcessInspection.canonicalURL(url, isDirectory: true)!
}

private func execute(_ sql: String, in directory: URL, binding values: [Any] = []) throws {
    var database: OpaquePointer?
    guard sqlite3_open(directory.appendingPathComponent("profiles.sqlite3").path, &database) == SQLITE_OK else {
        throw ProfileError.invalid("open")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw ProfileError.invalid("prepare") }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in values.enumerated() {
        let index = Int32(offset + 1)
        switch value {
        case let text as String: sqlite3_bind_text(statement, index, text, -1, transient)
        case let number as Int: sqlite3_bind_int64(statement, index, Int64(number))
        case let data as Data: _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
        default: throw ProfileError.invalid("bind")
        }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw ProfileError.invalid("step") }
}

private func rowCount(_ table: String, in directory: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open(directory.appendingPathComponent("profiles.sqlite3").path, &database) == SQLITE_OK else {
        throw ProfileError.invalid("open")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW else { throw ProfileError.invalid("count") }
    defer { sqlite3_finalize(statement) }
    return Int(sqlite3_column_int64(statement, 0))
}

private func message(_ error: Error?) -> String { error?.localizedDescription ?? "" }

@MainActor
struct LibraryTests {
    // MARK: Store

    @Test("Unreadable rows are skipped, kept, and still hold their port and seed")
    func unreadableRowsAreSkipped() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = try ProfileStore(directory: directory).makeDraft()
        try ProfileStore(directory: directory).save(good)

        let invalid = BrowserProfile(name: " ", port: 9223, fingerprint: FingerprintSettings(seed: 4343))
        let mismatched = BrowserProfile(name: "Other", port: 9224, fingerprint: FingerprintSettings(seed: 4444))
        let insert = "INSERT INTO profiles(id, port, seed, payload) VALUES(?, ?, ?, ?)"
        try execute(insert, in: directory, binding: [UUID().uuidString, 9300, 4242, Data([0, 255, 1])])
        try execute(insert, in: directory, binding: [invalid.id.uuidString, 9223, 4343, try JSONEncoder().encode(invalid)])
        try execute(insert, in: directory, binding: [UUID().uuidString, 9224, 4444, try JSONEncoder().encode(mismatched)])

        let store = try ProfileStore(directory: directory)
        #expect(store.profiles == [good])
        #expect(store.unreadableProfiles == 3)
        #expect(store.takenPorts == [good.port, 9223, 9224, 9300])
        #expect(store.takenSeeds == [good.fingerprint.seed, 4242, 4343, 4444])
        #expect(try store.makeDraft().port == 9225)

        var conflicting = try store.makeDraft()
        conflicting.port = 9300
        #expect(message(#expect(throws: ProfileError.self) { try store.save(conflicting) }).contains("无法读取"))
        conflicting.port = 9400
        conflicting.fingerprint.seed = 4242
        #expect(message(#expect(throws: ProfileError.self) { try store.save(conflicting) }).contains("无法读取"))

        #expect(try rowCount("profiles", in: directory) == 4)
        #expect(try ProfileStore(directory: directory).unreadableProfiles == 3)
    }

    @Test("Launch times are recorded, survive reopening and go with the Profile")
    func launchTimes() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let first = try store.makeDraft()
        try store.save(first)
        let second = try store.makeDraft()
        try store.save(second)

        let before = Date()
        store.recordLaunch(first.id)
        store.recordLaunch(UUID())
        let recorded = try #require(store.lastLaunched[first.id])
        #expect(recorded >= before.addingTimeInterval(-1) && recorded <= Date().addingTimeInterval(1))
        #expect(store.lastLaunched.count == 1)

        let reopened = try ProfileStore(directory: directory)
        let stored = try #require(reopened.lastLaunched[first.id])
        #expect(abs(stored.timeIntervalSince(recorded)) < 0.001)
        #expect(reopened.lastLaunched[second.id] == nil)

        try reopened.remove(first.id)
        #expect(reopened.lastLaunched[first.id] == nil)
        #expect(try rowCount("profile_usage", in: directory) == 0)
        #expect(try ProfileStore(directory: directory).lastLaunched.isEmpty)
    }

    // MARK: Import and export

    @Test("Exports leave out passwords unless asked to include them")
    func exportSecrets() throws {
        var profile = BrowserProfile(name: "Shop", port: 9400, fingerprint: FingerprintSettings(seed: 5),
                                     proxy: "http://zq-login:proxy-secret@proxy.example:8080", group: "G", notes: "N")
        profile.passkeyBox = PasskeyBoxAccount(serverURL: "https://pk.example.com", username: "u", password: "passkey-secret")
        var plain = BrowserProfile(name: "Plain", port: 9401, fingerprint: FingerprintSettings(seed: 6),
                                   proxy: "socks5://127.0.0.1:1080")
        plain.launch.startURLs = ["https://example.com/"]

        let without = try ProfileLibrary.export([profile, plain], includeSecrets: false)
        let text = String(decoding: without, as: UTF8.self)
        #expect(!text.contains("proxy-secret") && !text.contains("zq-login") && !text.contains("passkey-secret"))
        let object = try #require(JSONSerialization.jsonObject(with: without) as? [String: Any])
        #expect(object["format"] as? String == "anybrowser-profiles")
        #expect(object["version"] as? Int == 1)
        let entries = try #require(object["profiles"] as? [[String: Any]])
        #expect(entries.count == 2)
        #expect(entries[0]["passkeyBox"] == nil && entries[0]["group"] as? String == "G")
        #expect(entries[1]["proxy"] as? String == "socks5://127.0.0.1:1080")
        #expect(ProfileLibrary.withoutSecrets(plain) == plain)

        let with = String(decoding: try ProfileLibrary.export([profile], includeSecrets: true), as: UTF8.self)
        #expect(with.contains("proxy-secret") && with.contains("passkey-secret"))
    }

    @Test("Imports get new ids, move off taken ports and seeds, and skip invalid entries")
    func importReassignsAndSkips() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let existing = try store.makeDraft()
        try store.save(existing)
        try execute("INSERT INTO profiles(id, port, seed, payload) VALUES(?, ?, ?, ?)", in: directory,
                    binding: [UUID().uuidString, 9500, 5555, Data("{}".utf8)])
        let reopened = try ProfileStore(directory: directory)

        var clash = BrowserProfile(id: existing.id, name: "  Clash  ", port: existing.port,
                                   fingerprint: FingerprintSettings(seed: existing.fingerprint.seed), group: "Imported")
        clash.passkeyBox = PasskeyBoxAccount(serverURL: "pk.example.com", username: "u", password: "p")
        let keep = BrowserProfile(name: "Keep", port: 9400, fingerprint: FingerprintSettings(seed: 77))
        let sameFile = BrowserProfile(name: "Same file", port: 9400, fingerprint: FingerprintSettings(seed: 77))
        let unreadable = BrowserProfile(name: "Unreadable", port: 9500, fingerprint: FingerprintSettings(seed: 5555))
        let badPort = BrowserProfile(name: "Bad port", port: 80, fingerprint: FingerprintSettings(seed: 8))
        var entries = try [clash, keep, sameFile, unreadable, badPort].map {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
        }
        entries.append(["name": 5])
        entries.append("not a profile")
        let file = try JSONSerialization.data(withJSONObject: ["format": "anybrowser-profiles", "version": 1, "profiles": entries])

        let result = try reopened.importProfiles(from: file)
        #expect(result.skipped == 3)
        #expect(result.profiles.map(\.name) == ["Clash", "Keep", "Same file", "Unreadable"])
        let ids = [existing.id, clash.id, keep.id, sameFile.id, unreadable.id]
        #expect(result.profiles.allSatisfy { !ids.contains($0.id) })
        #expect(Set(result.profiles.map(\.id)).count == 4)
        #expect(result.profiles[0].port != existing.port && result.profiles[0].fingerprint.seed != existing.fingerprint.seed)
        #expect(result.profiles[0].group == "Imported")
        #expect(result.profiles[0].passkeyBox?.serverURL == "https://pk.example.com")
        #expect(result.profiles[1].port == 9400 && result.profiles[1].fingerprint.seed == 77)
        #expect(result.profiles[2].port != 9400 && result.profiles[2].fingerprint.seed != 77)
        #expect(result.profiles[3].port != 9500 && result.profiles[3].fingerprint.seed != 5555)
        #expect(Set(result.profiles.map(\.port)).count == 4)
        #expect(try ProfileStore(directory: directory).profiles == [existing] + result.profiles)
    }

    @Test("Exported Profiles import back with every field")
    func exportImportRoundTrip() throws {
        var profile = BrowserProfile(name: "Round", port: 9410, fingerprint: FingerprintSettings(seed: 41),
                                     proxy: "https://proxy.example:443", group: "G", notes: "多行\n备注")
        profile.passkeyBox = PasskeyBoxAccount(serverURL: "https://pk.example.com", username: "u", password: "p")
        profile.launch = LaunchOptions(startURLs: ["https://example.com/"], window: WindowLayout(width: 1280, height: 800))
        profile.fingerprint.platform = .windows
        let data = try ProfileLibrary.export([profile], includeSecrets: true)
        let imported = try ProfileLibrary.importProfiles(from: data, takenPorts: [], takenSeeds: [])
        #expect(imported.skipped == 0)
        var restored = try #require(imported.profiles.first)
        #expect(restored.id != profile.id)
        restored.id = profile.id
        #expect(restored == profile)

        let stripped = try ProfileLibrary.importProfiles(from: ProfileLibrary.export([profile], includeSecrets: false),
                                                         takenPorts: [], takenSeeds: [])
        #expect(stripped.profiles.first?.passkeyBox == nil)
        #expect(stripped.profiles.first?.proxy == "https://proxy.example:443")
    }

    @Test("Imports reject other files and versions")
    func importRejectsOtherFiles() throws {
        func attempt(_ object: Any) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: object)
            return message(#expect(throws: ProfileError.self) {
                try ProfileLibrary.importProfiles(from: data, takenPorts: [], takenSeeds: [])
            })
        }
        #expect(try attempt(["format": "something-else", "version": 1, "profiles": []]).contains("不是 AnyBrowser"))
        #expect(try attempt(["version": 1, "profiles": []]).contains("不是 AnyBrowser"))
        #expect(try attempt([["format": "anybrowser-profiles"]]).contains("不是 AnyBrowser"))
        #expect(try attempt(["format": "anybrowser-profiles", "version": 2, "profiles": []]).contains("版本 2"))
        #expect(try attempt(["format": "anybrowser-profiles", "profiles": []]).contains("版本"))
        #expect(try attempt(["format": "anybrowser-profiles", "version": 1]).contains("缺少"))
        #expect(throws: ProfileError.self) {
            try ProfileLibrary.importProfiles(from: Data("not json".utf8), takenPorts: [], takenSeeds: [])
        }
        let empty = try ProfileLibrary.importProfiles(
            from: JSONSerialization.data(withJSONObject: ["format": "anybrowser-profiles", "version": 1, "profiles": []]),
            takenPorts: [], takenSeeds: [])
        #expect(empty == ProfileLibrary.ImportResult(profiles: [], skipped: 0))
    }

    @Test("Export files are readable only by the current user")
    func exportFilePermissions() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Profiles.json")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data("old".utf8),
                                               attributes: [.posixPermissions: 0o644]))
        try ProfileLibrary.writePrivately(Data("new".utf8), to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Profiles.json"])
    }

    // MARK: Clone and batch

    @Test("Clones keep every setting but get a new id, name, port and seed")
    func cloneFields() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        var original = try store.makeDraft()
        original.name = "店铺"
        original.proxy = "socks5://127.0.0.1:1080"
        original.group = "电商"
        original.notes = "主账号"
        original.passkeyBox = PasskeyBoxAccount(serverURL: "https://pk.example.com", username: "u", password: "p")
        original.launch = LaunchOptions(startURLs: ["https://example.com/"], window: WindowLayout(width: 1200, height: 800))
        original.fingerprint.platform = .windows
        original.fingerprint.language = "en-US"
        try store.save(original)

        let copy = try store.saveClone(of: original.id)
        #expect(copy.id != original.id)
        #expect(copy.name == "店铺 副本")
        #expect(copy.port != original.port && copy.fingerprint.seed != original.fingerprint.seed)
        var same = copy
        same.id = original.id
        same.name = original.name
        same.port = original.port
        same.fingerprint.seed = original.fingerprint.seed
        #expect(same == original)
        #expect(store.profiles == [original, copy])
        #expect(try store.saveClone(of: original.id).name == "店铺 副本 2")

        let long = String(repeating: "长", count: 80)
        let name = ProfileLibrary.copyName(of: long, existing: [])
        #expect(name.count == 80 && name.hasSuffix(" 副本"))
        #expect(throws: ProfileError.self) { try store.saveClone(of: UUID()) }
    }

    @Test("Batch creation numbers names around existing ones and validates before saving")
    func batchCreation() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        for name in ["Profile 1", "Profile 3"] {
            var profile = try store.makeDraft()
            profile.name = name
            try store.save(profile)
        }
        let created = try store.saveBatch(.init(count: 3, prefix: "  ", group: "Shop", proxy: ""))
        #expect(created.map(\.name) == ["Profile 2", "Profile 4", "Profile 5"])
        #expect(created.allSatisfy { $0.group == "Shop" && $0.proxy.isEmpty })
        #expect(Set(store.profiles.map(\.port)).count == 5)
        #expect(Set(store.profiles.map(\.fingerprint.seed)).count == 5)
        #expect(store.profiles.count == 5)

        let named = try ProfileLibrary.batch(.init(count: 2, prefix: "店铺"), existingNames: ["店铺 1"],
                                             takenPorts: [], takenSeeds: [])
        #expect(named.map(\.name) == ["店铺 2", "店铺 3"])
        #expect(named.allSatisfy { $0.proxy == BrowserProfile.defaultProxy && $0.group.isEmpty })

        for request in [ProfileLibrary.BatchRequest(count: 0), .init(count: 51),
                        .init(count: 2, prefix: String(repeating: "p", count: 71)),
                        .init(count: 2, proxy: "not a proxy")] {
            #expect(throws: ProfileError.self) { try store.saveBatch(request) }
        }
        #expect(store.profiles.count == 5)
    }

    // MARK: Sidebar

    @Test("Sidebar search, sorting and group sections")
    func sidebarSections() throws {
        func profile(_ name: String, _ group: String, port: Int, notes: String = "") -> BrowserProfile {
            BrowserProfile(name: name, port: port, fingerprint: FingerprintSettings(seed: port), group: group, notes: notes)
        }
        let beta = profile("Beta", "Shop", port: 9222)
        let alpha = profile("alpha", "", port: 9223, notes: "VIP 客户")
        let gamma = profile("Gamma", "Ads", port: 9300)
        let ten = profile("Profile 10", "Shop", port: 9224)
        let two = profile("Profile 2", "Shop", port: 9225)
        let all = [beta, alpha, gamma, ten, two]

        let created = ProfileLibrary.sections(all, query: "", sort: .created, lastLaunched: [:])
        #expect(created.map(\.group) == ["Ads", "Shop", ""])
        #expect(created[1].profiles == [beta, ten, two])
        #expect(ProfileLibrary.sections(all, query: "", sort: .name, lastLaunched: [:])[1].profiles == [beta, two, ten])
        let now = Date()
        let recent = ProfileLibrary.sections(all, query: "", sort: .recent,
                                             lastLaunched: [two.id: now, beta.id: now.addingTimeInterval(-60)])
        #expect(recent[1].profiles == [two, beta, ten])

        #expect(ProfileLibrary.sections(all, query: " vip ", sort: .created, lastLaunched: [:])
            == [ProfileLibrary.Section(group: "", profiles: [alpha])])
        #expect(ProfileLibrary.sections(all, query: "9300", sort: .created, lastLaunched: [:]).flatMap(\.profiles) == [gamma])
        #expect(ProfileLibrary.sections(all, query: "shop", sort: .created, lastLaunched: [:]).flatMap(\.profiles) == [beta, ten, two])
        #expect(ProfileLibrary.sections(all, query: "nothing", sort: .created, lastLaunched: [:]).isEmpty)
        #expect(ProfileLibrary.groups(all) == ["Ads", "Shop"])
    }
}

// MARK: Removing browser data

/// A runtime whose "engine" is /bin/bash, so a bash process can stand in for a running browser.
@MainActor
private struct DataFixture {
    let root: URL
    let runtime: BrowserRuntime

    init() throws {
        root = try scratchDirectory()
        let storage = root.appendingPathComponent("Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
        let engine = BrowserEngine(version: "test", executable: URL(fileURLWithPath: "/bin/bash"),
                                   passkeyBoxDirectory: storage)
        runtime = BrowserRuntime(engine: engine, storage: storage)
    }

    /// Creates both directories of a Profile with a file in each.
    @discardableResult
    func populate(_ id: UUID) throws -> (data: URL, extensions: URL) {
        let data = runtime.dataDirectory(for: id)
        try runtime.ensureDirectory(data)
        try Data("cookie".utf8).write(to: data.appendingPathComponent("Cookies"))
        let extensions = try ProfileExtensions.prepareRoot(in: runtime.storage, for: id)
        try Data("{}".utf8).write(to: extensions.appendingPathComponent("manifest.json"))
        return (data, extensions)
    }

    /// A process whose arguments name `directory` the way Chromium's do. It exits when stdin closes.
    func standIn(for directory: URL, port: Int) throws -> (process: Process, input: Pipe) {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "read line", "anybrowser-test",
                             "--user-data-dir=\(directory.path)", "--remote-debugging-port=\(port)"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, input)
    }

    func finish(_ standIn: (process: Process, input: Pipe)) {
        try? standIn.input.fileHandleForWriting.close()
        standIn.process.terminate()
        standIn.process.waitUntilExit()
    }

    func exists(_ url: URL) -> Bool {
        var details = stat()
        return lstat(url.path, &details) == 0
    }
}

@MainActor
struct BrowserDataRemovalTests {
    @Test("Removing data deletes only that Profile's two directories, after the record")
    func removesOnlyThisProfile() async throws {
        let fixture = try DataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let other = UUID()
        let target = try fixture.populate(id)
        let kept = try fixture.populate(other)
        let unrelated = fixture.runtime.storage.appendingPathComponent("profiles.sqlite3")
        try Data().write(to: unrelated)

        var order: [String] = []
        try await fixture.runtime.removeData(for: id) {
            order.append(fixture.exists(target.data) ? "record before data" : "record after data")
        }
        #expect(order == ["record before data"])
        #expect(!fixture.exists(target.data) && !fixture.exists(target.extensions))
        #expect(fixture.exists(kept.data.appendingPathComponent("Cookies")))
        #expect(fixture.exists(kept.extensions.appendingPathComponent("manifest.json")))
        #expect(fixture.exists(unrelated))

        // A Profile that never ran has nothing to delete.
        try await fixture.runtime.removeData(for: UUID())
    }

    @Test("Nothing is deleted when removing the record fails")
    func recordFailureKeepsData() async throws {
        let fixture = try DataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let target = try fixture.populate(id)
        await #expect(throws: ProfileError.self) {
            try await fixture.runtime.removeData(for: id) { throw ProfileError.invalid("record") }
        }
        #expect(fixture.exists(target.data.appendingPathComponent("Cookies")))
        #expect(fixture.exists(target.extensions.appendingPathComponent("manifest.json")))
    }

    @Test("A running Profile's data is not deleted")
    func refusesWhileRunning() async throws {
        let fixture = try DataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profile = BrowserProfile(name: "Running", port: 9304, fingerprint: FingerprintSettings(seed: 9304))
        let target = try fixture.populate(profile.id)
        let standIn = try fixture.standIn(for: target.data, port: profile.port)
        defer { fixture.finish(standIn) }
        let pid = standIn.process.processIdentifier
        let details = try fixture.runtime.directoryDetails(target.data)
        let receipt = BrowserRuntime.Receipt(pid: pid, stamp: try #require(ProcessStamp.read(pid)), port: profile.port,
                                             device: details.st_dev, inode: details.st_ino)
        try JSONEncoder().encode(receipt).write(to: fixture.runtime.receiptURL(target.data))
        await fixture.runtime.refresh([profile])
        #expect(fixture.runtime.status(for: profile.id) == .running(pid: pid, port: profile.port, debugReady: false))

        var recordRemoved = false
        let error = await #expect(throws: ProfileError.self) {
            try await fixture.runtime.removeData(for: profile.id) { recordRemoved = true }
        }
        #expect(message(error).contains("停止"))
        #expect(!recordRemoved)
        #expect(fixture.exists(target.data.appendingPathComponent("Cookies")))
        #expect(fixture.exists(target.extensions))
    }

    @Test("Data a browser still holds open is not deleted")
    func refusesWhileInUse() async throws {
        let fixture = try DataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let target = try fixture.populate(id)
        let standIn = try fixture.standIn(for: target.data, port: 9304)
        defer { fixture.finish(standIn) }
        try FileManager.default.createSymbolicLink(atPath: target.data.appendingPathComponent("SingletonLock").path,
                                                   withDestinationPath: "test-host-\(standIn.process.processIdentifier)")
        #expect(fixture.runtime.status(for: id) == .stopped)

        var recordRemoved = false
        let error = await #expect(throws: ProfileError.self) {
            try await fixture.runtime.removeData(for: id) { recordRemoved = true }
        }
        #expect(message(error).contains("正在使用"))
        #expect(!recordRemoved)
        #expect(fixture.exists(target.data.appendingPathComponent("Cookies")))
    }

    @Test("A data directory replaced by a link is not followed")
    func refusesSymbolicLink() async throws {
        let fixture = try DataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("Keep"))
        let data = fixture.runtime.dataDirectory(for: id)
        try fixture.runtime.ensureDirectory(data.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: data, withDestinationURL: outside)

        var recordRemoved = false
        await #expect(throws: ProfileError.self) {
            try await fixture.runtime.removeData(for: id) { recordRemoved = true }
        }
        #expect(!recordRemoved)
        #expect(fixture.exists(data))
        #expect(fixture.exists(outside.appendingPathComponent("Keep")))
    }

    @Test("Data reached through a linked parent outside the storage directory is not deleted")
    func refusesPathOutsideStorage() async throws {
        let fixture = try DataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let elsewhere = fixture.root.appendingPathComponent("Elsewhere", isDirectory: true)
        let victim = elsewhere.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data("keep".utf8).write(to: victim.appendingPathComponent("Keep"))
        try FileManager.default.createSymbolicLink(at: fixture.runtime.storage.appendingPathComponent("Extensions"),
                                                   withDestinationURL: elsewhere)

        var recordRemoved = false
        let error = await #expect(throws: ProfileError.self) {
            try await fixture.runtime.removeData(for: id) { recordRemoved = true }
        }
        #expect(message(error).contains("路径异常"))
        #expect(!recordRemoved)
        #expect(fixture.exists(victim.appendingPathComponent("Keep")))
    }

    @Test("A file where the data directory should be is not deleted")
    func refusesRegularFile() async throws {
        let fixture = try DataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let data = fixture.runtime.dataDirectory(for: id)
        try fixture.runtime.ensureDirectory(data.deletingLastPathComponent())
        try Data("file".utf8).write(to: data)
        await #expect(throws: ProfileError.self) { try await fixture.runtime.removeData(for: id) }
        #expect(fixture.exists(data))
    }
}
