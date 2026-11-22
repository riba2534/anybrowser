@testable import AnyBrowserCore
import Foundation
import Testing

/// SplitMix64, so that a random assignment can be replayed.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Counts lookups in flight, to check the concurrency limit.
private actor LookupMeter {
    private(set) var running = 0
    private(set) var peak = 0
    private(set) var asked: [String] = []

    func begin(_ url: String) {
        running += 1
        peak = max(peak, running)
        asked.append(url)
    }

    func end() {
        running -= 1
    }
}

private func entries(_ count: Int) -> [ProxyEntry] {
    (1...count).map { ProxyEntry(url: "http://10.0.0.\($0):8080") }
}

private func profile(_ name: String, port: Int, group: String = "", proxy: String = "") -> BrowserProfile {
    BrowserProfile(name: name, port: port, fingerprint: FingerprintSettings(seed: port), proxy: proxy, group: group)
}

private func exit(_ ip: String, country: String = "US", timeZone: String = "America/New_York",
                  languages: [String] = ["en-US"]) -> ProxyExit {
    ProxyExit(ip: ip, countryCode: country, timeZone: timeZone, languages: languages)
}

@Suite("Proxy assignment")
@MainActor
struct ProxyAssignmentTests {
    @Test("Usage counts the Profiles behind each entry, however their address is written")
    func countsUsage() {
        let pool = [ProxyEntry(url: "http://user:pass@gate.example.com:7777"), ProxyEntry(url: "socks5://10.0.0.3:1080")]
        let profiles = [
            profile("A", port: 9222, proxy: "gate.example.com:7777:user:pass"),
            profile("B", port: 9223, proxy: "user:pass@GATE.example.com:7777"),
            profile("C", port: 9224, proxy: "socks5h://10.0.0.3:1080"),
            profile("D", port: 9225, proxy: ""),
            profile("E", port: 9226, proxy: "gate.example.com:7777:other:pass"),
        ]
        #expect(ProxyAssignment.usage(of: pool, by: profiles) == [pool[0].id: 2, pool[1].id: 1])
        let users = ProxyAssignment.users(of: profiles)
        #expect(ProxyAssignment.usage(of: pool, users: users, excluding: [profiles[0].id, profiles[2].id]) == [pool[0].id: 1])
    }

