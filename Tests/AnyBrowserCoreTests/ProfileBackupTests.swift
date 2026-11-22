@testable import AnyBrowserCore
import Darwin
import Foundation
import SQLite3
import Testing

// The fake engine listens on ports 17400–17409 here; nothing listens on 17499.

private typealias Manifest = ProfileBackup.Manifest
private typealias Entry = ProfileBackup.Entry

private func profile(port: Int, name: String = "Backup") -> BrowserProfile {
    BrowserProfile(name: name, port: port, fingerprint: FingerprintSettings(seed: port), proxy: "")
}

private func manifest(_ entries: [Entry], version: Int = ProfileBackup.version) -> Manifest {
    Manifest(format: ProfileBackup.format, version: version, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
             appVersion: "0.5.0", engineVersion: BundledVersions.engine, profiles: entries)
}

private func write(_ text: String, to relative: String, in root: URL) throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try Data(text.utf8).write(to: url)
}

/// Every path below `root`, relative to it.
private func listing(_ root: URL) -> Set<String> {
    let names = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
    return Set(names)
}

/// A backup folder holding `entries`, each with an empty cookie file and, when listed, a data directory.
private func stage(_ entries: [Entry], version: Int = ProfileBackup.version) throws -> URL {
    let root = try scratchDirectory("backup-stage")
    for entry in entries {
        let folder = ProfileBackup.entryFolder(entry.id, in: root)
        try write("[]\n", to: "Cookies.json", in: folder)
        if entry.browserData { try write("kept", to: "Data/Default/Preferences", in: folder) }
    }
    try ProfileBackup.write(manifest(entries, version: version), in: root)
    return root
}

/// Unpacks and checks a backup the way a restore does, returning its manifest.
private func open(_ file: URL) throws -> Manifest {
    let root = try scratchDirectory("backup-open")
    defer { try? FileManager.default.removeItem(at: root) }
    try ProfileBackup.unpack(file, into: root)
    return try ProfileBackup.readManifest(in: root, name: file.lastPathComponent)
}

private func failure(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch {
        return error.localizedDescription
    }
}

struct ProfileBackupTests {
    @Test("The manifest keeps every Profile setting, secrets included, and reads back the same")
    func manifestRoundTrip() throws {
        var saved = profile(port: 9300, name: "工作号")
        saved.proxy = "http://user:pa%40ss@proxy.example:8080"
        saved.passkeyBox = PasskeyBoxAccount(serverURL: "https://passkeys.example", username: "me", password: "secret")
        saved.tags = ["a"]
        let entry = Entry(id: saved.id, name: saved.name, cookies: 3, browserData: true, profile: saved)
        let root = try stage([entry])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try ProfileBackup.readManifest(in: root, name: "x") == manifest([entry]))
        let text = try String(contentsOf: root.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(text.contains("pa%40ss"))
        #expect(text.contains("\"password\" : \"secret\""))
        #expect(text.contains("\"engineVersion\" : \"\(BundledVersions.engine)\""))
        #expect(text.contains("\"createdAt\" : \"2023-11-14T22:13:20Z\""))
    }

