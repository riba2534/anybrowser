import AnyBrowserCore
import Foundation
import XCTest

final class ProfileTests: XCTestCase {
    func testUniquePortsAndSeedsSurviveReopeningStore() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }

            let store = try ProfileStore(directory: directory)
            let first = try store.makeDraft()
            XCTAssertEqual(first.port, 9222)
            try store.save(first)

            var second = try store.makeDraft()
            XCTAssertEqual(second.port, 9223)
            XCTAssertNotEqual(first.fingerprint.seed, second.fingerprint.seed)
            second.port = first.port
            XCTAssertThrowsError(try store.save(second))
            second.port = 9223
            second.fingerprint.seed = first.fingerprint.seed
            XCTAssertThrowsError(try store.save(second))

            second = try store.randomize(second, fields: [.seed, .language, .timeZone])
            try store.save(second)
            let reopened = try ProfileStore(directory: directory)
            XCTAssertEqual(reopened.profiles, [first, second])
            XCTAssertNotEqual(first.fingerprint.seed, second.fingerprint.seed)
            XCTAssertEqual(second.port, 9223)
            XCTAssertEqual(second.fingerprint.platform, nil)

            let dataDirectory = directory.appendingPathComponent(first.id.uuidString)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: false)
            try reopened.remove(first.id)
            XCTAssertEqual(try ProfileStore(directory: directory).profiles, [second])
            XCTAssertTrue(FileManager.default.fileExists(atPath: dataDirectory.path))
        }
    }

    func testTypedSettingsCompileIntoSeparateArguments() throws {
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
        XCTAssertTrue(arguments.contains("--user-data-dir=/tmp/AnyBrowser Testing/Profile Space"))
        XCTAssertTrue(arguments.contains("--remote-debugging-port=9235"))
        XCTAssertTrue(arguments.contains("--proxy-server=http://127.0.0.1:7890"))
        XCTAssertTrue(arguments.contains("--fingerprint=87"))
        XCTAssertTrue(arguments.contains("--fingerprint-platform=macos"))
        XCTAssertTrue(arguments.contains("--fingerprint-platform-version=26.2.0"))
        XCTAssertTrue(arguments.contains("--fingerprint-brand=Edge"))
        XCTAssertTrue(arguments.contains("--fingerprint-brand-version=148.0.3967.54"))
        XCTAssertTrue(arguments.contains("--fingerprint-hardware-concurrency=12"))
        XCTAssertTrue(arguments.contains("--accept-lang=zh-CN,zh"))
        XCTAssertTrue(arguments.contains("--timezone=Asia/Shanghai"))
        XCTAssertTrue(arguments.contains("--disable-spoofing=font,audio,gpu"))
    }

    func testProxyAddressesAndLegacyProfiles() throws {
        let home = URL(fileURLWithPath: "/tmp/AnyBrowser Profile")
        var profile = BrowserProfile(name: "Proxy", port: 9222, fingerprint: FingerprintSettings(seed: 1))
        let encoded = try JSONEncoder().encode(profile)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "proxy")
        let decoded = try JSONDecoder().decode(BrowserProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded, profile)

        profile.proxy = " SOCKS5://[::1]:7891/ "
        XCTAssertTrue(try profile.validated().launchArguments(userDataDirectory: home)
            .contains("--proxy-server=socks5://[::1]:7891"))
        profile.proxy = "https://proxy.example:443"
        XCTAssertTrue(try profile.validated().launchArguments(userDataDirectory: home)
            .contains("--proxy-server=https://proxy.example:443"))

        profile.proxy = ""
        let reopened = try JSONDecoder().decode(BrowserProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(reopened.proxy, "")
        XCTAssertFalse(reopened.launchArguments(userDataDirectory: home).contains { $0.hasPrefix("--proxy-server=") })

        for address in ["localhost", "localhost:0", "localhost:65536", "http://proxy:80/path",
                        "http://name:secret@localhost:7890", "localhost:7890 --other-flag",
                        "http://proxy:80;direct://", "http://[not-an-ip]:7890", "http://-proxy:443"] {
            profile.proxy = address
            XCTAssertThrowsError(try profile.validated(), address)
        }
    }

    func testInvalidConfigurationCannotBeSaved() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try ProfileStore(directory: directory)
            var draft = try store.makeDraft()
            draft.fingerprint.language = "en-US --remote-debugging-port=9444"
            XCTAssertThrowsError(try store.save(draft))
            draft.fingerprint.language = "en-US"
            draft.fingerprint.platformVersion = "26.1"
            XCTAssertThrowsError(try store.save(draft))
            draft.fingerprint.platform = .macOS
            draft.port = 65536
            XCTAssertThrowsError(try store.save(draft))
            XCTAssertTrue(store.profiles.isEmpty)
        }
    }

    func testRandomizingVersionsRequiresTheirBaseFields() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try ProfileStore(directory: directory)
            let draft = try store.makeDraft()
            XCTAssertThrowsError(try store.randomize(draft, fields: [.platformVersion]))
            XCTAssertThrowsError(try store.randomize(draft, fields: [.brandVersion]))
            let changed = try store.randomize(draft, fields: [.platform, .platformVersion, .brand, .brandVersion])
            XCTAssertNotNil(changed.fingerprint.platform)
            XCTAssertFalse(changed.fingerprint.platformVersion.isEmpty)
            XCTAssertNotNil(changed.fingerprint.brand)
            XCTAssertFalse(changed.fingerprint.brandVersion.isEmpty)
            XCTAssertEqual(changed.fingerprint.seed, draft.fingerprint.seed)
            XCTAssertNoThrow(try changed.validated())
        }
    }
}
