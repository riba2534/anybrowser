@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

/// Storage inside a stand-in Application Support folder, so Chromium's caches would live under a
/// stand-in Caches folder, as they do for the real AnyBrowser directory.
@MainActor
private struct CacheFixture {
    let root: URL
    let caches: URL
    let runtime: BrowserRuntime

    init() throws {
        root = try scratchDirectory("site-data")
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        caches = root.appendingPathComponent("Caches", isDirectory: true)
        let storage = support.appendingPathComponent("AnyBrowser", isDirectory: true)
        for directory in [support, caches, storage] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let engine = BrowserEngine(version: "test", executable: URL(fileURLWithPath: "/bin/true"),
                                   passkeyBoxDirectory: URL(fileURLWithPath: "/tmp/anybrowser-test-extension"))
        runtime = BrowserRuntime(engine: engine, storage: storage, applicationSupport: support, caches: caches)
    }

    /// Writes `relative` under `directory`, creating private parents as Chromium does.
    @discardableResult
    func write(_ relative: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data("kept".utf8).write(to: file)
        return file
    }

    func exists(_ url: URL) -> Bool {
        var details = stat()
        return lstat(url.path, &details) == 0
    }
}

struct SiteDataTests {
    @Test("Clearing a stopped Profile removes site data but keeps extension storage and preferences")
    @MainActor
    func clearsStoppedSiteData() async throws {
        let storage = try scratchDirectory("site-data")
        defer { try? FileManager.default.removeItem(at: storage) }

        let id = UUID()
        let root = storage.appendingPathComponent("Profiles/\(id.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let defaults = root.appendingPathComponent("Default", isDirectory: true)
        let cookies = defaults.appendingPathComponent("Network/Cookies")
        let localStorage = defaults.appendingPathComponent("Local Storage/leveldb/CURRENT")
        let sharedStorage = defaults.appendingPathComponent("SharedStorage")
        let salts = defaults.appendingPathComponent("MediaDeviceSalts")
        let cache = defaults.appendingPathComponent("Cache/Cache_Data/index")
        let extensionStorage = defaults.appendingPathComponent("Local Extension Settings/extension/config")
        let preferences = defaults.appendingPathComponent("Preferences")
        for file in [cookies, localStorage, sharedStorage, salts, cache, extensionStorage, preferences] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: file)
        }

        let engine = BrowserEngine(version: "test",
                                   executable: URL(fileURLWithPath: "/bin/true"),
                                   passkeyBoxDirectory: URL(fileURLWithPath: "/tmp/anybrowser-test-extension"))
        let runtime = BrowserRuntime(engine: engine, storage: storage)
        // Outside Application Support the caches stay in the data directory.
        #expect(runtime.cacheDirectory(for: id) == runtime.dataDirectory(for: id))
        try await runtime.clearSiteData(for: id)