    @Test("In order, proxies no Profile uses come first, and the library wraps around")
    func picksInOrder() throws {
        let pool = entries(4)
        let usage = [pool[0].id: 1, pool[2].id: 3]
        #expect(try ProxyAssignment.pick(3, from: pool, order: .sequential, usage: usage)
            == [pool[1].url, pool[3].url, pool[0].url])
        #expect(try ProxyAssignment.pick(6, from: pool, order: .sequential)
            == [pool[0].url, pool[1].url, pool[2].url, pool[3].url, pool[0].url, pool[1].url])
        #expect(ProxyAssignment.repeats(5, from: pool) && !ProxyAssignment.repeats(4, from: pool))
        #expect(try ProxyAssignment.pick(0, from: [], order: .sequential).isEmpty)
        #expect(throws: ProfileError.self) { try ProxyAssignment.pick(1, from: [], order: .sequential) }
    }

    @Test("At random, every Profile gets a different proxy, unused ones first, or none when there are too few")
    func picksAtRandom() throws {
        let pool = entries(6)
        let usage = [pool[0].id: 1, pool[1].id: 1]
        var seen: Set<[String]> = []
        for seed in 0..<20 {
            var generator = SeededGenerator(state: UInt64(seed))
            let picked = try ProxyAssignment.pick(5, from: pool, order: .randomUnique, usage: usage, using: &generator)
            #expect(Set(picked).count == 5)
            // The four free proxies all come before either used one.
            #expect(Set(picked.prefix(4)) == Set(pool[2...].map(\.url)))
            #expect(pool[..<2].map(\.url).contains(picked[4]))
            seen.insert(picked)
        }
        #expect(seen.count > 1)
        var generator = SeededGenerator(state: 7)
        let again = try ProxyAssignment.pick(5, from: pool, order: .randomUnique, usage: usage, using: &generator)
        generator = SeededGenerator(state: 7)
        #expect(try ProxyAssignment.pick(5, from: pool, order: .randomUnique, usage: usage, using: &generator) == again)
        #expect(throws: ProfileError.self) { try ProxyAssignment.pick(7, from: pool, order: .randomUnique) }
    }

    @Test("Exits are looked up once per proxy, a few at a time, and failures keep their reason")
    func looksUpExits() async throws {
        let meter = LookupMeter()
        let proxies = (1...9).map { "10.0.0.\($0):8080" } + ["http://10.0.0.1:8080", "", "nonsense address"]
        var reports: [(Int, Int)] = []
        var completed: [String: TimeInterval] = [:]
        let results = await ProxyAssignment.lookUpExits(proxies, limit: 3, lookup: { endpoint in
            await meter.begin(endpoint.url)
            try await Task.sleep(nanoseconds: 20_000_000)
            await meter.end()
            if endpoint.host == "10.0.0.4" { throw ProfileError.invalid("代理拒绝连接。") }
            return exit(endpoint.host)
        }, progress: { reports.append(($0, $1)) }, completed: { url, _, duration in completed[url] = duration })
        #expect(completed.count == 9 && completed.values.allSatisfy { $0 >= 0.015 })
        #expect(await meter.peak == 3)
        #expect(await meter.asked.count == 9)
        #expect(results["http://10.0.0.2:8080"] == .found(exit("10.0.0.2")))
        #expect(results["http://10.0.0.4:8080"] == .failed("代理拒绝连接。"))
        #expect(results["nonsense address"]?.exit == nil && results["nonsense address"] != nil)
        #expect(results[""] == nil)
        #expect(reports.first! == (0, 9) && reports.last! == (9, 9) && reports.count == 10)
    }

    @Test("Each Profile's locale comes from its own exit, the Mac's without a proxy, and failures say why")
    func alignsLocales() throws {
        let lookups: [String: ProxyAssignment.Lookup] = [
            "http://10.0.0.1:8080": .found(exit("1.1.1.1", country: "DE", timeZone: "Europe/Berlin", languages: ["de-DE"])),
            "http://10.0.0.2:8080": .failed("超时。"),
            "http://10.0.0.3:8080": .found(ProxyExit(ip: "3.3.3.3")),
        ]
        let german = ProxyAssignment.locale(for: "10.0.0.1:8080", in: lookups)
        #expect(german.hint?.language == "de-DE" && german.hint?.timeZone == "Europe/Berlin" && german.failure == nil)
        #expect(ProxyAssignment.locale(for: "10.0.0.2:8080", in: lookups) == (nil, "超时。"))
        #expect(ProxyAssignment.locale(for: "10.0.0.3:8080", in: lookups).failure?.contains("3.3.3.3") == true)
        #expect(ProxyAssignment.locale(for: "10.0.0.9:8080", in: lookups).failure != nil)
        let none = ProxyAssignment.locale(for: "  ", in: lookups)
        #expect(none.hint == IdentitySampler.LocaleHint.host && none.failure == nil)
    }

    @Test("A batch gives each Profile its own proxy and locale and saves them together")
    func createsBatchWithOwnProxies() throws {
        let directory = try scratchDirectory("library-batch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        try store.save(profile("Shop 2", port: 9222))
        let german = try #require(IdentitySampler.LocaleHint(language: "de-DE", timeZone: "Europe/Berlin"))
        let japanese = try #require(IdentitySampler.LocaleHint(language: "ja-JP", timeZone: "Asia/Tokyo"))
        let request = ProfileLibrary.BatchRequest(count: 3, prefix: "Shop", group: "店铺", proxy: "ignored:1")
        let created = try store.saveBatch(request, proxies: ["10.0.0.1:8080", "10.0.0.2:8080", ""],
                                          locales: [german, japanese, nil])
        #expect(created.map(\.name) == ["Shop 1", "Shop 3", "Shop 4"])
        #expect(created.map(\.proxy) == ["10.0.0.1:8080", "10.0.0.2:8080", ""])
        #expect(created[0].fingerprint.timeZone == "Europe/Berlin" && created[0].fingerprint.language == "de-DE")
        #expect(created[1].fingerprint.timeZone == "Asia/Tokyo" && created[1].fingerprint.language == "ja-JP")
        #expect(created.allSatisfy { $0.group == "店铺" })
        #expect(Set(store.profiles.map(\.port)).count == 4 && Set(store.profiles.map(\.fingerprint.seed)).count == 4)
        #expect(throws: ProfileError.self) {
            try store.saveBatch(request, proxies: ["10.0.0.1:8080"], locales: [nil, nil, nil])
        }
        // One invalid proxy saves none of the batch.
        #expect(throws: ProfileError.self) {
            try store.saveBatch(ProfileLibrary.BatchRequest(count: 2, prefix: "Bad"), proxies: ["10.0.0.1:8080", "ftp://x:1"],
                                locales: [nil, nil])
        }
        #expect(store.profiles.count == 4)
    }
}