    @Test("A Profile this version cannot read skips that entry, not the backup")
    func unreadableEntry() throws {
        let saved = profile(port: 9300)
        let root = try stage([Entry(id: saved.id, name: saved.name, cookies: 0, browserData: false, profile: saved)])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("manifest.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try #require(object["profiles"] as? [[String: Any]])
        var stored = try #require(entries[0]["profile"] as? [String: Any])
        stored["fingerprint"] = nil
        entries[0]["profile"] = stored
        object["profiles"] = entries
        object["addedLater"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let read = try ProfileBackup.readManifest(in: root, name: "x")
        #expect(read.profiles.count == 1)
        #expect(read.profiles[0].profile == nil)
        #expect(read.profiles[0].unreadable == "缺少字段 fingerprint。")
        let plan = ProfileBackup.plan(read.profiles, identity: .renew, takenIDs: [:], takenPorts: [], takenSeeds: [])
        #expect(plan.map(\.skipped) == ["缺少字段 fingerprint。"])
    }

    @Test("Damaged, newer, foreign and incomplete backups are refused")
    func refusesBadBackups() throws {
        let saved = profile(port: 9300, name: "A")
        let entry = Entry(id: saved.id, name: "A", cookies: 0, browserData: true, profile: saved)
        let scratch = try scratchDirectory("backup-bad")
        defer { try? FileManager.default.removeItem(at: scratch) }
        func packed(_ name: String, _ change: (URL) throws -> Void = { _ in }, version: Int = ProfileBackup.version) throws -> URL {
            let root = try stage([entry], version: version)
            defer { try? FileManager.default.removeItem(at: root) }
            try change(root)
            let file = scratch.appendingPathComponent(name)
            try ProfileBackup.pack(root, to: file)
            return file
        }

        let good = try packed("good.anybrowser")
        #expect(try open(good).profiles == [entry])
        #expect(try permissions(good) == 0o600)

        let garbage = scratch.appendingPathComponent("garbage.anybrowser")
        try Data("not a zip archive".utf8).write(to: garbage)
        #expect(failure { _ = try open(garbage) } == "「garbage.anybrowser」不是有效的 AnyBrowser 备份文件，或已损坏。")
        let truncated = scratch.appendingPathComponent("truncated.anybrowser")
        let bytes = try Data(contentsOf: good)
        try bytes.prefix(bytes.count / 2).write(to: truncated)
        #expect(failure { _ = try open(truncated) } == "「truncated.anybrowser」不是有效的 AnyBrowser 备份文件，或已损坏。")
        #expect(failure { _ = try open(scratch) } == "请选择一个 AnyBrowser 备份文件。")

        let newer = try packed("newer.anybrowser", version: ProfileBackup.version + 1)
        #expect(failure { _ = try open(newer) } == "不支持此版本的备份文件（版本 \(ProfileBackup.version + 1)），请升级 AnyBrowser 后再恢复。")
        let foreign = try packed("foreign.anybrowser") { root in
            let url = root.appendingPathComponent("manifest.json")
            let text = try String(contentsOf: url, encoding: .utf8)
            try Data(text.replacingOccurrences(of: ProfileBackup.format, with: "anybrowser-profiles").utf8).write(to: url)
        }
        #expect(failure { _ = try open(foreign) } == "「foreign.anybrowser」不是 AnyBrowser 备份文件。")
        let unlisted = try packed("unlisted.anybrowser") { try FileManager.default.removeItem(at: $0.appendingPathComponent("manifest.json")) }
        #expect(failure { _ = try open(unlisted) } == "「unlisted.anybrowser」不是 AnyBrowser 备份文件。")
        let damaged = try packed("damaged.anybrowser") { try Data("{\"format\":\"anybrowser-backup\",\"version\":1,\"profiles\":7}".utf8).write(to: $0.appendingPathComponent("manifest.json")) }
        #expect(failure { _ = try open(damaged) } == "「damaged.anybrowser」的备份清单已损坏。")

        let folder = { (root: URL) in ProfileBackup.entryFolder(saved.id, in: root) }
        let noCookies = try packed("no-cookies.anybrowser") { try FileManager.default.removeItem(at: folder($0).appendingPathComponent("Cookies.json")) }
        #expect(failure { _ = try open(noCookies) } == "「no-cookies.anybrowser」不完整：缺少「A」的 Cookie。")
        let noData = try packed("no-data.anybrowser") { try FileManager.default.removeItem(at: folder($0).appendingPathComponent("Data")) }
        #expect(failure { _ = try open(noData) } == "「no-data.anybrowser」不完整：缺少「A」的浏览器资料。")
        let twice = try packed("twice.anybrowser") { try ProfileBackup.write(manifest([entry, entry]), in: $0) }
        #expect(failure { _ = try open(twice) } == "「twice.anybrowser」的备份清单已损坏：重复列出了「A」。")
    }

    @Test("A refused backup changes nothing")
    @MainActor
    func refusedBackupChangesNothing() async throws {
        let directory = try scratchDirectory("backup-refused")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let engine = BrowserEngine(version: "test", executable: URL(fileURLWithPath: "/bin/true"), passkeyBoxDirectory: directory)
        let runtime = BrowserRuntime(engine: engine, storage: store.directory)
        let file = directory.appendingPathComponent("garbage.anybrowser")
        try Data("PK".utf8).write(to: file)
        await #expect(throws: ProfileError.self) {
            _ = try await ProfileBackup.restore(from: file, store: store, runtime: runtime)
        }
        #expect(store.profiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Profiles").path))
    }

    @Test("Caches and the last browser's lock and receipt files are left out of the copy")
    func copyLeavesCachesOut() throws {
        let source = try scratchDirectory("backup-copy")
        let destination = try scratchDirectory("backup-copied")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let kept = [
            "Local State", "Default/Preferences", "Default/Cookies", "Default/Local Storage/leveldb/000003.log",
            "Default/IndexedDB/http_127.0.0.1_8000.indexeddb.leveldb/LOG",
            "Default/Service Worker/CacheStorage/abc/index", "Default/Local Extension Settings/id/000003.log",
        ]
        let dropped = [
            "Default/Cache/Cache_Data/data_0", "Default/Code Cache/js/index", "GPUCache/data_1",
            "ShaderCache/data_0", "GrShaderCache/data_0", "GraphiteDawnCache/data_0", "Default/DawnWebGPUCache/data_0",
            "Default/Storage/ext/id/def/GPUCache/data_0", "component_crx_cache/x", "extensions_crx_cache/y",
            ".anybrowser-runtime.json", ".anybrowser-runtime.lock", "DevToolsActivePort",
        ]
        for path in kept + dropped { try write(path, to: path, in: source) }
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("SingletonLock").path,
                                                   withDestinationPath: "host-123")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("Default/elsewhere").path,
                                                   withDestinationPath: "/etc")
        let copied = destination.appendingPathComponent("Data", isDirectory: true)
        try ProfileBackup.copyBrowserData(from: source, to: copied)

