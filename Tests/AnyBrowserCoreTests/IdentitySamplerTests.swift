@testable import AnyBrowserCore
import Foundation
import Testing

struct IdentitySamplerTests {
    private static let engine = BundledVersions.engine

    @Test("Default samples are complete, coherent macOS identities")
    func defaultSamples() {
        let fonts: Set<FontProfile> = [.macos26, .macos15]
        let versions = Set(IdentityPreset.all.filter { $0.platform == .macOS }.flatMap(\.platformVersions))
        var majors: Set<Substring> = []
        for _ in 0..<300 {
            // Callers always draw seeds with newSeed, which skips impossible macOS machines.
            let seed = FingerprintSettings.newSeed(excluding: [])
            let fingerprint = IdentitySampler.sample(seed: seed)
            #expect(fingerprint.platform == .macOS)
            #expect(versions.contains(fingerprint.platformVersion))
            majors.insert(fingerprint.platformVersion.prefix(2))
            #expect(fingerprint.brand == .chrome)
            // The engine picks a released Chrome build by seed.
            #expect(fingerprint.brandVersion.isEmpty)
            #expect(fingerprint.cpuCount != nil)
            #expect(EngineHardwareTable.bundled.exists(platform: .macOS, seed: seed, cpuCount: fingerprint.cpuCount))
            // The identity guard applies the screen in the page; a generated Profile always has one.
            let screenWidth = try? #require(fingerprint.screenWidth)
            let screenHeight = try? #require(fingerprint.screenHeight)
            #expect((fingerprint.availWidth ?? .max) <= (screenWidth ?? 0))
            #expect((fingerprint.availHeight ?? .max) <= (screenHeight ?? 0))
            #expect([24, 30].contains(fingerprint.colorDepth ?? 0))
            #expect(fingerprint.deviceScaleFactor == 2)
            #expect(fingerprint.deviceMemory == EngineHardwareTable.bundled.deviceMemory(seed: seed))
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
            #expect(issues.isEmpty, "\(issues)")
        }
        #expect(majors == ["15", "26", "27"])
    }

    @Test("An explicit Windows preset gets a Windows bundle and its engine limits")
    func windowsPreset() throws {
        let preset = try #require(IdentityPreset.all.first { $0.id == "win11-chrome" })
        #expect(preset.isExperimental)
        for _ in 0..<50 {
            let seed = FingerprintSettings.newSeed(excluding: [])
            let fingerprint = IdentitySampler.sample(seed: seed, preset: preset)
            #expect(fingerprint.platform == .windows)
            #expect(fingerprint.platformVersion == "19.0.0")
            #expect(fingerprint.brandVersion.isEmpty)
            #expect(EngineHardwareTable.bundled.gpu(for: .windows, seed: seed)?.cpuCounts.contains(fingerprint.cpuCount ?? 0) == true)
            #expect(fingerprint.screenWidth != nil)
            #expect(fingerprint.colorDepth == 24)
            #expect([1.0, 1.25, 1.5].contains(fingerprint.deviceScaleFactor ?? 0))
            #expect(fingerprint.fontProfile == .windows11)
            #expect(fingerprint.languages?.first == fingerprint.language)
            #expect(throws: Never.self) {
                try BrowserProfile(name: "Sampled", port: 9301, fingerprint: fingerprint).validated()
            }
            let ids = BrowserProfile(name: "Sampled", port: 9301, fingerprint: fingerprint)
                .consistencyIssues(engineVersion: Self.engine, exit: nil).map(\.id)
            #expect(Set(ids) == ["font-spoof-missing", "webgpu-host-gpu", "voices-host-os"])
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
            #expect(regenerated.fingerprint.screenWidth != nil)
            #expect(regenerated.fingerprint.seed != profile.fingerprint.seed)
            #expect(regenerated.deviceIdentity != profile.deviceIdentity)
        }
    }

    @Test("A proxy exit supplies language and time zone")
    func proxyLocale() throws {
        let exit = ProxyExit(ip: "203.0.113.7", countryCode: "US", city: "Los Angeles",
                             timeZone: "America/Los_Angeles", languages: ["en-US"])
        let hint = try #require(IdentitySampler.LocaleHint(exit: exit))
        #expect(hint.language == "en-US")
        #expect(hint.timeZone == "America/Los_Angeles")
        #expect(hint.languages == ["en-US", "en"])

        let fingerprint = IdentitySampler.sample(seed: 123, constraints: .init(locale: hint))
        #expect(fingerprint.language == "en-US")
        #expect(fingerprint.timeZone == "America/Los_Angeles")
        #expect(fingerprint.languages == hint.languages)
    }

    @Test("Exit languages keep only the first tag, completed with its base language")
    func exitLanguagesAreTrimmed() throws {
        // ipapi.co lists every language of the country.
        let ipapi = ProxyExit(ip: "203.0.113.8", countryCode: "US", timeZone: "America/New_York",
                              languages: ["en-US", "es-US", "haw", "fr"])
        #expect(try #require(IdentitySampler.LocaleHint(exit: ipapi)).languages == ["en-US", "en"])
        // ipinfo.io has no languages; the country fallback lists two regional tags.
        let swiss = ProxyExit(ip: "203.0.113.9", countryCode: "CH", timeZone: "Europe/Zurich")
        let hint = try #require(IdentitySampler.LocaleHint(exit: swiss))
        #expect(hint.language == "de-CH")
        #expect(hint.languages == ["de-CH", "de"])
        #expect(IdentitySampler.LocaleHint(exit: ProxyExit(ip: "203.0.113.10", timeZone: "UTC")) == nil)
    }

    @Test("macOS language tags are written the way Chrome writes them")
    func appleLanguageTags() throws {
        let cases = [
            "zh-Hans-CN": "zh-CN", "zh-Hant-TW": "zh-TW", "zh-Hant-HK": "zh-HK", "zh-Hans": "zh-CN",
            "zh-Hant": "zh-TW", "en_US": "en-US", "EN-gb": "en-GB", "sr-Latn-RS": "sr-RS", "de": "de",
            "es-419": "es-419", " ja-JP ": "ja-JP",
        ]
        for (apple, chrome) in cases {
            #expect(IdentitySampler.chromeLanguageTag(apple) == chrome, "\(apple)")
        }
        let hint = try #require(IdentitySampler.LocaleHint(language: "zh-Hans-CN", timeZone: "Asia/Shanghai",
                                                            languages: ["zh-Hans-CN", "en-US"]))
        #expect(hint.language == "zh-CN")
        #expect(hint.languages == ["zh-CN", "en-US"])
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
