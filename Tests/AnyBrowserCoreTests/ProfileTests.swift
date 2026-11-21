import AnyBrowserCore
import Foundation
import Testing

struct ProfileTests {
    @Test("Unique ports and seeds survive reopening the store")
    func uniquePortsAndSeedsSurviveReopeningStore() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }

            let store = try ProfileStore(directory: directory)
            let first = try store.makeDraft()
            #expect(first.port == 9222)
            try store.save(first)

            var second = try store.makeDraft()
            #expect(second.port == 9223)
            #expect(first.fingerprint.seed != second.fingerprint.seed)
            second.port = first.port
            #expect(throws: (any Error).self) { try store.save(second) }
            second.port = 9223
            second.fingerprint.seed = first.fingerprint.seed
            #expect(throws: (any Error).self) { try store.save(second) }

            second = try store.randomize(second, fields: [.seed, .language, .timeZone])
            try store.save(second)
            let reopened = try ProfileStore(directory: directory)
            #expect(reopened.profiles == [first, second])
            #expect(first.fingerprint.seed != second.fingerprint.seed)
            #expect(second.port == 9223)
            #expect(second.fingerprint.platform == nil)

            let dataDirectory = directory.appendingPathComponent(first.id.uuidString)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: false)
            try reopened.remove(first.id)
            #expect(try ProfileStore(directory: directory).profiles == [second])
            #expect(FileManager.default.fileExists(atPath: dataDirectory.path))
        }
    }

    @Test("Typed settings compile into separate launch arguments")
    func typedSettingsCompileIntoSeparateArguments() throws {
        var fingerprint = FingerprintSettings(seed: 87)
        fingerprint.platform = .macOS
        fingerprint.platformVersion = "26.2.0"
        fingerprint.brand = .edge
        fingerprint.brandVersion = "148.0.3967.54"
        fingerprint.cpuCount = 12
        fingerprint.language = "zh-CN"
        fingerprint.timeZone = "Asia/Shanghai"
        fingerprint.adjustments = [.canvas, .clientRects]

        let userDataDirectory = URL(fileURLWithPath: "/tmp/AnyBrowser Testing/Profile Space")
        let profile = try BrowserProfile(name: "Test", port: 9235, fingerprint: fingerprint).validated()
        let arguments = profile.launchArguments(userDataDirectory: userDataDirectory)
        #expect(arguments.contains("--user-data-dir=/tmp/AnyBrowser Testing/Profile Space"))
        #expect(arguments.contains("--remote-debugging-port=9235"))
        #expect(arguments.contains("--proxy-server=http://127.0.0.1:7890"))
        #expect(arguments.contains("--fingerprint=87"))
        #expect(arguments.contains("--fingerprint-platform=macos"))
        #expect(arguments.contains("--fingerprint-platform-version=26.2.0"))
        #expect(arguments.contains("--fingerprint-brand=Edge"))
        #expect(arguments.contains("--fingerprint-brand-version=148.0.3967.54"))
        #expect(arguments.contains("--fingerprint-hardware-concurrency=12"))
        #expect(arguments.contains("--accept-lang=zh-CN,zh"))
        #expect(arguments.contains("--timezone=Asia/Shanghai"))
        #expect(arguments.contains("--disable-spoofing=font,audio,gpu"))
    }

    @Test("Proxy addresses are validated and legacy profiles decode")
    func proxyAddressesAndLegacyProfiles() throws {
        let home = URL(fileURLWithPath: "/tmp/AnyBrowser Profile")
        var profile = BrowserProfile(name: "Proxy", port: 9222, fingerprint: FingerprintSettings(seed: 1))
        let encoded = try JSONEncoder().encode(profile)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "proxy")
        let decoded = try JSONDecoder().decode(BrowserProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded == profile)

        profile.proxy = " SOCKS5://[::1]:7891/ "
        #expect(try profile.validated().launchArguments(userDataDirectory: home)
            .contains("--proxy-server=socks5://[::1]:7891"))
        profile.proxy = "https://proxy.example:443"
        #expect(try profile.validated().launchArguments(userDataDirectory: home)
            .contains("--proxy-server=https://proxy.example:443"))

        profile.proxy = ""
        let reopened = try JSONDecoder().decode(BrowserProfile.self, from: JSONEncoder().encode(profile))
        #expect(reopened.proxy == "")
        #expect(!reopened.launchArguments(userDataDirectory: home).contains { $0.hasPrefix("--proxy-server=") })

        for address in ["localhost", "localhost:0", "localhost:65536", "http://proxy:80/path",
                        "socks5://name:secret@localhost:7890", "localhost:7890 --other-flag",
                        "http://proxy:80;direct://", "http://[not-an-ip]:7890", "http://-proxy:443"] {
            profile.proxy = address
            #expect(throws: (any Error).self, "\(address)") { try profile.validated() }
        }
    }

    @Test("Invalid configuration cannot be saved")
    func invalidConfigurationCannotBeSaved() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try ProfileStore(directory: directory)
            var draft = try store.makeDraft()
            draft.fingerprint.language = "en-US --remote-debugging-port=9444"
            #expect(throws: (any Error).self) { try store.save(draft) }
            draft.fingerprint.language = "en-US"
            draft.fingerprint.platformVersion = "26.1"
            #expect(throws: (any Error).self) { try store.save(draft) }
            draft.fingerprint.platform = .macOS
            draft.port = 65536
            #expect(throws: (any Error).self) { try store.save(draft) }
            #expect(store.profiles.isEmpty)
        }
    }

    @Test("Randomizing versions requires their base fields")
    func randomizingVersionsRequiresTheirBaseFields() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try ProfileStore(directory: directory)
            let draft = try store.makeDraft()
            #expect(throws: (any Error).self) { try store.randomize(draft, fields: [.platformVersion]) }
            #expect(throws: (any Error).self) { try store.randomize(draft, fields: [.brandVersion]) }
            let changed = try store.randomize(draft, fields: [.platform, .platformVersion, .brand, .brandVersion])
            #expect(changed.fingerprint.platform != nil)
            #expect(!changed.fingerprint.platformVersion.isEmpty)
            #expect(changed.fingerprint.brand != nil)
            #expect(!changed.fingerprint.brandVersion.isEmpty)
            #expect(changed.fingerprint.seed == draft.fingerprint.seed)
            #expect(throws: Never.self) { try changed.validated() }
        }
    }
}
