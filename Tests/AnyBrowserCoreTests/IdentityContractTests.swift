@testable import AnyBrowserCore
import Foundation
import Testing

/// The device identity a Profile presents to Stripe, the cookie posture it launches with and the
/// places the id is planted, plus the font policy that follows the platform.
@Suite("Identity contract", .serialized)
@MainActor
struct IdentityContractTests {
    private static let macPreset = IdentityPreset.all.first { $0.id == "macos26-chrome" }!

    // MARK: DeviceIdentity

    @Test("A minted id is a lowercase UUIDv4")
    func mintShape() {
        let identity = DeviceIdentity.mint()
        #expect(identity.count == 36)
        #expect(identity == identity.lowercased())
        #expect(DeviceIdentity.isValid(identity))
        let characters = Array(identity)
        #expect(characters[8] == "-" && characters[13] == "-" && characters[18] == "-" && characters[23] == "-")
        #expect(characters[14] == "4")
        #expect("89ab".contains(characters[19]))
        let isASCII = identity.unicodeScalars.allSatisfy(\.isASCII)
        #expect(isASCII)
    }

    @Test("A thousand minted ids are all different")
    func mintIsUnique() {
        let identities = Set((0..<1000).map { _ in DeviceIdentity.mint() })
        #expect(identities.count == 1000)
    }