        let files = listing(copied).filter { path in
            var details = stat()
            return lstat(copied.appendingPathComponent(path).path, &details) == 0 && details.st_mode & S_IFMT != S_IFDIR
        }
        #expect(files == Set(kept))
        for path in kept {
            #expect(try String(contentsOf: copied.appendingPathComponent(path), encoding: .utf8) == path)
        }
        #expect(try permissions(copied) == 0o700)
        #expect(throws: ProfileError.self) { try ProfileBackup.copyBrowserData(from: source, to: copied) }
    }

    @Test("Restored ids follow the policy, and taken ports and seeds are replaced as on import")
    func planFollowsPolicy() throws {
        let first = profile(port: 9300, name: "First")
        var second = profile(port: 9300, name: "Second")
        second.fingerprint.seed = first.fingerprint.seed
        let third = profile(port: 9301, name: "Third")
        var invalid = profile(port: 80, name: "Invalid")
        invalid.fingerprint.seed = 7
        let entries = [first, second, third, invalid].map {
            Entry(id: $0.id, name: $0.name, cookies: 0, browserData: false, profile: $0)
        }
        let taken = [first.id: "本机已有 ID 相同的 Profile「First」。"]
        func plan(_ identity: ProfileBackup.IdentityPolicy) -> [ProfileBackup.Planned] {
            ProfileBackup.plan(entries, identity: identity, takenIDs: taken, takenPorts: [9301], takenSeeds: [9301])
        }

        let kept = plan(.keepOriginal)
        #expect(kept.map(\.skipped) == ["本机已有 ID 相同的 Profile「First」。", nil, nil, "调试端口须为 1024–65535。"])
        // The skipped first entry leaves its port and seed to the second.
        #expect(kept[1].profile?.id == second.id)
        #expect(kept[1].profile?.port == 9300)
        #expect(kept[1].profile?.fingerprint.seed == first.fingerprint.seed)
        #expect(kept[2].profile?.id == third.id)
        #expect(kept[2].profile.map { $0.port != 9301 && $0.port != 9300 } == true)
        #expect(kept[2].profile.map { $0.fingerprint.seed != 9301 && $0.fingerprint.seed != first.fingerprint.seed } == true)
        #expect(kept[2].profile?.name == "Third")

        let renewedWhenTaken = plan(.keepOriginalOrRenew)
        #expect(renewedWhenTaken.map(\.skipped) == [nil, nil, nil, "调试端口须为 1024–65535。"])
        let renewed = try #require(renewedWhenTaken[0].profile)
        #expect(renewed.id != first.id)
        #expect(renewed.port == 9300)
        #expect(renewedWhenTaken[1].profile?.id == second.id)
        // The second now collides with the first in the same backup.
        #expect(renewedWhenTaken[1].profile.map { $0.port != 9300 && $0.port != 9301 } == true)
        #expect(renewedWhenTaken[1].profile.map { $0.fingerprint.seed != first.fingerprint.seed } == true)

        let fresh = plan(.renew)
        let ids = fresh.compactMap(\.profile?.id)
        #expect(ids.count == 3)
        #expect(Set(ids).isDisjoint(with: entries.map(\.id)))
        #expect(Set(fresh.compactMap(\.profile?.port)).count == 3)
    }
}

