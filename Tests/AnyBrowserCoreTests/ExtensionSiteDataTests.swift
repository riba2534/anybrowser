@testable import AnyBrowserCore
import CryptoKit
import Darwin
import Foundation
import Network
import Testing

// Clearing site data keeps what extensions store per origin. The fake engine listens on port 11970;
// the engine suite uses debug port 9420 (plus ANYBROWSER_TEST_PORT_OFFSET).

/// A data directory as Chromium leaves it, with an extension's entries beside the websites' where
/// it keeps one per origin.
private struct OriginLayout {
    static let extensionID = "kncbpedbpbkaoccdefeaejhidfbkhhed"
    let kept: [String]
    let deleted: [String]
    private let contents: [String: String]

    init() {
        let extensionOrigin = "chrome-extension_\(Self.extensionID)_0"
        let extensionCaches = Self.cacheStorage(extensionOrigin)
        let siteCaches = Self.cacheStorage("https_example.com_0")
        // A website's cache may have any name, an extension's address too.
        let decoyCaches = Self.cacheStorage("https_decoy.example_0")
        let extensionURL = "chrome-extension://\(Self.extensionID)/"
        contents = [
            extensionCaches + "/index.txt": "\n\u{3}\u{12}\u{1}c\u{12}4\(extensionURL)\u{1a}4\(extensionURL)",
            siteCaches + "/index.txt": "\n\u{3}\u{12}\u{4}site\u{12}\u{14}https://example.com/",
            decoyCaches + "/index.txt": "\n\u{3}\u{12}4\(extensionURL)\u{12}\u{16}https://decoy.example/",
        ]
        kept = [
            "Default/IndexedDB/\(extensionOrigin).indexeddb.leveldb/CURRENT",
            "Default/IndexedDB/\(extensionOrigin).indexeddb.blob/1/00/1",
            extensionCaches + "/index.txt",
            extensionCaches + "/88c59d7b-5472-4ffb-9625-2e75fd21971b/index",
            "Default/Local Extension Settings/\(Self.extensionID)/CURRENT",
            "Default/Preferences",
        ]
        deleted = [
            "Default/IndexedDB/https_example.com_0.indexeddb.leveldb/CURRENT",
            "Default/IndexedDB/http_127.0.0.1_8080.indexeddb.blob/1/00/1",
            "Default/Service Worker/Database/CURRENT",
            "Default/Service Worker/ScriptCache/index",
            siteCaches + "/index.txt",
            decoyCaches + "/index.txt",
            // Never indexed, so Chromium cannot read it either.
            Self.cacheStorage("https_unindexed.example_0") + "/09e5c347-722d-4869-9f78-a1da70a8b37e/index",
            "Default/WebStorage/QuotaManager",
            "Default/Local Storage/leveldb/CURRENT",
            "Default/File System/Origins/CURRENT",
            "Default/Network/Cookies",
        ]
    }

    static func cacheStorage(_ identifier: String) -> String {
        "Default/Service Worker/CacheStorage/" + Insecure.SHA1.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func write(in root: URL) throws {
        for relative in kept + deleted {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data((contents[relative] ?? "kept").utf8).write(to: file)
        }
    }

    func check(in root: URL) {
        for relative in kept {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path), "kept \(relative)")
        }
        for relative in deleted {
            let url = root.appendingPathComponent(relative)
            var details = stat()
            #expect(lstat(url.path, &details) != 0, "deleted \(relative)")
        }
        // Only the websites' entries went, not the directories holding the extension's.
        let caches = root.appendingPathComponent(Self.cacheStorage("chrome-extension_\(Self.extensionID)_0"))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: caches.deletingLastPathComponent().path))
                == [caches.lastPathComponent])
    }
}

@MainActor
struct ExtensionSiteDataTests {
    @Test("Clearing a stopped Profile keeps an extension's IndexedDB and Cache Storage and deletes the websites'")
    func clearingKeepsExtensionEntries() async throws {
        let storage = try scratchDirectory("extension-site-data")
        defer { try? FileManager.default.removeItem(at: storage) }
        let engine = BrowserEngine(version: "test", executable: URL(fileURLWithPath: "/bin/true"),
                                   passkeyBoxDirectory: URL(fileURLWithPath: "/tmp/anybrowser-test-extension"))
        let runtime = BrowserRuntime(engine: engine, storage: storage)
        let id = UUID()
        let root = runtime.dataDirectory(for: id)
        try PrivateDirectory.ensure(root)
        let layout = OriginLayout()
        try layout.write(in: root)
        try await runtime.clearSiteData(for: id)
        layout.check(in: root)
    }

