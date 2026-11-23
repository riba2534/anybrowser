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
            // The seed is the engine anchor; the sampler may move it to realise the drawn family.
            #expect(EngineHardwareTable.bundled.exists(platform: .macOS, seed: fingerprint.seed,
                                                       cpuCount: fingerprint.cpuCount))
            // The identity guard applies the screen in the page; a generated Profile always has one.
            let screenWidth = try? #require(fingerprint.screenWidth)
            let screenHeight = try? #require(fingerprint.screenHeight)
            #expect((fingerprint.availWidth ?? .max) <= (screenWidth ?? 0))
            #expect((fingerprint.availHeight ?? .max) <= (screenHeight ?? 0))
            #expect([24, 30].contains(fingerprint.colorDepth ?? 0))
            #expect(fingerprint.deviceScaleFactor == 2)
            #expect(fingerprint.deviceMemory == EngineHardwareTable.bundled.deviceMemory(seed: fingerprint.seed))
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
            #expect(EngineHardwareTable.bundled.gpu(for: .windows, seed: fingerprint.seed)?.cpuCounts.contains(fingerprint.cpuCount ?? 0) == true)
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

    // MARK: Family sampling

    private static let windowsWidths: Set<Int> = [1920, 1536, 2560, 1366]
    private static let macWidths: Set<Int> = [1512, 1728, 2560, 1440, 1920]
    private static let linuxWidths: Set<Int> = [1920, 2560, 1366]

    @Test("A thousand samples carry no blocking issue and never repeat a triple")
    func thousandSamplesAreCleanAndUnique() {
        var taken: Set<String> = []
        for index in 0..<1000 {
            let seed = FingerprintSettings.newSeed(excluding: [])
            let result = IdentitySampler.sampleResult(seed: seed, constraints: .init(excluding: taken))
            let fingerprint = result.fingerprint
            let profile = BrowserProfile(name: "S", port: 9301, fingerprint: fingerprint)
            let blocking = profile.blockingConsistencyIssues(engineVersion: Self.engine)
            #expect(blocking.isEmpty, "\(blocking) at \(index)")
            #expect(!taken.contains(fingerprint.identityTriple), "\(fingerprint.identityTriple)")
            taken.insert(fingerprint.identityTriple)
            #expect((1...IdentitySampler.maximumAttempts).contains(result.attempts))
            #expect(throws: Never.self) { try profile.validated() }
        }
        #expect(taken.count == 1000)
    }

    @Test("Randomizing screen, font, touch or memory keeps the machine family")
    func fieldRandomizationStaysInFamily() throws {
        for preset in IdentityPreset.all {
            let result = IdentitySampler.sampleResult(seed: FingerprintSettings.newSeed(excluding: []),
                                                      constraints: .init(preset: preset))
            let fingerprint = result.fingerprint
            let familyID = try #require(result.familyID)
            for field in [FingerprintField.screen, .font, .touch, .deviceMemory] {
                var value = fingerprint
                value.randomize([field], excluding: [])
                #expect(IdentitySampler.family(for: value, platform: preset.platform)?.id == familyID,
                        "\(preset.id) \(field.rawValue)")
                let widths = switch preset.platform {
                case .macOS: Self.macWidths
                case .windows: Self.windowsWidths
                case .linux: Self.linuxWidths
                }
                #expect(widths.contains(value.screenWidth ?? 0), "\(preset.id) \(field.rawValue)")
                if field == .deviceMemory {
                    // The memory moved with the seed, and the seed still belongs to the same GPU.
                    #expect(value.deviceMemory == EngineHardwareTable.bundled.deviceMemory(seed: value.seed))
                    let gpu = EngineHardwareTable.bundled.gpu(for: preset.platform, seed: value.seed)
                    #expect(gpu?.deviceMemory.contains(value.deviceMemory ?? 0) != false)
                }
                if preset.platform == .macOS {
                    #expect(value.touch == false)
                    #expect(value.deviceScaleFactor == 2)
                }
            }
        }
    }

    @Test("A rejected identity is redrawn and attempts are reported")
    func attemptsAreCounted() {
        final class Rejections: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var calls: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
            func accept(after rejections: Int) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                count += 1
                return count > rejections
            }
        }
        let rejections = Rejections()
        let result = IdentitySampler.sampleResult(
            seed: FingerprintSettings.newSeed(excluding: []),
            constraints: .init(accepting: { _ in rejections.accept(after: 3) }))
        #expect(rejections.calls >= 4 || result.usedFallback)
        #expect(result.attempts >= rejections.calls)
        #expect(result.attempts <= IdentitySampler.maximumAttempts)
        // Three identities were rejected before the accepting one. A duplicate triple spends an
        // attempt without reaching the closure, so attempts may be higher than the call count.
    }

    @Test("When every attempt fails the platform default family is used")
    func fallbackTriggers() {
        for platform in [BrowserPlatform.macOS, .windows, .linux] {
            let result = IdentitySampler.sampleResult(
                seed: FingerprintSettings.newSeed(excluding: []),
                constraints: .init(platforms: [platform], accepting: { _ in false }))
            #expect(result.usedFallback)
            #expect(result.attempts == IdentitySampler.maximumAttempts)
            #expect(result.fingerprint.platform == platform)
            let profile = BrowserProfile(name: "F", port: 9301, fingerprint: result.fingerprint)
            #expect(profile.blockingConsistencyIssues(engineVersion: Self.engine).isEmpty)
            #expect(throws: Never.self) { try profile.validated() }
        }
    }

    @Test("Constraints still narrow the platform and the preset")
    func constraintsNarrowTheDraw() {
        for _ in 0..<50 {
            let linux = IdentitySampler.sampleResult(seed: FingerprintSettings.newSeed(excluding: []),
                                                     constraints: .init(platforms: [.linux]))
            #expect(linux.fingerprint.platform == .linux)
            let win10 = IdentitySampler.sampleResult(seed: FingerprintSettings.newSeed(excluding: []),
                                                     constraints: .init(presets: ["win10-chrome"],
                                                                        platforms: [.windows]))
            #expect(win10.fingerprint.platform == .windows)
            #expect(win10.fingerprint.platformVersion == "10.0.0")
            #expect(win10.fingerprint.fontProfile == .windows10)
        }
    }

    @Test("An already used triple is not handed out again")
    func triplesAreNotRepeated() throws {
        let first = IdentitySampler.sampleResult(seed: FingerprintSettings.newSeed(excluding: []))
        let triple = first.fingerprint.identityTriple
        for _ in 0..<30 {
            let next = IdentitySampler.sampleResult(seed: FingerprintSettings.newSeed(excluding: []),
                                                    constraints: .init(excluding: [triple]))
            #expect(next.fingerprint.identityTriple != triple)
        }
    }

    @Test("Common values dominate: macOS 26, 16 GB, no touch, no 30-bit panel")
    func weightsFollowCommonness() {
        var presets: [String: Int] = [:]
        var memory32 = 0
        var depth30 = 0
        let ids = IdentityPreset.all.map(\.id)
        var platforms: [BrowserPlatform: Int] = [:]
        for _ in 0..<1500 {
            let seed = FingerprintSettings.newSeed(excluding: [])
            let result = IdentitySampler.sampleResult(seed: seed, constraints: .init(presets: ids))
            let fingerprint = result.fingerprint
            presets[result.familyID?.split(separator: "#").first.map(String.init) ?? "", default: 0] += 1
            platforms[fingerprint.platform ?? .macOS, default: 0] += 1
            if fingerprint.deviceMemory == 32 { memory32 += 1 }
            if fingerprint.colorDepth == 30 { depth30 += 1 }
            #expect(fingerprint.touch != true || fingerprint.platform != .macOS)
        }
        #expect(presets["macos26-chrome"] == presets.values.max())
        #expect(presets["macos26-chrome", default: 0] > presets["macos15-chrome", default: 0])
        #expect(platforms[.macOS, default: 0] > platforms[.windows, default: 0])
        #expect(platforms[.windows, default: 0] > platforms[.linux, default: 0])
        // 32 GB and 30-bit panels are a minority of machines.
        #expect(memory32 < 1500 / 3)
        #expect(depth30 < 1500 / 5)

        // Touch screens are rare on Windows and almost absent on Linux.
        var touches = 0
        for _ in 0..<400 {
            let result = IdentitySampler.sampleResult(seed: FingerprintSettings.newSeed(excluding: []),
                                                      constraints: .init(platforms: [.windows]))
            if result.fingerprint.touch == true { touches += 1 }
        }
        #expect(touches > 0 && touches < 100)
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