    @Test("The derived fallback is stable for the same seed and platform and moves with either")
    func derivedFollowsSeedAndPlatform() {
        let first = DeviceIdentity.derived(seed: 4242, platform: .macOS)
        #expect(first == DeviceIdentity.derived(seed: 4242, platform: .macOS))
        #expect(DeviceIdentity.isValid(first))
        #expect(first != DeviceIdentity.derived(seed: 4243, platform: .macOS))
        #expect(first != DeviceIdentity.derived(seed: 4242, platform: .windows))
        #expect(first != DeviceIdentity.derived(seed: 4242, platform: nil))
        #expect(DeviceIdentity.derived(seed: 4242, platform: nil)
            != DeviceIdentity.derived(seed: 4242, platform: .linux))
    }

    @Test("The effective id is the Profile's own, or the fallback while it has none")
    func effectivePrefersTheOwnId() {
        var fingerprint = FingerprintSettings(seed: 4242)
        fingerprint.platform = .macOS
        var profile = BrowserProfile(name: "Identity", port: 9311, fingerprint: fingerprint)
        #expect(DeviceIdentity.effective(profile) == DeviceIdentity.derived(seed: 4242, platform: .macOS))

        let own = DeviceIdentity.mint()
        profile.deviceIdentity = own
        #expect(DeviceIdentity.effective(profile) == own)
        #expect(DeviceIdentity.effective(profile) != DeviceIdentity.derived(seed: 4242, platform: .macOS))
    }

    @Test("isValid takes a UUIDv4 with or without its checksum and refuses other shapes")
    func isValidShapes() {
        let identity = DeviceIdentity.mint()
        #expect(DeviceIdentity.isValid(identity))
        #expect(DeviceIdentity.isValid(identity + "abcdef"))
        #expect(!DeviceIdentity.isValid(identity.uppercased()))
        // UUIDv1 and a v4 with a non-RFC variant nibble.
        #expect(!DeviceIdentity.isValid("0f8b3c2a-4d5e-1f60-8a1b-2c3d4e5f6071"))
        #expect(!DeviceIdentity.isValid("0f8b3c2a-4d5e-4f60-ca1b-2c3d4e5f6071"))
        #expect(!DeviceIdentity.isValid(String(repeating: "a", count: 42)))
        #expect(!DeviceIdentity.isValid(identity + "zzzzzz"))
        #expect(!DeviceIdentity.isValid(""))
        #expect(!DeviceIdentity.isValid(" " + identity + " "))
    }

    // MARK: Profile encoding

    @Test("A Profile with a device id survives encoding and decoding")
    func profileRoundTrip() throws {
        let identity = DeviceIdentity.mint()
        let profile = BrowserProfile(name: "Identity", port: 9312, fingerprint: FingerprintSettings(seed: 4242),
                                     deviceIdentity: identity)
        let decoded = try JSONDecoder().decode(BrowserProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        #expect(decoded.deviceIdentity == identity)
    }

    @Test("A row written before the field existed decodes without one")
    func legacyRowHasNoIdentity() throws {
        let profile = BrowserProfile(name: "Old", port: 9313, fingerprint: FingerprintSettings(seed: 4242))
        let encoded = try JSONEncoder().encode(profile)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "deviceIdentity")
        let decoded = try JSONDecoder().decode(BrowserProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.deviceIdentity == nil)
    }

    @Test("Validation refuses an identity that is not a lowercase UUIDv4")
    func validationRefusesInvalidIdentity() throws {
        let profile = BrowserProfile(name: "Identity", port: 9314, fingerprint: FingerprintSettings(seed: 4242),
                                     deviceIdentity: DeviceIdentity.mint().uppercased())
        #expect(throws: ProfileError.self) { try profile.validated() }
        var fixed = profile
        fixed.deviceIdentity = DeviceIdentity.mint()
        #expect(throws: Never.self) { try fixed.validated() }

        for value in ["abc", String(repeating: "a", count: 42), DeviceIdentity.mint() + "zzzzzz"] {
            var broken = fixed
            broken.deviceIdentity = value
            #expect(throws: ProfileError.self, "\(value)") { try broken.validated() }
        }
    }

    @Test("A new draft already carries a valid device id")
    func draftHasIdentity() throws {
        let directory = try scratchDirectory("identity-draft")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let draft = try store.makeDraft()
        let identity = try #require(draft.deviceIdentity)
        #expect(DeviceIdentity.isValid(identity))
        #expect(throws: Never.self) { try draft.validated() }
    }

    // MARK: Regenerating

    @Test("Regenerating an identity changes the seed and the device id")
    func regenerateMovesBoth() throws {
        let directory = try scratchDirectory("identity-regenerate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let profile = try store.makeDraft()
        try store.save(profile)
        let oldIdentity = try #require(profile.deviceIdentity)

        let regenerated = try store.regenerateIdentity(profile)
        #expect(regenerated.id == profile.id)
        #expect(regenerated.fingerprint.seed != profile.fingerprint.seed)
        let newIdentity = try #require(regenerated.deviceIdentity)
        #expect(newIdentity != oldIdentity)
        #expect(DeviceIdentity.isValid(newIdentity))
        // The old value no longer points at the new device.
        #expect(DeviceIdentity.effective(regenerated) != oldIdentity)
    }

    // MARK: Automation API

    @Test("A PATCH that changes the seed clears the device id; an unchanged seed keeps it")
    func automationSeedChangeClearsIdentity() async throws {
        let backend = try FakeBackend()
        let profile = try backend.add("Identity", port: 9315) { $0.deviceIdentity = DeviceIdentity.mint() }
        let identity = try #require(profile.deviceIdentity)
        try await serveAutomation(backend) { port in
            let unchanged = await automationRequest(port, "PATCH", "/api/v1/profiles/\(profile.id)",
                                                    json: ["fingerprint": ["seed": profile.fingerprint.seed]])
            #expect(unchanged.status == 200)
            #expect((unchanged.json?["config"] as? [String: Any])?["deviceIdentity"] as? String == identity)

            let changed = await automationRequest(port, "PATCH", "/api/v1/profiles/\(profile.id)",
                                                  json: ["fingerprint": ["seed": 9402]])
            #expect(changed.status == 200)
            #expect((changed.json?["config"] as? [String: Any])?["deviceIdentity"] == nil)
            let saved = try #require(backend.store.profiles.first { $0.id == profile.id })
            #expect(saved.deviceIdentity == nil)
            #expect(saved.fingerprint.seed == 9402)
        }
    }

    // MARK: StripeIdentitySeeder

    @Test("Start hosts are lowercased, deduplicated, HTTP(S) only and capped at 20")
    func seederHosts() {
        #expect(StripeIdentitySeeder.hosts(from: [
            " https://Trim.Example/start ",
            "https://trim.example/other",
            "HTTPS://TRIM.EXAMPLE/",
            "http://plain.example/",
            "ftp://files.example/",
            "example.com/no-scheme",
            "http://127.0.0.1:8080/",
            "",
        ]) == ["trim.example", "plain.example", "127.0.0.1"])

        let many = (0..<25).map { "https://h\($0).example/" }
        let capped = StripeIdentitySeeder.hosts(from: many)
        #expect(capped.count == StripeIdentitySeeder.maximumHosts)
        #expect(capped == (0..<20).map { "h\($0).example" })
    }

    @Test("Only a bare UUIDv4, with or without the checksum, is acceptable as it stands")
    func seederAcceptable() {
        let identity = DeviceIdentity.mint()
        #expect(StripeIdentitySeeder.acceptable(identity))
        #expect(!StripeIdentitySeeder.acceptable(nil))
        #expect(StripeIdentitySeeder.acceptable(identity + "abcdef"))
        #expect(!StripeIdentitySeeder.acceptable(String(repeating: "a", count: 42)))
        #expect(!StripeIdentitySeeder.acceptable(identity.uppercased()))
        #expect(!StripeIdentitySeeder.acceptable("0f8b3c2a-4d5e-1f60-8a1b-2c3d4e5f6071"))
        #expect(!StripeIdentitySeeder.acceptable(identity + "zzzzzz"))
    }

    @Test("Seeding writes the effective id and a session id, dots domain hosts and leaves IPs bare")
    func seederCookies() async throws {
        let server = try await FakeDevTools.start { method, _ in
            method == "Storage.getCookies" ? .result(["cookies": []]) : .result([:])
        }
        defer { server.stop() }
        let client = try DevToolsClient(endpoint: server.endpoint)
        defer { client.close() }

        let identity = DeviceIdentity.mint()
        let profile = BrowserProfile(name: "Seed", port: 9316, fingerprint: FingerprintSettings(seed: 4242),
                                     deviceIdentity: identity)
        let warnings = await StripeIdentitySeeder.seed(
            profile, startURLs: ["https://shop.example/", "http://127.0.0.1:8787/"], client: client)
        #expect(!warnings.isEmpty)

        let setCalls = server.methods.filter { $0 == "Storage.setCookies" }
        #expect(setCalls.count == 1)
        let index = try #require(server.methods.firstIndex(of: "Storage.setCookies"))
        let parameters = try #require(server.commands[index]["cookies"] as? [[String: Any]])
        let planted = parameters.compactMap { cookie -> (name: String, value: String, domain: String)? in
            guard let name = cookie["name"] as? String, let value = cookie["value"] as? String,
                  let domain = cookie["domain"] as? String else { return nil }
            return (name, value, domain)
        }
        #expect(Set(planted.map(\.name)) == ["__stripe_mid", "__stripe_sid"])
        let mids = planted.filter { $0.name == "__stripe_mid" }
        let sids = planted.filter { $0.name == "__stripe_sid" }
        let midsCarryTheId = mids.allSatisfy { $0.value == identity }
        let sidsDiffer = sids.allSatisfy { $0.value != identity }
        #expect(midsCarryTheId)
        #expect(sidsDiffer)
        // A domain host takes the leading dot; a bare IP must not.
        #expect(Set(planted.map(\.domain)) == [".shop.example", "127.0.0.1"])
        #expect(mids.count == 2)
        #expect(sids.count == 2)
        // One mid plus a distinct sid per host.
        #expect(Set(planted.map(\.value)).count == 3)
    }

    @Test("Seeding keeps an acceptable existing pair")
    func seederKeepsExistingCookies() async throws {
        let existingMid = DeviceIdentity.mint() + "abcdef"
        let existingSid = DeviceIdentity.mint()
        let server = try await FakeDevTools.start { method, _ in
            guard method == "Storage.getCookies" else { return .result([:]) }
            return .result(["cookies": [
                ["name": "__stripe_mid", "value": existingMid, "domain": ".shop.example"],
                ["name": "__stripe_sid", "value": existingSid, "domain": ".shop.example"],
            ]])
        }
        defer { server.stop() }
        let client = try DevToolsClient(endpoint: server.endpoint)
        defer { client.close() }

        let profile = BrowserProfile(name: "Seed", port: 9317, fingerprint: FingerprintSettings(seed: 4242))
        _ = await StripeIdentitySeeder.seed(profile, startURLs: ["https://shop.example/"], client: client)
        #expect(!server.methods.contains("Storage.setCookies"))
    }

    // MARK: ThirdPartyCookiePosture

    @Test("An empty directory gets the profile-level cookie posture")
    func postureFromScratch() throws {
        let directory = try scratchDirectory("posture-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        try ThirdPartyCookiePosture.apply(in: directory)
        let data = try Data(contentsOf: directory.appendingPathComponent("Default/Preferences"))
        #expect(String(decoding: data, as: UTF8.self) == #"{"profile":{"cookie_controls_mode":0}}"#)
    }

    @Test("Other preference keys survive and the posture is written over an old value")
    func postureKeepsOtherKeys() throws {
        let directory = try scratchDirectory("posture-existing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultDirectory = directory.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        let url = defaultDirectory.appendingPathComponent("Preferences")
        try Data(#"{"profile":{"password_manager_enabled":true,"cookie_controls_mode":1},"other":{"x":1}}"#.utf8)
            .write(to: url)

        try ThirdPartyCookiePosture.apply(in: directory)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((root["profile"] as? [String: Any])?["cookie_controls_mode"] as? Int == 0)
        #expect((root["profile"] as? [String: Any])?["password_manager_enabled"] as? Bool == true)
        #expect((root["other"] as? [String: Any])?["x"] as? Int == 1)
    }

    @Test("Applying the posture again leaves the file as it is")
    func postureIsIdempotent() throws {
        let directory = try scratchDirectory("posture-idempotent")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultDirectory = directory.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        let url = defaultDirectory.appendingPathComponent("Preferences")
        try Data(#"{"profile":{"password_manager_enabled":true}}"#.utf8).write(to: url)

        try ThirdPartyCookiePosture.apply(in: directory)
        let first = try Data(contentsOf: url)
        try ThirdPartyCookiePosture.apply(in: directory)
        let second = try Data(contentsOf: url)
        #expect(second == first)
        let root = try #require(try JSONSerialization.jsonObject(with: first) as? [String: Any])
        #expect((root["profile"] as? [String: Any])?["password_manager_enabled"] as? Bool == true)
    }

    @Test("A Preferences file that is not a JSON object is reported, not overwritten")
    func postureRefusesGarbage() throws {
        let directory = try scratchDirectory("posture-garbage")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultDirectory = directory.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        let url = defaultDirectory.appendingPathComponent("Preferences")
        let garbage = Data("[1, 2]".utf8)
        try garbage.write(to: url)
        #expect(throws: ProfileError.self) { try ThirdPartyCookiePosture.apply(in: directory) }
        #expect(try Data(contentsOf: url) == garbage)
    }

    // MARK: Fonts follow the platform

    @Test("A sampled identity always carries the font switch")
    func samplesKeepFonts() {
        for preset in IdentityPreset.all {
            for seed in [4242, 87] {
                let fingerprint = IdentitySampler.sample(seed: seed, constraints: .init(preset: preset))
                #expect(fingerprint.adjustments.contains(.font), "\(preset.id)")
                #expect(fingerprint.fontProfile != nil, "\(preset.id)")
            }
        }
    }

    @Test("Without a platform nothing applies the font table, and adapting drops both")
    func adaptingDropsFontsWithoutPlatform() {
        var fingerprint = IdentitySampler.sample(seed: 4242, constraints: .init(preset: Self.macPreset))
        #expect(fingerprint.adjustments.contains(.font))
        #expect(fingerprint.fontProfile != nil)

        fingerprint.platform = nil
        fingerprint.adaptToPlatform()
        #expect(!fingerprint.adjustments.contains(.font))
        #expect(fingerprint.fontProfile == nil)
        #expect(throws: Never.self) {
            try BrowserProfile(name: "Host", port: 9318, fingerprint: fingerprint).validated()
        }
    }

    // MARK: Consistency hints

    private func issueIDs(_ fingerprint: FingerprintSettings) -> [String] {
        BrowserProfile(name: "Check", port: 9319, fingerprint: fingerprint)
            .consistencyIssues(engineVersion: BundledVersions.engine, exit: nil).map(\.id)
    }

    @Test("A font table without the font switch is flagged, and the switch clears it")
    func fontHint() {
        var fingerprint = IdentitySampler.sample(seed: 4242, constraints: .init(preset: Self.macPreset))
        fingerprint.adjustments.remove(.font)
        #expect(issueIDs(fingerprint).contains("font-spoof-disabled"))
        fingerprint.adjustments.insert(.font)
        #expect(!issueIDs(fingerprint).contains("font-spoof-disabled"))
    }

    @Test("A platform with no screen is flagged as sharing the host display, and a screen clears it")
    func screenHint() {
        var fingerprint = FingerprintSettings(seed: 4242)
        fingerprint.platform = .macOS
        fingerprint.platformVersion = "26.2.0"
        fingerprint.fontProfile = .macos26
        fingerprint.adjustments.insert(.font)
        #expect(issueIDs(fingerprint).contains("screen-host-shared"))

        fingerprint.screenWidth = 1512
        fingerprint.screenHeight = 982
        fingerprint.availWidth = 1512
        fingerprint.availHeight = 945
        #expect(!issueIDs(fingerprint).contains("screen-host-shared"))

        fingerprint.platform = nil
        fingerprint.fontProfile = nil
        #expect(!issueIDs(fingerprint).contains("screen-host-shared"))
    }

    @Test("A normal sampled identity is not font-flagged and is screen-flagged")
    func noFalsePositives() {
        let fingerprint = IdentitySampler.sample(seed: 4242, constraints: .init(preset: Self.macPreset))
        let ids = issueIDs(fingerprint)
        #expect(!ids.contains("font-spoof-disabled"))
        #expect(ids.contains("screen-host-shared"))
    }
}