        for file in [cookies, localStorage, sharedStorage, salts, cache] {
            #expect(!FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)")
        }
        #expect(FileManager.default.fileExists(atPath: extensionStorage.path))
        #expect(FileManager.default.fileExists(atPath: preferences.path))
    }

    @Test("Under Application Support the cache directory is the matching path under Caches")
    @MainActor
    func cacheDirectoryFollowsChromium() throws {
        let fixture = try CacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        #expect(fixture.runtime.cacheDirectory(for: id).path
            == fixture.caches.path + "/AnyBrowser/Profiles/\(id.uuidString.lowercased())")
    }

    @Test("Clearing a stopped Profile also deletes its cache directory under Caches")
    @MainActor
    func clearsCacheDirectory() async throws {
        let fixture = try CacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let data = fixture.runtime.dataDirectory(for: id)
        let cache = fixture.runtime.cacheDirectory(for: id)
        let cookies = try fixture.write("Default/Network/Cookies", in: data)
        let preferences = try fixture.write("Default/Preferences", in: data)
        try fixture.write("Default/Cache/Cache_Data/index", in: cache)
        try fixture.write("Default/Code Cache/js/index", in: cache)
        let other = try fixture.write("Default/Cache/Cache_Data/index", in: fixture.runtime.cacheDirectory(for: UUID()))

        try await fixture.runtime.clearSiteData(for: id)
        #expect(!fixture.exists(cookies))
        #expect(!fixture.exists(cache))
        #expect(fixture.exists(preferences))
        #expect(fixture.exists(other))
    }

    @Test("A cache directory that is a link stops the clearing before anything is deleted")
    @MainActor
    func linkedCacheStopsClearing() async throws {
        let fixture = try CacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let cookies = try fixture.write("Default/Network/Cookies", in: fixture.runtime.dataDirectory(for: id))
        let outside = try fixture.write("Keep", in: fixture.root.appendingPathComponent("Outside", isDirectory: true))
        let cache = fixture.runtime.cacheDirectory(for: id)
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: outside.deletingLastPathComponent())

        await #expect(throws: ProfileError.self) { try await fixture.runtime.clearSiteData(for: id) }
        #expect(fixture.exists(cookies))
        #expect(fixture.exists(outside))
    }

    @Test("Removing browser data deletes the cache directory; removing only the record keeps it")
    @MainActor
    func removeDataDeletesCache() async throws {
        let fixture = try CacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let removed = UUID()
        let kept = UUID()
        for id in [removed, kept] {
            try fixture.write("Default/Preferences", in: fixture.runtime.dataDirectory(for: id))
            try fixture.write("Default/Cache/Cache_Data/index", in: fixture.runtime.cacheDirectory(for: id))
        }
        try await fixture.runtime.removeData(for: removed)
        #expect(!fixture.exists(fixture.runtime.dataDirectory(for: removed)))
        #expect(!fixture.exists(fixture.runtime.cacheDirectory(for: removed)))

        try await fixture.runtime.removeData(for: kept, keepingBrowserData: true)
        #expect(fixture.exists(fixture.runtime.dataDirectory(for: kept)))
        #expect(fixture.exists(fixture.runtime.cacheDirectory(for: kept)))
    }

    @Test("A linked cache directory is not followed and stops the removal")
    @MainActor
    func removeDataRefusesLinkedCache() async throws {
        let fixture = try CacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let preferences = try fixture.write("Default/Preferences", in: fixture.runtime.dataDirectory(for: id))
        let outside = try fixture.write("Keep", in: fixture.root.appendingPathComponent("Outside", isDirectory: true))
        let cache = fixture.runtime.cacheDirectory(for: id)
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: outside.deletingLastPathComponent())

        var recordRemoved = false
        await #expect(throws: ProfileError.self) {
            try await fixture.runtime.removeData(for: id) { recordRemoved = true }
        }
        #expect(!recordRemoved)
        #expect(fixture.exists(preferences))
        #expect(fixture.exists(outside))
    }

    @Test("Orphaned cache directories are those of unknown Profiles without data, and only they are deleted")
    @MainActor
    func orphanCaches() async throws {
        let fixture = try CacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let known = UUID()
        let orphan = UUID()
        let withData = UUID()
        let linked = UUID()
        for id in [known, orphan, withData] {
            try fixture.write("Default/Cache/Cache_Data/index", in: fixture.runtime.cacheDirectory(for: id))
        }
        try fixture.write("Default/Preferences", in: fixture.runtime.dataDirectory(for: withData))
        let parent = fixture.runtime.cacheDirectory(for: known).deletingLastPathComponent()
        try fixture.write("Unrelated/file", in: parent)
        let outside = try fixture.write("Keep", in: fixture.root.appendingPathComponent("Outside", isDirectory: true))
        try FileManager.default.createSymbolicLink(at: fixture.runtime.cacheDirectory(for: linked),
                                                   withDestinationURL: outside.deletingLastPathComponent())

        let found = fixture.runtime.orphanCacheDirectories(knownProfiles: [known])
        #expect(Set(found) == [fixture.runtime.cacheDirectory(for: orphan), fixture.runtime.cacheDirectory(for: linked)])

        // The linked one is reported and kept; the real orphan is deleted all the same.
        await #expect(throws: ProfileError.self) {
            try await fixture.runtime.removeOrphanCacheDirectories(knownProfiles: [known])
        }
        #expect(!fixture.exists(fixture.runtime.cacheDirectory(for: orphan)))
        #expect(fixture.exists(outside))
        try FileManager.default.removeItem(at: fixture.runtime.cacheDirectory(for: linked))
        #expect(try await fixture.runtime.removeOrphanCacheDirectories(knownProfiles: [known]) == [])
        for id in [known, withData] {
            #expect(fixture.exists(fixture.runtime.cacheDirectory(for: id)))
        }
        #expect(fixture.exists(parent.appendingPathComponent("Unrelated/file")))
    }

    @Test("Without separate caches there are no orphaned cache directories")
    @MainActor
    func noOrphansWithoutSeparateCaches() throws {
        let storage = try scratchDirectory("site-data")
        defer { try? FileManager.default.removeItem(at: storage) }
        let engine = BrowserEngine(version: "test", executable: URL(fileURLWithPath: "/bin/true"),
                                   passkeyBoxDirectory: URL(fileURLWithPath: "/tmp/anybrowser-test-extension"))
        let runtime = BrowserRuntime(engine: engine, storage: storage)
        try PrivateDirectory.ensure(runtime.dataDirectory(for: UUID()))
        #expect(runtime.orphanCacheDirectories(knownProfiles: []).isEmpty)
    }
}
