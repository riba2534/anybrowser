import AnyBrowserCore
import Foundation
import Testing

struct IdentitySamplerTests {
    private static let engine = "148.0.7778.215"

    @Test("Default samples are complete, coherent macOS identities")
    func defaultSamples() {
        let fonts: Set<FontProfile> = [.macos26, .macos15]
        for _ in 0..<200 {
            let fingerprint = IdentitySampler.sample(seed: Int.random(in: 1...Int(Int32.max)))
            #expect(fingerprint.platform == .macOS)
            #expect(["26.2.0", "15.7.1"].contains(fingerprint.platformVersion))
            #expect(fingerprint.brand == .chrome)
            #expect(fingerprint.cpuCount != nil)
            // The bundled engine ignores its screen switches, so generated Profiles do not claim one.
            #expect(fingerprint.screenWidth == nil)
            #expect(fingerprint.colorDepth == nil)
            #expect(fingerprint.deviceScaleFactor == nil)
            #expect(fingerprint.deviceMemory == nil)
            #expect(fingerprint.languages?.first == fingerprint.language)
            #expect(fingerprint.languages?.isEmpty == false)
            #expect(TimeZone.knownTimeZoneIdentifiers.contains(fingerprint.timeZone))
            #expect(fingerprint.touch == false)
            #expect(fonts.contains(fingerprint.fontProfile ?? .windows11))
            #expect(fingerprint.adjustments.contains(.canvas))
            #expect(fingerprint.adjustments.contains(.gpu))
            #expect(fingerprint.adjustments.contains(.audio))
            #expect(throws: Never.self) {
                try BrowserProfile(name: "Sampled", port: 9301, fingerprint: fingerprint).validated()
            }
            let issues = BrowserProfile(name: "Sampled", port: 9301, fingerprint: fingerprint)
                .consistencyIssues(engineVersion: Self.engine, exit: nil)
            #expect(issues.isEmpty)
        }
    }

    @Test("An explicit Windows preset gets a Windows bundle")
    func windowsPreset() throws {
        let preset = try #require(IdentityPreset.all.first { $0.id == "win11-chrome" })
        for _ in 0..<50 {
            let fingerprint = IdentitySampler.sample(seed: Int.random(in: 1...Int(Int32.max)), preset: preset)
            #expect(fingerprint.platform == .windows)
            #expect(fingerprint.platformVersion == "19.0.0")
            #expect(fingerprint.screenWidth == nil)
            #expect(fingerprint.fontProfile == .windows11)
            #expect(fingerprint.languages?.first == fingerprint.language)
            #expect(throws: Never.self) {
                try BrowserProfile(name: "Sampled", port: 9301, fingerprint: fingerprint).validated()
            }
            let ids = BrowserProfile(name: "Sampled", port: 9301, fingerprint: fingerprint)
                .consistencyIssues(engineVersion: Self.engine, exit: nil).map(\.id)
            #expect(ids.contains("font-spoof-missing"))
        }
    }

    @Test("Regenerating a Windows Profile keeps it on Windows")
    func regenerateKeepsPlatform() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try ProfileStore(directory: directory)
            var profile = try store.makeDraft()
            profile.fingerprint.platform = .windows
            profile.fingerprint.platformVersion = "19.0.0"
            profile.fingerprint.adaptToPlatform()
            try store.save(profile)

            let regenerated = try store.regenerateIdentity(profile)
            #expect(regenerated.fingerprint.platform == .windows)
            #expect([FontProfile.windows11, .windows10].contains(regenerated.fingerprint.fontProfile))
            #expect(regenerated.fingerprint.screenWidth == nil)
            #expect(regenerated.fingerprint.seed != profile.fingerprint.seed)
        }
    }

    @Test("A proxy exit supplies language and time zone")
    func proxyLocale() throws {
        let exit = ProxyExit(ip: "203.0.113.7", countryCode: "US", city: "Los Angeles",
                             timeZone: "America/Los_Angeles", languages: ["en-US"])
        let hint = try #require(IdentitySampler.LocaleHint(exit: exit))
        #expect(hint.language == "en-US")
        #expect(hint.timeZone == "America/Los_Angeles")
        #expect(hint.languages.first == "en-US")

        let fingerprint = IdentitySampler.sample(seed: 123, constraints: .init(locale: hint))
        #expect(fingerprint.language == "en-US")
        #expect(fingerprint.timeZone == "America/Los_Angeles")
        #expect(fingerprint.languages == hint.languages)
    }

    @Test("Batch profiles share the proxy locale but keep separate seeds")
    func batchLocale() throws {
        let hint = try #require(IdentitySampler.LocaleHint(language: "ja-JP", timeZone: "Asia/Tokyo"))
        let batch = try ProfileLibrary.batch(
            .init(count: 3, prefix: "P", preset: nil, proxy: "", locale: hint),
            existingNames: [], takenPorts: [], takenSeeds: [])
        #expect(Set(batch.map(\.fingerprint.seed)).count == 3)
        #expect(batch.allSatisfy {
            $0.fingerprint.language == "ja-JP" && $0.fingerprint.timeZone == "Asia/Tokyo"
        })
    }

    @Test("Legacy fingerprint JSON without the bundle fields still decodes")
    func legacyDecoding() throws {
        let encoded = try JSONEncoder().encode(FingerprintSettings(seed: 42))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["languages", "screenWidth", "screenHeight", "availWidth", "availHeight",
                    "colorDepth", "deviceScaleFactor", "deviceMemory", "touch", "fontProfile"] {
            object.removeValue(forKey: key)
        }
        let legacy = try JSONDecoder().decode(FingerprintSettings.self,
                                              from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.seed == 42)
        #expect(legacy.languages == nil)
        #expect(legacy.screenWidth == nil)
        #expect(legacy.fontProfile == nil)
        #expect(legacy.touch == nil)
    }
}