/// Whether the browser the runtime runs for `id` right now was started without windows.
@MainActor
private func runsHeadless(_ id: UUID, _ runtime: BrowserRuntime) -> Bool? {
    guard case let .running(pid, _, _) = runtime.status(for: id) else { return nil }
    return ProcessInspection.arguments(pid)?.contains("--headless=new")
}

@MainActor
struct ProfileBackupFlowTests {
    @Test("A stopped Profile starts headless for its cookies, stops, and its data is backed up without caches")
    func backsUpStoppedProfile() async throws {
        let fixture = try FakeEngineFixture("backup-stopped")
        let store = try ProfileStore(directory: fixture.storage)
        var saved = fixture.profile(port: 17400)
        // Credentials would need the relay helper, which the fake engine lacks; the manifest test
        // above covers secrets in the package.
        saved.proxy = "http://127.0.0.1:17499"
        try store.save(saved)
        saved = store.profiles[0]
        try store.savePasskeyBoxAccount(PasskeyBoxAccount(serverURL: "https://passkeys.example", username: "global", password: "pw"))
        let data = fixture.runtime.dataDirectory(for: saved.id)
        for path in ["Default/Local Storage/leveldb/000003.log", "Default/Cache/Cache_Data/data_0", "GPUCache/data_1"] {
            try write(path, to: path, in: data)
        }
        try write("separate", to: "Default/Cache/Cache_Data/data_0", in: fixture.runtime.cacheDirectory(for: saved.id))

        try await fixture.run([saved]) {
            let file = fixture.root.appendingPathComponent("backup.anybrowser")
            let missing = UUID()
            var headless: [Bool?] = []
            var steps: [ProfileBackup.Progress] = []
            let result = try await ProfileBackup.export([saved.id, missing, saved.id], to: file, store: store,
                                                        runtime: fixture.runtime) { progress in
                steps.append(progress)
                if progress.message.contains("Cookie") { headless.append(runsHeadless(saved.id, fixture.runtime)) }
            }
            #expect(result.file == file)
            #expect(result.profiles.map(\.id) == [saved.id, missing])
            // The fake engine has no cookies to give; a real browser's are covered by the engine test.
            #expect(result.profiles[0] == ProfileBackup.ExportedProfile(
                id: saved.id, name: saved.name, cookies: 0, browserData: true,
                warnings: ["未能导出 Cookie：浏览器返回的 Cookie 数据无法识别。"]))
            #expect(result.profiles[1].skipped == "找不到此 Profile，可能已被移除。")
            #expect(headless == [true])
            #expect(fixture.commands(saved).contains { $0["method"] as? String == "Storage.getCookies" })
            #expect(fixture.runtime.status(for: saved.id) == .stopped)
            #expect(steps.first?.message == "正在以无窗口方式启动「\(saved.name)」")
            #expect(steps.last == ProfileBackup.Progress(completed: 2, total: 2, profile: nil, message: "正在写入备份文件"))
            // The launch signed in with the global account, as starting the Profile normally does.
            let config = PasskeyBoxInstall.directory(in: fixture.storage, for: saved.id).appendingPathComponent("managed-config.json")
            #expect(try String(contentsOf: config, encoding: .utf8).contains("global"))