    @Test("A launch that resets site data keeps the extension's entries as well")
    func resetAtLaunchKeepsExtensionEntries() async throws {
        let fake = try FakeEngineFixture("extension-site-data-launch")
        let profile = fake.profile(port: testPort(11970))
        let layout = OriginLayout()
        try layout.write(in: fake.runtime.dataDirectory(for: profile.id))
        try await fake.run([profile]) {
            let outcome = try await fake.runtime.start(profile, overrides: LaunchOverrides(urls: [], resetSiteData: true))
            #expect(outcome.startedFresh)
            try await fake.runtime.stop(profile.id)
            layout.check(in: fake.runtime.dataDirectory(for: profile.id))
        }
    }
}

// MARK: Real engine

/// A wallet-like extension that keeps a secret in each kind of storage an extension page has, and
/// answers messages from its service worker.
private func makeWallet(in root: URL) throws -> URL {
    try makeExtension(at: root.appendingPathComponent("Wallet", isDirectory: true), manifest: """
        {"manifest_version": 3, "name": "Site data wallet", "version": "1.0", "permissions": ["storage"],
         "background": {"service_worker": "worker.js"}}
        """, files: [
        "worker.js": "chrome.runtime.onMessage.addListener((message, sender, reply) => { reply('pong'); });",
        "vault.html": #"<!doctype html><title>vault</title><script src="vault.js"></script>"#,
        // Reports what is stored, then stores what is missing.
        "vault.js": """
            (async () => {
              const found = {};
              const db = await new Promise((resolve, reject) => {
                const open = indexedDB.open('vault', 1);
                open.onupgradeneeded = () => open.result.createObjectStore('keys');
                open.onsuccess = () => resolve(open.result);
                open.onerror = () => reject(open.error);
              });
              found.indexedDB = await new Promise(resolve => {
                const read = db.transaction('keys').objectStore('keys').get('seed');
                read.onsuccess = () => resolve(read.result ?? null);
              });
              const cache = await caches.open('vault');
              found.cacheStorage = await cache.match('https://vault.invalid/seed').then(r => r ? r.text() : null);
              found.storage = (await chrome.storage.local.get('seed')).seed ?? null;
              found.localStorage = localStorage.getItem('seed');
              found.worker = await chrome.runtime.sendMessage('ping').catch(error => String(error));
              await new Promise(resolve => {
                const write = db.transaction('keys', 'readwrite');
                write.objectStore('keys').put('idb-seed', 'seed');
                write.oncomplete = resolve;
              });
              await cache.put('https://vault.invalid/seed', new Response('cache-seed'));
              await chrome.storage.local.set({ seed: 'storage-seed' });
              localStorage.setItem('seed', 'local-seed');
              document.title = JSON.stringify(found);
            })().catch(error => { document.title = 'error: ' + error; });
            """,
    ])
}

/// A website that reports its own storage the same way.
private let siteScript = """
    <script>
    (async () => {
      const found = {};
      found.localStorage = localStorage.getItem('seed');
      found.indexedDB = (await indexedDB.databases()).map(db => db.name);
      found.cacheStorage = await caches.has('site');
      localStorage.setItem('seed', 'site-seed');
      await new Promise(resolve => {
        const open = indexedDB.open('site', 1);
        open.onupgradeneeded = () => open.result.createObjectStore('keys');
        open.onsuccess = () => {
          const write = open.result.transaction('keys', 'readwrite');
          write.objectStore('keys').put('site-seed', 'seed');
          write.oncomplete = resolve;
        };
      });
      await (await caches.open('site')).put('/seed', new Response('site-seed'));
      document.title = JSON.stringify(found);
    })().catch(error => { document.title = 'error: ' + error; });
    </script>
    """

@Suite("Extension site data engine", .serialized,
       .enabled(if: testAppPath != nil, "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test."))
