@testable import AnyBrowserCore
import Foundation
import SQLite3
import Testing

@Suite("Proxy library")
@MainActor
struct ProxyLibraryTests {
    @Test("Pasted lists are read line by line, normalized and deduplicated")
    func parsesLists() {
        let text = """
        # residential pool
        gate.example.com:7777:user-1:pass

          http://user-1:pass@GATE.example.com:7777/
        user-2:p%40ss@gate.example.com:7777
        socks5h://alice:secret@10.0.0.2:1080
        socks5://10.0.0.3:1080\r
        not a proxy
        ftp://10.0.0.4:21
        """
        let parsed = ProxyLibrary.parseList(text)
        #expect(parsed.urls == [
            "http://user-1:pass@gate.example.com:7777", "http://user-2:p%40ss@gate.example.com:7777",
            "socks5://alice:secret@10.0.0.2:1080", "socks5://10.0.0.3:1080",
        ])
        #expect(parsed.rejected == ["not a proxy", "ftp://10.0.0.4:21"])
        #expect(ProxyLibrary.parseList("").urls.isEmpty)
    }

    @Test("Entries are added once, edited, checked and removed, and survive reopening the store")
    func storesEntries() throws {
        let directory = try scratchDirectory("proxy-library")
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: ProfileStore? = try ProfileStore(directory: directory)
        var library = ProxyLibrary(store: try #require(store))

        let added = try library.add(["gate.example.com:7777:user-1:pass", "http://user-1:pass@gate.example.com:7777",
                                     "socks5://10.0.0.3:1080"], label: " 住宅池 ")
        #expect(added.map(\.url) == ["http://user-1:pass@gate.example.com:7777", "socks5://10.0.0.3:1080"])
        #expect(added.allSatisfy { $0.label == "住宅池" && $0.lastExit == nil && $0.lastCheckedAt == nil })
        // Already there, however it is written.
        #expect(try library.add(["user-1:pass@gate.example.com:7777", "socks5h://10.0.0.3:1080"]).isEmpty)
        // An invalid address adds nothing at all.
        #expect(throws: ProfileError.self) { try library.add(["10.0.0.5:8080", "nonsense"]) }
        #expect(library.entries.count == 2)
        #expect(library.entry(matching: " gate.example.com:7777:user-1:pass ")?.id == added[0].id)
        #expect(library.entry(matching: "gate.example.com:7777:user-2:pass") == nil)

        var edited = added[1]
        edited.tags = ["美国", "美国", " 低延迟 "]
        edited.note = "  主力  "
        edited.label = "SOCKS"
        try library.update(edited)
        #expect(library.entries[1].tags == ["美国", "低延迟"] && library.entries[1].note == "主力")
        edited.url = "http://user-1:pass@gate.example.com:7777"
        #expect(throws: ProfileError.self) { try library.update(edited) }
        edited.url = "10.0.0.3:1080:x:"
        edited.tags = ["a,b"]
        #expect(throws: ProfileError.self) { try library.update(edited) }

        let exit = ProxyExit(ip: "203.0.113.9", countryCode: "US", timeZone: "America/Chicago", languages: ["en-US"])
        let checked = Date(timeIntervalSince1970: 1_800_000_000)
        try library.recordCheck(added[0].id, exit: exit, at: checked)
        try library.recordCheck(added[1].id, exit: nil, at: checked)
        #expect(library.entries[0].lastExit == exit && library.entries[0].lastCheckedAt == checked)
        #expect(library.entries[1].lastExit == nil && library.entries[1].lastCheckedAt == checked)

        // A new address drops the exit checked through the old one.
        var moved = library.entries[0]
        moved.url = "gate.example.com:7777:user-3:pass"
        try library.update(moved)
        #expect(library.entries[0].url == "http://user-3:pass@gate.example.com:7777" && library.entries[0].lastExit == nil)
        try library.recordCheck(moved.id, exit: exit, at: checked)

        let snapshot = library.entries
        library = ProxyLibrary(store: try #require(store))
        #expect(library.entries == snapshot)
        store = nil
        store = try ProfileStore(directory: directory)
        library = ProxyLibrary(store: try #require(store))
        #expect(library.entries == snapshot)

        try library.remove([added[1].id, UUID()])
        #expect(library.entries.map(\.id) == [added[0].id])
        #expect(ProxyLibrary(store: try #require(store)).entries.map(\.id) == [added[0].id])
    }

    @Test("Each Profile's last exit is kept, and Profiles sharing an exit IP are found")
    func recordsProfileExits() throws {
        let directory = try scratchDirectory("proxy-exits")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        var profiles: [BrowserProfile] = []
        for _ in 0..<4 {
            let profile = try store.makeDraft()
            try store.save(profile)
            profiles.append(profile)
        }
        let library = ProxyLibrary(store: store)
        let shared = ProxyExit(ip: "198.51.100.7", countryCode: "DE")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try library.recordExit(shared, forProfile: profiles[0].id, at: date)
        try library.recordExit(ProxyExit(ip: "198.51.100.8"), forProfile: profiles[1].id)
        try library.recordExit(shared, forProfile: profiles[2].id)
        // A record left by a Profile that no longer exists does not count.
        let gone = UUID()
        try library.recordExit(shared, forProfile: gone)

        #expect(library.lastExit(forProfile: profiles[0].id)?.exit == shared)
        #expect(library.lastExit(forProfile: profiles[0].id)?.checkedAt == date)
        #expect(library.lastExit(forProfile: profiles[3].id) == nil)
        #expect(library.profilesSharingExit(with: profiles[0].id) == [profiles[2].id])
        #expect(library.profilesSharingExit(with: profiles[2].id) == [profiles[0].id])
        #expect(library.profilesSharingExit(with: profiles[1].id).isEmpty)
        #expect(library.profilesSharingExit(with: profiles[3].id).isEmpty)

        // The exit moved: no longer shared.
        try library.recordExit(ProxyExit(ip: "198.51.100.9"), forProfile: profiles[2].id)
        #expect(library.profilesSharingExit(with: profiles[0].id).isEmpty)
        let reopened = ProxyLibrary(store: store)
        #expect(reopened.lastExit(forProfile: profiles[2].id)?.exit.ip == "198.51.100.9")
        #expect(reopened.profileExits.count == 4)
        try reopened.forgetExit(forProfile: gone)
        #expect(ProxyLibrary(store: store).profileExits[gone] == nil)
    }

    @Test("A recorded exit holds only while the Profile keeps the proxy it was seen through")
    func exitsFollowTheProxy() throws {
        let directory = try scratchDirectory("proxy-exit-proxy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        var profiles: [BrowserProfile] = []
        for proxy in ["127.0.0.1:9", "http://alice:s3cret@127.0.0.1:9"] {
            var profile = try store.makeDraft()
            profile.proxy = proxy
            try store.save(profile)
            profiles.append(profile)
        }
        let library = ProxyLibrary(store: store)
        let tokyo = ProxyExit(ip: "203.0.113.5", countryCode: "JP", timeZone: "Asia/Tokyo")
        try library.recordExit(tokyo, forProfile: profiles[0].id)
        try library.recordExit(tokyo, forProfile: profiles[1].id, proxy: "127.0.0.1:9:alice:s3cret")
        #expect(library.lastExit(forProfile: profiles[1].id)?.exit == tokyo)
        #expect(library.profilesSharingExit(with: profiles[1].id) == [profiles[0].id])
        // Stored as the exit's own JSON, which earlier readers take as it is, without the password.
        let stored = try withDatabase(directory) { database -> Data in
            var read: OpaquePointer?
            defer { sqlite3_finalize(read) }
            guard sqlite3_prepare_v2(database, "SELECT exit FROM profile_exits WHERE id='\(profiles[1].id.uuidString)'",
                                     -1, &read, nil) == SQLITE_OK, sqlite3_step(read) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(read, 0) else { throw ProfileError.invalid("read") }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(read, 0)))
        }
        #expect(try JSONDecoder().decode(ProxyExit.self, from: stored) == tokyo)
        #expect(!String(decoding: stored, as: UTF8.self).contains("s3cret"))

        // Written another way, the proxy is the same one.
        profiles[0].proxy = "http://127.0.0.1:9/"
        try store.save(profiles[0])
        #expect(library.lastExit(forProfile: profiles[0].id)?.exit == tokyo)

        // Moved to another proxy: the exit seen through the old one says nothing and is shared with no one.
        profiles[0].proxy = "127.0.0.1:10"
        try store.save(profiles[0])
        #expect(library.lastExit(forProfile: profiles[0].id) == nil)
        #expect(library.lastExit(forProfile: profiles[0].id, proxy: "127.0.0.1:9")?.exit == tokyo)
        #expect(library.profilesSharingExit(with: profiles[0].id).isEmpty)
        #expect(library.profilesSharingExit(with: profiles[1].id).isEmpty)
        #expect(ProxyLibrary(store: store).lastExit(forProfile: profiles[0].id) == nil)
        let index = LibraryIndex()
        index.update(.init(profiles: store.profiles, query: "", sort: .created, lastLaunched: [:], exits: library.profileExits))
        #expect(Set(index.exits.keys) == [profiles[1].id] && index.sharedExits.isEmpty)
        profiles[0].proxy = ""
        try store.save(profiles[0])
        #expect(library.lastExit(forProfile: profiles[0].id) == nil)

        // A record that does not say which proxy it came through holds for none.
        try execute("UPDATE profile_exits SET exit=? WHERE id=?", in: directory,
                    binding: [try JSONEncoder().encode(tokyo), profiles[1].id.uuidString])
        let reopened = ProxyLibrary(store: store)
        #expect(reopened.profileExits[profiles[1].id]?.exit == tokyo)
        #expect(reopened.lastExit(forProfile: profiles[1].id) == nil)
    }

    @Test("A database a newer AnyBrowser wrote is not written to, with a reason the user can read")
    func refusesNewerDatabase() throws {
        let directory = try scratchDirectory("proxy-read-only")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID: UUID
        do {
            let store = try ProfileStore(directory: directory)
            let profile = try store.makeDraft()
            try store.save(profile)
            profileID = profile.id
            try ProxyLibrary(store: store).add(["http://1.2.3.4:8080"])
        }
        try execute("PRAGMA user_version = 99", in: directory)
        let store = try ProfileStore(directory: directory)
        #expect(store.isReadOnly)
        let library = ProxyLibrary(store: store)
        var edited = try #require(library.entries.first)
        edited.label = "changed"
        let exit = ProxyExit(ip: "203.0.113.5")
        let writes: [(String, () throws -> Void)] = [
            ("add", { _ = try library.add(["http://5.6.7.8:8080"]) }), ("update", { try library.update(edited) }),
            ("recordCheck", { try library.recordCheck(edited.id, exit: exit) }),
            ("recordExit", { try library.recordExit(exit, forProfile: profileID) }), ("remove", { try library.remove([edited.id]) }),
        ]
        for (name, write) in writes {
            do {
                try write()
                Issue.record("\(name) wrote to the database")
            } catch {
                #expect(error.localizedDescription.contains("更新版本的 AnyBrowser"), "\(name): \(error.localizedDescription)")
            }
        }
        #expect(library.entries.map(\.label) == [""] && library.profileExits.isEmpty)
        #expect(try rowCount("proxies", in: directory) == 1 && rowCount("profile_exits", in: directory) == 0)
    }

    @Test("Rows this version cannot read are left alone")
    func skipsUnreadableRows() throws {
        let directory = try scratchDirectory("proxy-rows")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let library = ProxyLibrary(store: store)
        try library.add(["10.0.0.1:8080"])
        for sql in ["INSERT INTO proxies(id, url, created_at) VALUES('not-a-uuid', 'http://10.0.0.2:8080', 1)",
                    "INSERT INTO proxies(id, url, created_at) VALUES('\(UUID().uuidString)', 'garbage', 2)",
                    "INSERT INTO profile_exits(id, exit, checked_at) VALUES('\(UUID().uuidString)', x'00', 3)"] {
            #expect(sqlite3_exec(store.database, sql, nil, nil, nil) == SQLITE_OK)
        }
        let reopened = ProxyLibrary(store: store)
        #expect(reopened.entries.map(\.url) == ["http://10.0.0.1:8080"])
        #expect(reopened.profileExits.isEmpty)
    }
}