            let unpacked = try scratchDirectory("backup-unpacked")
            defer { try? FileManager.default.removeItem(at: unpacked) }
            try ProfileBackup.unpack(file, into: unpacked)
            let manifest = try ProfileBackup.readManifest(in: unpacked, name: "backup.anybrowser")
            #expect(manifest.profiles == [Entry(id: saved.id, name: saved.name, cookies: 0, browserData: true, profile: saved)])
            #expect(manifest.profiles[0].profile?.proxy == "http://127.0.0.1:17499")
            let packed = ProfileBackup.entryFolder(saved.id, in: unpacked).appendingPathComponent("Data")
            #expect(listing(packed) == ["Default", "Default/Local Storage", "Default/Local Storage/leveldb",
                                        "Default/Local Storage/leveldb/000003.log", "cdp.log"])

            // Restoring next to the original needs another id, port and seed.
            let kept = try await ProfileBackup.restore(from: file, store: store, runtime: fixture.runtime, identity: .keepOriginal)
            #expect(kept.profiles.map(\.skipped) == ["本机已有 ID 相同的 Profile「\(saved.name)」。"])
            #expect(store.profiles.count == 1)

            let restored = try await ProfileBackup.restore(from: file, store: store, runtime: fixture.runtime, identity: .renew)
            #expect(restored.engineVersion == BundledVersions.engine)
            #expect(restored.warnings.isEmpty)
            let entry = try #require(restored.profiles.first)
            let copy = try #require(entry.profile)
            #expect(entry.skipped == nil)
            #expect(entry.browserData)
            #expect(entry.importedCookies == 0)
            #expect(copy.id != saved.id)
            #expect(copy.port != saved.port)
            #expect(copy.fingerprint.seed != saved.fingerprint.seed)
            #expect(copy.proxy == saved.proxy)
            #expect(store.profiles.map(\.id) == [saved.id, copy.id])
            let copied = fixture.runtime.dataDirectory(for: copy.id)
            #expect(try permissions(copied) == 0o700)
            #expect(listing(copied) == listing(packed))
            #expect(try String(contentsOf: copied.appendingPathComponent("Default/Local Storage/leveldb/000003.log"),
                               encoding: .utf8) == "Default/Local Storage/leveldb/000003.log")

            let renewed = try await ProfileBackup.restore(from: file, store: store, runtime: fixture.runtime,
                                                          identity: .keepOriginalOrRenew, selection: [saved.id, missing])
            #expect(renewed.profiles.count == 1)
            #expect(renewed.profiles[0].profile.map { $0.id != saved.id && $0.id != copy.id } == true)
            #expect(store.profiles.count == 3)
            await fixture.cleanUp(store.profiles)
        }
    }

    @Test("A running Profile keeps running, and its data directory stays out of the backup")
    func runningProfileStaysUp() async throws {
        let fixture = try FakeEngineFixture("backup-running")
        let store = try ProfileStore(directory: fixture.storage)
        try store.save(fixture.profile(port: 17401))
        let saved = store.profiles[0]
        try await fixture.run([saved]) {
            try await fixture.runtime.start(saved)
            guard case let .running(pid, _, true) = fixture.runtime.status(for: saved.id) else {
                Issue.record("Not running: \(fixture.runtime.status(for: saved.id))")
                return
            }
            let file = fixture.root.appendingPathComponent("running.anybrowser")
            let result = try await ProfileBackup.export([saved.id], to: file, store: store, runtime: fixture.runtime)
            #expect(result.profiles == [ProfileBackup.ExportedProfile(
                id: saved.id, name: saved.name, cookies: 0, browserData: false,
                warnings: ["未能导出 Cookie：浏览器返回的 Cookie 数据无法识别。",
                           "浏览器正在运行，没有备份浏览器资料（站点存储、扩展数据、历史记录等），停止后再备份可以包含它们。"])])
            #expect(fixture.runtime.status(for: saved.id) == .running(pid: pid, port: saved.port, debugReady: true))
            #expect(isAlive(pid))
            #expect(try open(file).profiles == [Entry(id: saved.id, name: saved.name, cookies: 0, browserData: false, profile: saved)])

            let other = try ProfileStore(directory: try scratchDirectory("backup-running-other"))
            defer { try? FileManager.default.removeItem(at: other.directory) }
            let runtime = BrowserRuntime(engine: fixture.engine, storage: other.directory)
            let restored = try await ProfileBackup.restore(from: file, store: other, runtime: runtime, identity: .keepOriginal)
            #expect(restored.profiles.map(\.profile) == [saved])
            #expect(restored.profiles[0].browserData == false)
            #expect(!FileManager.default.fileExists(atPath: runtime.dataDirectory(for: saved.id).path))
        }
    }

    @Test("Restoring starts the Profile headless with its own account to import its cookies, then stops it")
    func restoreImportsCookies() async throws {
        let fixture = try FakeEngineFixture("backup-cookies")
        let store = try ProfileStore(directory: fixture.storage)
        var saved = fixture.profile(port: 17402)
        saved.passkeyBox = PasskeyBoxAccount(serverURL: "https://passkeys.example", username: "own", password: "secret")
        saved = try saved.validated()
        // Made on another Mac: this store has never seen the Profile.
        let staging = try scratchDirectory("backup-cookies-package")
        defer { try? FileManager.default.removeItem(at: staging) }
        let expiry = Int(Date().timeIntervalSince1970) + 3600
        try write("""
            [{"name": "first", "value": "1", "domain": "127.0.0.1", "path": "/", "expires": \(expiry), "httpOnly": false, "secure": false},
             {"name": "second", "value": "2", "domain": ".example.com", "path": "/", "expires": -1, "httpOnly": true, "secure": true}]
            """, to: "Cookies.json", in: ProfileBackup.entryFolder(saved.id, in: staging))
        try ProfileBackup.write(manifest([Entry(id: saved.id, name: saved.name, cookies: 2, browserData: false, profile: saved)]),
                                in: staging)
        let file = fixture.root.appendingPathComponent("cookies.anybrowser")
        try ProfileBackup.pack(staging, to: file)

        try await fixture.run([saved]) {
            var headless: [Bool?] = []
            let restored = try await ProfileBackup.restore(from: file, store: store, runtime: fixture.runtime,
                                                           identity: .keepOriginal) { progress in
                if progress.message.contains("Cookie") { headless.append(runsHeadless(saved.id, fixture.runtime)) }
            }
            // The fake engine lists no cookies, which the import needs before it sets any; the engine
            // test covers a real browser's.
            #expect(restored.profiles == [ProfileBackup.RestoredProfile(
                originalID: saved.id, name: saved.name, profile: saved,
                warnings: ["Cookie 未能导入，在另一台 Mac 上恢复时可能需要重新登录：浏览器返回的 Cookie 数据无法识别。"])])
            #expect(store.profiles == [saved])
            #expect(headless == [true])
            #expect(fixture.commands(saved).map { $0["method"] as? String } == ["Storage.getCookies", "Browser.close"])
            #expect(fixture.runtime.status(for: saved.id) == .stopped)
            // The Profile's own account, kept in the backup, signed in for the import.
            let config = PasskeyBoxInstall.directory(in: fixture.storage, for: saved.id).appendingPathComponent("managed-config.json")
            #expect(try String(contentsOf: config, encoding: .utf8).contains("own"))
        }
    }
}

