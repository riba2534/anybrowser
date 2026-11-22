@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

// Debugging port 9362 belongs to this suite.
@Suite("Shared extension library", .serialized)
struct SharedExtensionTests {
    @Test("Folders are copied in under a name taken from the manifest, numbered when taken")
    func addsFolders() throws {
        let (root, storage) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeExtension(at: root.appendingPathComponent("My Ext"),
                                       manifest: #"{"manifest_version":3,"name":"Wallet: Pro ✨","version":"1.2.3"}"#,
                                       files: ["background.js": "one", "icons/16.png": "png"])
        let library = SharedExtensions.root(in: storage)
        #expect(library.path == storage.path + "/Extensions/Shared")
        #expect(SharedExtensions.list(in: storage).isEmpty)

        let added = try SharedExtensions.add(folder: source, in: storage)
        #expect(added == SharedExtension(name: "Wallet Pro", manifestName: "Wallet: Pro ✨", version: "1.2.3",
                                         directory: library.appendingPathComponent("Wallet Pro", isDirectory: true), isValid: true))
        #expect(try String(contentsOf: added.directory.appendingPathComponent("icons/16.png"), encoding: .utf8) == "png")
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path))
        #expect(try permissions(library) == 0o700)
        #expect(try permissions(library.deletingLastPathComponent()) == 0o700)
        #expect(try permissions(added.directory) == 0o700)

        // A second copy never replaces the first, including a name that only differs in case.
        try Data("two".utf8).write(to: source.appendingPathComponent("background.js"))
        #expect(try SharedExtensions.add(folder: source, in: storage).name == "Wallet Pro 2")
        try Data(#"{"manifest_version":3,"name":"wallet pro","version":"2"}"#.utf8)
            .write(to: source.appendingPathComponent("manifest.json"))
        let third = try SharedExtensions.add(folder: source, in: storage)
        #expect(["wallet pro", "wallet pro 3"].contains(third.name))
        #expect(try String(contentsOf: added.directory.appendingPathComponent("background.js"), encoding: .utf8) == "one")
        let versions = Dictionary(uniqueKeysWithValues: SharedExtensions.list(in: storage).map { ($0.name, $0.version) })
        #expect(versions == ["Wallet Pro": "1.2.3", "Wallet Pro 2": "1.2.3", third.name: "2"])

        // A link to the folder is followed; Chromium-style comments in the manifest are accepted.
        let other = try makeExtension(at: root.appendingPathComponent("Other"), manifest: """
        // Comments are allowed.
        {"manifest_version": 3, /* inline */ "name": "Other", "version": "0.1",}
        """)
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        let linked = try SharedExtensions.add(folder: link, in: storage)
        #expect(linked.name == "Other")
        #expect(try FileManager.default.attributesOfItem(atPath: linked.directory.path)[.type] as? FileAttributeType == .typeDirectory)
        #expect(try hidden(in: library) == [".lock"])
    }

    /// Pins the trade-off in `SharedExtensions`: a key per Profile would change the IDs, and with them
    /// the extension data, of entries Profiles already use.
    @Test("A folder keeps its manifest as it is, so without a key every Profile loads it under one path-based ID")
    func foldersKeepTheirManifest() throws {
        let (root, storage) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = #"{"manifest_version":3,"name":"Wallet","version":"1"}"#
        let keyed = #"{"manifest_version":3,"name":"Keyed","version":"1","key":"MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A"}"#
        let wallet = try SharedExtensions.add(folder: makeExtension(at: root.appendingPathComponent("Wallet"), manifest: plain),
                                              in: storage)
        let own = try SharedExtensions.add(folder: makeExtension(at: root.appendingPathComponent("Keyed"), manifest: keyed),
                                           in: storage)
        let manifest = { (entry: SharedExtension) in
            try String(contentsOf: entry.directory.appendingPathComponent("manifest.json"), encoding: .utf8)
        }
        #expect(try manifest(wallet) == plain)
        #expect(try manifest(own) == keyed)

        let profiles = (1...2).map { seed in
            var profile = BrowserProfile(name: "P\(seed)", port: 9300 + seed, fingerprint: FingerprintSettings(seed: seed))
            profile.launch.loadPasskeyBox = false
            profile.launch.sharedExtensions = [wallet.name]
            return profile
        }
        #expect(profiles.map { ProfileExtensions.paths(for: $0, in: storage).map(\.path) }
            == [[wallet.directory.path], [wallet.directory.path]])
    }

    @Test("Localized names come from the default locale, else the folder name stands in")
    func localizedNames() throws {
        let (root, storage) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let localized = try makeExtension(
            at: root.appendingPathComponent("loc"),
            manifest: #"{"manifest_version":3,"name":"__MSG_appName__","version":"1","default_locale":"en_US"}"#,
            files: ["_locales/en_US/messages.json": #"{"AppName":{"message":"Translated Name"}}"#]
        )
        let added = try SharedExtensions.add(folder: localized, in: storage)
        #expect(added.name == "Translated Name")
        #expect(added.manifestName == "Translated Name")

        let unresolved = try makeExtension(at: root.appendingPathComponent("nkbihfbeogaeaoehlefnkodbefgpgknn"),
                                           manifest: #"{"manifest_version":3,"name":"__MSG_missing__","version":"1"}"#)
        let fallback = try SharedExtensions.add(folder: unresolved, in: storage)
        #expect(fallback.name == "nkbihfbeogaeaoehlefnkodbefgpgknn")
        #expect(fallback.manifestName == "__MSG_missing__")
    }

    @Test("Folder names are reduced to what a shared extension name allows")
    func folderNames() {
        #expect(SharedExtensions.folderName(for: "uBlock Origin", fallback: "x") == "uBlock Origin")
        #expect(SharedExtensions.folderName(for: "Dark Reader: night mode", fallback: "x") == "Dark Reader night mode")
        #expect(SharedExtensions.folderName(for: "...Google 翻译 ", fallback: "x") == "Google")
        #expect(SharedExtensions.folderName(for: "-_v2.0", fallback: "x") == "v2.0")
        #expect(SharedExtensions.folderName(for: "翻译", fallback: "my-ext") == "my-ext")
        #expect(SharedExtensions.folderName(for: "翻译", fallback: "扩展") == "Extension")
        #expect(SharedExtensions.folderName(for: "__MSG_name__", fallback: "fallback") == "fallback")
        let long = SharedExtensions.folderName(for: String(repeating: "a", count: 63) + " b c", fallback: "x")
        #expect(long == String(repeating: "a", count: 63))
        for name in ["uBlock Origin", "Google", "v2.0", long] {
            #expect(LaunchOptions.isSharedExtensionName(name))
        }
    }

    @Test("Folders without a valid manifest are refused and leave nothing behind")
    func refusesInvalidFolders() throws {
        let (root, storage) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        let notAFolder = "请选择扩展所在的文件夹"
        let missing = "缺少 manifest.json"
        var sources = [(empty, missing), (file, notAFolder), (root.appendingPathComponent("Missing"), notAFolder)]
        for (index, manifest) in [
            "not json", "[1]", #"{"name":"A","version":"1"}"#, #"{"manifest_version":3,"version":"1"}"#,
            #"{"manifest_version":3,"name":"","version":"1"}"#, #"{"manifest_version":3,"name":"A"}"#,
            #"{"manifest_version":"3","name":"A","version":"1"}"#,
        ].enumerated() {
            sources.append((try makeExtension(at: root.appendingPathComponent("Bad\(index)"), manifest: manifest), "manifest.json 无效"))
        }
        let linked = root.appendingPathComponent("LinkedManifest", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        let real = try makeExtension(at: root.appendingPathComponent("Real"), manifest: #"{"manifest_version":3,"name":"A","version":"1"}"#)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("manifest.json"),
                                                   withDestinationURL: real.appendingPathComponent("manifest.json"))
        sources.append((linked, missing))

        for (source, message) in sources {
            try expectFailure(containing: message) { try SharedExtensions.add(folder: source, in: storage) }
        }
        #expect(SharedExtensions.list(in: storage).isEmpty)
        let library = SharedExtensions.root(in: storage)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []).allSatisfy { $0 == ".lock" })
    }

    @Test("CRX3 files are unpacked into the library and keep their Web Store key")
    func addsCRXFiles() throws {
        let (root, storage) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data((0..<294).map { UInt8($0 % 251) })
        let decoy = Data(repeating: 7, count: 270)
        let manifest = """
        {
          // From the store.
          "manifest_version": 3, "name": "Store Wallet", "version": "11.4.2"
        }
        """
        let file = try makeCRX(at: root.appendingPathComponent("wallet.crx"), in: root, manifest: manifest,
                               files: ["background.js": "worker", "_metadata/verified_contents.json": "[]"],
                               keys: [decoy, key], crxID: crxID(key))

        let added = try SharedExtensions.add(crx: file, in: storage)
        #expect(added.name == "Store Wallet")
        #expect(added.version == "11.4.2")
        #expect(try String(contentsOf: added.directory.appendingPathComponent("background.js"), encoding: .utf8) == "worker")
        #expect(FileManager.default.fileExists(atPath: added.directory.appendingPathComponent("_metadata/verified_contents.json").path))
        let text = try String(contentsOf: added.directory.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(text.contains("// From the store."))
        let written = try #require(JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed]) as? [String: Any])
        #expect(written["key"] as? String == key.base64EncodedString())
        #expect(written["name"] as? String == "Store Wallet")
        #expect(try hidden(in: SharedExtensions.root(in: storage)) == [".lock"])

        // A manifest with its own key keeps it; without a matching CRX ID no key is added.
        let own = try makeCRX(at: root.appendingPathComponent("own.crx"), in: root,
                              manifest: #"{"manifest_version":3,"name":"Own","version":"1","key":"AAAA"}"#,
                              keys: [key], crxID: crxID(key))
        let ownManifest = try Data(contentsOf: try SharedExtensions.add(crx: own, in: storage).directory.appendingPathComponent("manifest.json"))
        #expect(String(decoding: ownManifest, as: UTF8.self) == #"{"manifest_version":3,"name":"Own","version":"1","key":"AAAA"}"#)
        let unmatched = try makeCRX(at: root.appendingPathComponent("unmatched.crx"), in: root,
                                    manifest: #"{"manifest_version":3,"name":"Plain","version":"1"}"#,
                                    keys: [key], crxID: Data(repeating: 0, count: 16))
        let plain = try Data(contentsOf: try SharedExtensions.add(crx: unmatched, in: storage).directory.appendingPathComponent("manifest.json"))
        #expect(String(decoding: plain, as: UTF8.self) == #"{"manifest_version":3,"name":"Plain","version":"1"}"#)
    }

    @Test("Files that are not CRX3 extensions are refused and leave nothing behind")
    func refusesInvalidCRXFiles() throws {
        let (root, storage) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try makeCRX(at: root.appendingPathComponent("valid.crx"), in: root,
                                manifest: #"{"manifest_version":3,"name":"A","version":"1"}"#, keys: [], crxID: nil)
        let bytes = try Data(contentsOf: valid)
        let zipStart = 12 + (Int(bytes[8]) | Int(bytes[9]) << 8)
        let noManifest = try makeCRX(at: root.appendingPathComponent("nomanifest.crx"), in: root, manifest: nil,
                                     files: ["background.js": "x"], keys: [], crxID: nil)

        let notCRX = "不是有效的 CRX 扩展文件"
        let cases: [(String, Data, String)] = [
            ("empty", Data(), notCRX),
            ("short", Data("Cr24".utf8), notCRX),
            ("zip", bytes[zipStart...], notCRX),
            ("bad magic", Data("Cr25".utf8) + bytes[4...], notCRX),
            ("crx2", Data("Cr24".utf8) + le32(2) + bytes[8...], "只支持 CRX3"),
            ("long header", bytes.prefix(8) + le32(UInt32(bytes.count - 11)) + bytes[12...], notCRX),
            ("not a zip", bytes.prefix(zipStart) + Data("not a zip archive".utf8), notCRX),
            ("broken zip", bytes.prefix(zipStart) + Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 64), "无法解压"),
            ("no manifest", try Data(contentsOf: noManifest), "缺少 manifest.json"),
        ]
        for (label, data, message) in cases {
            let file = root.appendingPathComponent("\(label).crx")
            try data.write(to: file)
            try expectFailure(containing: message) { try SharedExtensions.add(crx: file, in: storage) }
        }
        try expectFailure(containing: "请选择 .crx 扩展文件") { try SharedExtensions.add(crx: root, in: storage) }
        try expectFailure(containing: "无法读取 CRX 扩展文件") {
            try SharedExtensions.add(crx: root.appendingPathComponent("missing.crx"), in: storage)
        }
        #expect(SharedExtensions.list(in: storage).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: SharedExtensions.root(in: storage).path) == [".lock"])

        #expect(try SharedExtensions.add(crx: valid, in: storage).name == "A")
    }

    @Test("Removing takes an extension out of the library; leftovers of interrupted changes are cleared")
    func removesExtensions() throws {
        let (root, storage) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try SharedExtensions.remove("Anything", in: storage)
        let source = try makeExtension(at: root.appendingPathComponent("Ext"), manifest: #"{"manifest_version":3,"name":"Ext","version":"1"}"#)
        let added = try SharedExtensions.add(folder: source, in: storage)
        let library = SharedExtensions.root(in: storage)
        for name in [".incoming-\(UUID().uuidString)", ".incoming-\(UUID().uuidString).zip", ".removing-\(UUID().uuidString)"] {
            try FileManager.default.createDirectory(at: library.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        try SharedExtensions.remove(added.name, in: storage)
        #expect(SharedExtensions.list(in: storage).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path) == [".lock"])
        try SharedExtensions.remove(added.name, in: storage)
        for invalid in ["", "../Ext", ".lock", "a/b", "a,b"] {
            #expect(throws: ProfileError.self, "\(invalid)") { try SharedExtensions.remove(invalid, in: storage) }
        }

        // A link in the library is removed without touching what it points to.
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("Linked"), withDestinationURL: source)
        #expect(SharedExtensions.list(in: storage).map(\.name) == ["Linked"])
        try SharedExtensions.remove("Linked", in: storage)
        #expect(SharedExtensions.list(in: storage).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path))
    }

    @Test("The list shows broken entries as invalid and skips anything that is not an entry")
    func listsEntries() throws {
        let (root, storage) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SharedExtensions.root(in: storage)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Broken"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data().write(to: library.appendingPathComponent("file"))
        _ = try makeExtension(at: library.appendingPathComponent("Good"), manifest: #"{"manifest_version":3,"name":"G","version":"3"}"#)
        #expect(SharedExtensions.list(in: storage) == [
            SharedExtension(name: "Broken", manifestName: "", version: "",
                            directory: library.appendingPathComponent("Broken", isDirectory: true), isValid: false),
            SharedExtension(name: "Good", manifestName: "G", version: "3",
                            directory: library.appendingPathComponent("Good", isDirectory: true), isValid: true),
        ])
    }

    @Test("Profiles load the shared extensions they pick, in order, before their own directories")
    func pathOrder() {
        let storage = URL(fileURLWithPath: "/tmp/anybrowser-storage", isDirectory: true)
        var profile = BrowserProfile(name: "Shared", port: 9301, fingerprint: FingerprintSettings(seed: 3),
                                     proxy: "http://user:pass@127.0.0.1:8080")
        profile.launch.sharedExtensions = ["Wallet", "Ad Block"]
        profile.launch.extensionDirectories = ["/Users/me/Ext"]
        let own = "/tmp/anybrowser-storage/Extensions/\(profile.id.uuidString.lowercased())"
        #expect(ProfileExtensions.paths(for: profile, in: storage).map(\.path) == [
            own + "/PasskeyBox",
            "/tmp/anybrowser-storage/Extensions/Shared/Wallet", "/tmp/anybrowser-storage/Extensions/Shared/Ad Block",
            "/Users/me/Ext",
        ])
        profile.launch.loadPasskeyBox = false
        profile.proxy = ""
        #expect(ProfileExtensions.paths(for: profile, in: storage).map(\.path) == [
            "/tmp/anybrowser-storage/Extensions/Shared/Wallet", "/tmp/anybrowser-storage/Extensions/Shared/Ad Block",
            "/Users/me/Ext",
        ])
    }

    @Test("A Profile does not start when a shared extension it loads is missing or broken")
    func checksBeforeLaunch() throws {
        let (root, storage) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeExtension(at: root.appendingPathComponent("Ext"), manifest: #"{"manifest_version":3,"name":"Wallet","version":"1"}"#)
        try SharedExtensions.add(folder: source, in: storage)
        var profile = BrowserProfile(name: "Shared", port: 9301, fingerprint: FingerprintSettings(seed: 3))
        try ProfileExtensions.check(for: profile, in: storage)
        profile.launch.sharedExtensions = ["Wallet"]
        try ProfileExtensions.check(for: profile, in: storage)
        #expect(SharedExtensions.unavailable(["Wallet"], in: storage).isEmpty)

        profile.launch.sharedExtensions = ["Wallet", "Gone"]
        #expect(SharedExtensions.unavailable(profile.launch.sharedExtensions, in: storage) == ["Gone"])
        try expectFailure(containing: "共享扩展「Gone」已不在扩展库中") { try ProfileExtensions.check(for: profile, in: storage) }

        try FileManager.default.removeItem(at: SharedExtensions.directory(named: "Wallet", in: storage).appendingPathComponent("manifest.json"))
        profile.launch.sharedExtensions = ["Wallet"]
        #expect(SharedExtensions.unavailable(["Wallet"], in: storage) == ["Wallet"])
        try expectFailure(containing: "共享扩展「Wallet」缺少 manifest.json") { try ProfileExtensions.check(for: profile, in: storage) }

        profile.launch.sharedExtensions = ["../Ext"]
        try expectFailure(containing: "共享扩展名称无效") { try ProfileExtensions.check(for: profile, in: storage) }

        // Chromium splits --load-extension at commas.
        let comma = root.appendingPathComponent("a,b", isDirectory: true)
        profile.launch.sharedExtensions = []
        try expectFailure(containing: "逗号") { try ProfileExtensions.check(for: profile, in: comma) }
    }

    @Test(
        "Shared extensions load in the browser, with the CRX's Web Store ID",
        .enabled(
            if: testAppPath != nil,
            "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test."
        )
    )
    @MainActor
    func loadsSharedExtensions() async throws {
        let engine = try testEngine()
        let (root, storage) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data((0..<294).map { UInt8($0 % 241) })
        let crx = try makeCRX(at: root.appendingPathComponent("store.crx"), in: root,
                              manifest: #"{"manifest_version":3,"name":"Shared CRX","version":"1","background":{"service_worker":"crx-worker.js"}}"#,
                              files: ["crx-worker.js": ""], keys: [key], crxID: crxID(key))
        let folder = try makeExtension(at: root.appendingPathComponent("Folder"),
                                       manifest: #"{"manifest_version":3,"name":"Shared Folder","version":"1","background":{"service_worker":"folder-worker.js"}}"#,
                                       files: ["folder-worker.js": ""])
        let fromCRX = try SharedExtensions.add(crx: crx, in: storage)
        let fromFolder = try SharedExtensions.add(folder: folder, in: storage)

        var profile = BrowserProfile(name: "Shared extensions", port: testPort(9362),
                                     fingerprint: FingerprintSettings(seed: 9362), proxy: "")
        profile.launch.loadPasskeyBox = false
        profile.launch.sharedExtensions = [fromCRX.name, fromFolder.name]
        let runtime = BrowserRuntime(engine: engine, storage: storage)
        try await runtime.start(profile)
        do {
            let workers = { (targets: [[String: Any]]) in
                targets.filter { $0["type"] as? String == "service_worker" }.compactMap { $0["url"] as? String }
            }
            let crxWorker = "chrome-extension://\(Self.extensionID(key))/crx-worker.js"
            let targets = try await DevToolsPage.waitForTargets(port: profile.port) { targets in
                workers(targets).contains(crxWorker) && workers(targets).contains { $0.hasSuffix("/folder-worker.js") }
            }
            #expect(!workers(targets).contains { $0.contains("gfejlnakeokbjdhoionfappnfepjoili") })
            var details = stat()
            #expect(lstat(PasskeyBoxInstall.directory(in: storage, for: profile.id).path, &details) != 0)
            try await runtime.stop(profile.id)
        } catch {
            try? await runtime.stop(profile.id)
            throw error
        }
    }

    // MARK: - Helpers

    /// A scratch directory and the storage directory inside it.
    private func scratch() throws -> (root: URL, storage: URL) {
        let root = try scratchDirectory("shared")
        let storage = root.appendingPathComponent("Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        return (root, storage)
    }

    /// Chromium's extension ID for a public key: the CRX ID written with the letters a–p.
    private static func extensionID(_ key: Data) -> String {
        crxID(key).map { String([Character(UnicodeScalar(97 + $0 >> 4)), Character(UnicodeScalar(97 + $0 & 15))]) }.joined()
    }
}