@Suite("Sidebar index")
@MainActor
struct LibraryIndexTests {
    @Test("Sections are worked out again only when what they show changes")
    func cachesSections() {
        let index = LibraryIndex()
        let profiles = [profile("B", port: 9222, group: "店铺"), profile("A", port: 9223), profile("C", port: 9224, group: "店铺")]
        var inputs = LibraryIndex.Inputs(profiles: profiles, query: "", sort: .name, lastLaunched: [:])
        index.update(inputs)
        index.update(inputs)
        #expect(index.computations == 1)
        #expect(index.sections.map(\.group) == ["店铺", ""])
        #expect(index.visibleIDs == [profiles[0].id, profiles[2].id, profiles[1].id])
        #expect(index.groups == ["店铺"])

        inputs.query = "group:店铺 C"
        index.update(inputs)
        #expect(index.computations == 2 && index.visibleIDs == [profiles[2].id])
        inputs.query = ""
        inputs.sort = .recent
        inputs.lastLaunched = [profiles[2].id: Date()]
        index.update(inputs)
        #expect(index.computations == 3 && index.visibleIDs == [profiles[2].id, profiles[0].id, profiles[1].id])
        var renamed = profiles
        renamed[1].group = "备用"
        renamed[0].tags = ["美国", "Main"]
        renamed[2].tags = ["main", "低价"]
        inputs.profiles = renamed
        index.update(inputs)
        #expect(index.computations == 4 && index.groups == ["备用", "店铺"])
        // Each tag once whatever its case, spelled as first seen.
        #expect(index.tags.count == 3 && Set(index.tags) == ["Main", "低价", "美国"])
    }

    @Test("Profiles that left through the same IP are marked, each with the others")
    func findsSharedExits() {
        let ids = (0..<4).map { _ in UUID() }
        let gone = UUID()
        let record = { (ip: String) in ProfileExitRecord(exit: exit(ip), checkedAt: Date()) }
        let exits = [ids[0]: record("1.1.1.1"), ids[1]: record("2.2.2.2"), ids[2]: record("1.1.1.1"),
                     ids[3]: record("3.3.3.3"), gone: record("3.3.3.3")]
        #expect(LibraryIndex.sharedExits(exits, among: ids) == [ids[0]: [ids[2]], ids[2]: [ids[0]]])

        let index = LibraryIndex()
        var profiles = [profile("A", port: 9222, proxy: "10.0.0.1:8080"), profile("B", port: 9223, proxy: "10.0.0.2:8080")]
        var inputs = LibraryIndex.Inputs(profiles: profiles, query: "", sort: .created, lastLaunched: [:])
        index.update(inputs)
        #expect(index.sharedExits.isEmpty)
        let seen = { (ip: String, profile: BrowserProfile) in
            ProfileExitRecord(exit: exit(ip), checkedAt: Date(), proxy: ProfileExitRecord.key(for: profile.proxy))
        }
        inputs.exits = [profiles[0].id: seen("9.9.9.9", profiles[0]), profiles[1].id: seen("9.9.9.9", profiles[1])]
        index.update(inputs)
        #expect(index.sharedExits[profiles[0].id] == [profiles[1].id])
        #expect(index.names[profiles[1].id] == "B")
        #expect(index.exits == inputs.exits)

        // B has moved to another proxy: what was seen through the old one no longer counts.
        profiles[1].proxy = "http://10.0.0.3:8080"
        inputs.profiles = profiles
        index.update(inputs)
        #expect(index.sharedExits.isEmpty)
        #expect(Set(index.exits.keys) == [profiles[0].id])
    }