// Uses debugging port 9352.
@Suite(.serialized)
struct ProfileBackupEngineTests {
    @Test(
        "A backup restored as a new Profile elsewhere keeps its cookies and local storage, and leaves caches out",
        .enabled(
            if: testAppPath != nil,
            "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test."
        )
    )
    @MainActor
    func restoresSignIns() async throws {
        let engine = try testEngine()
        let source = try scratchDirectory("backup-source")
        let target = try scratchDirectory("backup-target")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let page = try await LoopbackPage.start(title: "AnyBrowser backup fixture")
        defer { page.listener.cancel() }
        let store = try ProfileStore(directory: source)
        var saved = try store.makeDraft()
        saved.port = testPort(9352)
        saved.proxy = ""
        try store.save(saved)
        // Run from a test, Chromium cannot keep its key in the login keychain and so persists no
        // cookies at all; both sides use the mock keychain, whose key is the same everywhere.
        let runtime = BrowserRuntime(engine: engine, storage: store.directory)
        runtime.additionalArguments = ["--use-mock-keychain"]
        try await runtime.start(saved)
        do {
            let tab = try await DevToolsPage.open(port: saved.port, url: page.url)
            defer { tab.socket.cancel(with: .normalClosure, reason: nil) }
            _ = try await tab.evaluate("document.cookie = 'signin=kept; max-age=86400; path=/'; localStorage.setItem('note', 'kept')")
            try await runtime.stop(saved.id)
        } catch {
            try? await runtime.stop(saved.id)
            throw error
        }
        let data = runtime.dataDirectory(for: saved.id)
        let caches = ["Default/Cache", "Default/Code Cache", "GPUCache"].filter {
            FileManager.default.fileExists(atPath: data.appendingPathComponent($0).path)
        }
        #expect(!caches.isEmpty, "The browser wrote no caches to leave out")

        let file = source.appendingPathComponent("backup.anybrowser")
        let exported = try await ProfileBackup.export([saved.id], to: file, store: store, runtime: runtime)
        #expect(exported.profiles.map(\.warnings) == [[]])
        let entry = try #require(exported.profiles.first)
        #expect(entry.browserData)
        #expect(entry.cookies == 1)
        #expect(runtime.status(for: saved.id) == .stopped)

        let unpacked = try scratchDirectory("backup-engine-unpacked")
        defer { try? FileManager.default.removeItem(at: unpacked) }
        try ProfileBackup.unpack(file, into: unpacked)
        let folder = ProfileBackup.entryFolder(saved.id, in: unpacked)
        let packed = listing(folder.appendingPathComponent("Data"))
        #expect(packed.contains("Default/Local Storage/leveldb"))
        #expect(packed.contains("Default/Cookies"))
        #expect(packed.filter { ProfileBackup.cacheDirectories.contains(($0 as NSString).lastPathComponent) }.isEmpty)

        // On another Mac the keychain holds another key. The copied cookies are re-encrypted with
        // an unknown one to match, so only the cookies the restore imports can be read.
        try reencrypt(folder.appendingPathComponent("Data/Default/Cookies"))
        let moved = source.appendingPathComponent("moved.anybrowser")
        try ProfileBackup.pack(unpacked, to: moved)
        let other = try ProfileStore(directory: target)
        let otherRuntime = BrowserRuntime(engine: engine, storage: other.directory)
        otherRuntime.additionalArguments = ["--use-mock-keychain"]
        let restored = try await ProfileBackup.restore(from: moved, store: other, runtime: otherRuntime, identity: .renew)
        let result = try #require(restored.profiles.first)
        let copy = try #require(result.profile)
        #expect(copy.id != saved.id)
        #expect(result.browserData)
        #expect(result.importedCookies == 1)
        #expect(result.warnings.isEmpty)
        #expect(otherRuntime.status(for: copy.id) == .stopped)

        try await otherRuntime.start(copy)
        do {
            let tab = try await DevToolsPage.open(port: copy.port, url: page.url)
            defer { tab.socket.cancel(with: .normalClosure, reason: nil) }
            #expect(try await tab.evaluate("document.cookie") as? String == "signin=kept")
            #expect(try await tab.evaluate("localStorage.getItem('note')") as? String == "kept")
            try await otherRuntime.stop(copy.id)
        } catch {
            try? await otherRuntime.stop(copy.id)
            throw error
        }
    }

    /// Replaces each stored cookie value with random bytes behind Chromium's "v10" prefix.
    private func reencrypt(_ database: URL) throws {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        try #require(sqlite3_open(database.path, &connection) == SQLITE_OK)
        try #require(sqlite3_exec(connection, """
            UPDATE cookies SET encrypted_value = X'763130' || randomblob(length(encrypted_value) - 3)
            WHERE length(encrypted_value) > 3
            """, nil, nil, nil) == SQLITE_OK)
        try #require(sqlite3_changes(connection) == 1)
    }
}