@MainActor
struct ExtensionSiteDataEngineTests {
    /// The JSON a page reports in its title, opened in a new tab of the Profile's browser.
    private func report(_ runtime: BrowserRuntime, _ id: UUID, url: String) async throws -> [String: Any] {
        let client = try DevToolsClient(endpoint: try #require(await runtime.devToolsEndpoint(for: id)))
        defer { client.close() }
        let target = try #require(try await client.send("Target.createTarget", ["url": url])["targetId"] as? String)
        let session = try #require(try await client.send("Target.attachToTarget", ["targetId": target, "flatten": true])["sessionId"] as? String)
        for _ in 0..<60 {
            let result = try await client.send("Runtime.evaluate", ["expression": "document.title", "returnByValue": true],
                                               sessionId: session)
            let title = (result["result"] as? [String: Any])?["value"] as? String ?? ""
            if title.hasPrefix("error") { throw VerificationFailure.message(title) }
            if title.hasPrefix("{") {
                _ = try? await client.send("Target.closeTarget", ["targetId": target])
                return try #require(JSONSerialization.jsonObject(with: Data(title.utf8)) as? [String: Any])
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw VerificationFailure.message("\(url) reported nothing")
    }

    /// The extension's id, once its service worker runs.
    private func walletID(_ runtime: BrowserRuntime, _ id: UUID) async throws -> String {
        let client = try DevToolsClient(endpoint: try #require(await runtime.devToolsEndpoint(for: id)))
        defer { client.close() }
        for _ in 0..<60 {
            let targets = try await client.send("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
            if let url = targets.compactMap({ $0["url"] as? String }).first(where: { $0.hasSuffix("/worker.js") }),
               let host = URLComponents(string: url)?.host {
                return host
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw VerificationFailure.message("The extension's service worker did not start")
    }

    @Test("A new identity's launch deletes the websites' storage but not what an extension keeps in IndexedDB and Cache Storage")
    func extensionDataSurvivesReset() async throws {
        let root = try scratchDirectory("extension-site-data-engine")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = BrowserRuntime(engine: try testEngine(), storage: root.appendingPathComponent("Storage", isDirectory: true))
        var profile = BrowserProfile(name: "Site data", port: testPort(9420), fingerprint: FingerprintSettings(seed: 4_249_420), proxy: "")
        profile.launch.extensionDirectories = [try makeWallet(in: root).path]
        profile.launch.loadPasskeyBox = false
        let site = try await LoopbackPage.start(title: "site", content: siteScript)
        defer { site.listener.cancel() }
        do {
            try await runtime.start(profile, overrides: LaunchOverrides(urls: []))
            let wallet = try await walletID(runtime, profile.id)
            let vault = "chrome-extension://\(wallet)/vault.html"
            let empty = try await report(runtime, profile.id, url: vault)
            #expect(empty["indexedDB"] is NSNull && empty["storage"] is NSNull && empty["worker"] as? String == "pong")
            _ = try await report(runtime, profile.id, url: site.url.absoluteString)
            let stored = try await report(runtime, profile.id, url: site.url.absoluteString)
            #expect(stored["localStorage"] as? String == "site-seed" && stored["cacheStorage"] as? Bool == true)
            #expect(stored["indexedDB"] as? [String] == ["site"])
            try await runtime.stop(profile.id)

            try await runtime.start(profile, overrides: LaunchOverrides(urls: [], resetSiteData: true))
            _ = try await walletID(runtime, profile.id)
            let kept = try await report(runtime, profile.id, url: vault)
            #expect(kept["indexedDB"] as? String == "idb-seed")
            #expect(kept["cacheStorage"] as? String == "cache-seed")
            #expect(kept["storage"] as? String == "storage-seed")
            // Its service worker was registered again.
            #expect(kept["worker"] as? String == "pong")
            // One database for every origin, so it goes with the websites', as the editor says.
            #expect(kept["localStorage"] is NSNull)
            let cleared = try await report(runtime, profile.id, url: site.url.absoluteString)
            #expect(cleared["localStorage"] is NSNull && cleared["cacheStorage"] as? Bool == false)
            #expect(cleared["indexedDB"] as? [String] == [])
            try await runtime.stop(profile.id)
        } catch {
            try? await runtime.stop(profile.id, force: true)
            throw error
        }
    }
}
