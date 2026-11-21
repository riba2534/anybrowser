@testable import AnyBrowserCore
import Foundation
import Testing

struct ProfileModelTests {
    @Test("Profiles saved before groups, identities and launch options still decode")
    func legacyProfilesDecode() throws {
        let legacy = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","port":9222,"fingerprint":{"seed":7,"platformVersion":"","brandVersion":"","language":"","timeZone":"","adjustments":["canvas"]}}"#
        let profile = try JSONDecoder().decode(BrowserProfile.self, from: Data(legacy.utf8))
        #expect(profile.group.isEmpty && profile.notes.isEmpty)
        #expect(profile.passkeyBox == nil)
        #expect(profile.launch == LaunchOptions())
        #expect(profile.proxy == BrowserProfile.defaultProxy)
    }

    @Test("New Profile fields survive a round trip")
    func newFieldsRoundTrip() throws {
        var profile = BrowserProfile(name: "New", port: 9300, fingerprint: FingerprintSettings(seed: 9))
        profile.group = "Shop"
        profile.notes = "notes"
        profile.passkeyBox = PasskeyBoxAccount(serverURL: "https://pk.example.com", username: "a", password: "b")
        profile.launch = LaunchOptions(startURLs: ["https://example.com/"], window: WindowLayout(width: 1280, height: 800),
                                       extensionDirectories: ["/tmp/Ext"])
        let decoded = try JSONDecoder().decode(BrowserProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
    }

    @Test("Extension directories load in order: Passkey Box, then the Profile's own")
    func extensionOrder() throws {
        var profile = BrowserProfile(name: "Ext", port: 9301, fingerprint: FingerprintSettings(seed: 3))
        profile.launch.extensionDirectories = ["/Users/me/Ext"]
        let storage = URL(fileURLWithPath: "/tmp/anybrowser-storage", isDirectory: true)
        let paths = ProfileExtensions.paths(for: profile, in: storage)
        #expect(paths.map(\.path) == [
            "/tmp/anybrowser-storage/Extensions/\(profile.id.uuidString.lowercased())/PasskeyBox",
            "/Users/me/Ext",
        ])
        let arguments = profile.launchArguments(userDataDirectory: storage, extensions: paths)
        #expect(arguments.filter { $0.hasPrefix("--load-extension=") } == ["--load-extension=\(paths.map(\.path).joined(separator: ","))"])
    }

    @Test("Group and notes are trimmed and bounded")
    func organizationValidation() throws {
        var profile = BrowserProfile(name: "Org", port: 9302, fingerprint: FingerprintSettings(seed: 4))
        profile.group = "  Shop  "
        #expect(try profile.validated().group == "Shop")
        profile.group = String(repeating: "g", count: 41)
        #expect(throws: ProfileError.self) { try profile.validated() }
        profile.group = ""
        profile.notes = String(repeating: "n", count: 2001)
        #expect(throws: ProfileError.self) { try profile.validated() }

        // Combining marks stack on one character: the scalar bound stops a huge value hiding in it.
        profile.notes = ""
        profile.name = "a" + String(repeating: "\u{0301}", count: 100_000)
        #expect(profile.name.count == 1)
        #expect(throws: ProfileError.self) { try profile.validated() }
        profile.name = "Org"
        profile.group = "g" + String(repeating: "\u{0301}", count: 1_000)
        #expect(throws: ProfileError.self) { try profile.validated() }

        // Existing names full of emoji sequences stay valid: 80 keycaps of 3 scalars each.
        profile.group = ""
        profile.name = String(repeating: "1\u{FE0F}\u{20E3}", count: 80)
        #expect(profile.name.unicodeScalars.count == 240)
        #expect(profile.name.count == 80)
        #expect(throws: Never.self) { try profile.validated() }
    }
}