    @Test("Proxies of Profiles in the recycle bin count as used, as the API counts them")
    func countsTrashedProxyUsers() throws {
        let pool = entries(3)
        let kept = profile("Kept", port: 9222, proxy: pool[1].url)
        let trashed = TrashedProfile(profile: profile("Trashed", port: 9223, proxy: "10.0.0.1:8080"), deletedAt: Date())
        let index = LibraryIndex()
        var inputs = LibraryIndex.Inputs(profiles: [kept], query: "", sort: .created, lastLaunched: [:])
        index.update(inputs)
        #expect(index.proxyUsers == [pool[1].url: [kept.id]])
        inputs.trashed = [trashed]
        index.update(inputs)
        #expect(index.proxyUsers == ProxyAssignment.users(of: [kept, trashed.profile]))
        #expect(index.proxyUsers[pool[0].url] == [trashed.id])
        // Restored, it would share its proxy with a Profile made meanwhile: hand out the free one first.
        let usage = ProxyAssignment.usage(of: pool, users: index.proxyUsers)
        #expect(try ProxyAssignment.pick(1, from: pool, order: .sequential, usage: usage) == [pool[2].url])
    }

    @Test("⇧-click ranges and arrow steps follow the rows as shown")
    func selectsRanges() {
        let order = (0..<5).map { _ in UUID() }
        let outside = UUID()
        #expect(LibrarySelection.range(from: order[3], to: order[1], in: order) == Array(order[1...3]))
        #expect(LibrarySelection.range(from: order[1], to: order[4], in: order) == Array(order[1...4]))
        #expect(LibrarySelection.range(from: nil, to: order[2], in: order) == [order[2]])
        #expect(LibrarySelection.range(from: outside, to: order[2], in: order) == [order[2]])
        #expect(LibrarySelection.range(from: order[0], to: outside, in: order).isEmpty)

        #expect(LibrarySelection.step(from: order[2], by: 1, in: order) == order[3])
        #expect(LibrarySelection.step(from: order[2], by: -1, in: order) == order[1])
        #expect(LibrarySelection.step(from: order[4], by: 1, in: order) == order[4])
        #expect(LibrarySelection.step(from: order[0], by: -1, in: order) == order[0])
        #expect(LibrarySelection.step(from: nil, by: 1, in: order) == order[0])
        #expect(LibrarySelection.step(from: outside, by: -1, in: order) == order[4])
        #expect(LibrarySelection.step(from: nil, by: 1, in: []) == nil)
    }

    @Test("The recycle bin counts down whole days until the entry is purged")
    func countsDaysLeft() {
        let removed = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = TrashedProfile(profile: profile("A", port: 9222), deletedAt: removed)
        #expect(entry.daysRemaining(now: removed) == 30)
        #expect(entry.daysRemaining(now: removed.addingTimeInterval(3600)) == 30)
        #expect(entry.daysRemaining(now: removed.addingTimeInterval(86400)) == 29)
        #expect(entry.daysRemaining(now: removed.addingTimeInterval(29.5 * 86400)) == 1)
        #expect(entry.daysRemaining(now: removed.addingTimeInterval(30 * 86400)) == 0)
        #expect(entry.daysRemaining(now: removed.addingTimeInterval(40 * 86400)) == 0)
        #expect(entry.daysRemaining(now: removed.addingTimeInterval(86400), retention: 7) == 6)
    }

    @Test("Database backups are described by the names the store gives them")
    func describesDatabaseBackups() throws {
        let directory = try scratchDirectory("library-backups")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let before = Date()
        let url = try store.backup(reason: "manual")
        let backup = try #require(DatabaseBackup(url))
        #expect(backup.reason == "manual" && backup.title == "手动备份")
        #expect(abs(backup.createdAt.timeIntervalSince(before)) < 5)
        #expect(ProfileStore.backups(in: directory).compactMap(DatabaseBackup.init).map(\.url) == [url])
        let other = DatabaseBackup(URL(fileURLWithPath: "/tmp/profiles-20260102-030405-678-daily.sqlite3"))
        #expect(other?.reason == "daily" && other?.title == "每日自动备份")
        #expect(DatabaseBackup(URL(fileURLWithPath: "/tmp/profiles.sqlite3")) == nil)
        #expect(DatabaseBackup(URL(fileURLWithPath: "/tmp/profiles-2026-daily.sqlite3")) == nil)
    }
}
