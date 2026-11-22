@testable import AnyBrowserCore
import Foundation
import Testing

struct FingerprintTests {
    private static let engine = BundledVersions.engine
    private static let hardware = EngineHardwareTable.bundled
    /// Hints every Windows or Linux identity carries on this engine.
    private static let hostHints: Set<String> = ["webgpu-host-gpu", "voices-host-os"]

    private func disabledSpoofing(_ fingerprint: FingerprintSettings) -> String? {
        fingerprint.arguments().first { $0.hasPrefix("--disable-spoofing=") }
    }

    private func issueIDs(_ fingerprint: FingerprintSettings, engine: String? = engine,
                          exit: ProxyExit? = nil, context: ConsistencyContext = ConsistencyContext()) -> [String] {
        BrowserProfile(name: "Check", port: 9301, fingerprint: fingerprint)
            .consistencyIssues(engineVersion: engine, exit: exit, context: context).map(\.id)
    }

    private func issues(_ fingerprint: FingerprintSettings, engine: String? = engine,
                        context: ConsistencyContext = ConsistencyContext()) -> [ConsistencyIssue] {
        BrowserProfile(name: "Check", port: 9301, fingerprint: fingerprint)
            .consistencyIssues(engineVersion: engine, exit: nil, context: context)
    }

    /// The brand version the randomizer may pick for a brand: released builds only, and empty
    /// for Edge, whose explicit version the engine would send unreduced.
    private func matches(_ version: String, _ brand: BrowserBrand?, platform: BrowserPlatform? = nil) -> Bool {
        switch brand {
        case .chrome:
            let builds = ["148.0.7778.217", "148.0.7778.179", "148.0.7778.168", "148.0.7778.97"]
            return builds.contains(version) || (platform != .windows && version == "148.0.7778.215")
        case .edge: return version.isEmpty
        case .opera: return version == "\(BundledVersions.engineMajor - 16).0.0.0"
        case .vivaldi: return ["7.5", "7.6"].contains(version)
        case nil: return version.isEmpty
        }
    }

    /// A seed for which every macOS GPU and memory combination exists.
    private func seed(_ seed: Int) -> Int {
        precondition(Self.hardware.macOSSeedExists(seed))
        return seed
    }

    // MARK: Launch arguments

    @Test("Linux never spoofs WebGL, whatever the adjustments say")
    func linuxDisablesWebGLSpoofing() {
        var fingerprint = FingerprintSettings(seed: 5)
        fingerprint.adjustments = Set(FingerprintAdjustment.allCases)
        #expect(disabledSpoofing(fingerprint) == nil)
        fingerprint.platform = .windows
        #expect(disabledSpoofing(fingerprint) == nil)
        fingerprint.platform = .linux
        #expect(disabledSpoofing(fingerprint) == "--disable-spoofing=gpu")
        fingerprint.adjustments = [.canvas]
        #expect(disabledSpoofing(fingerprint) == "--disable-spoofing=font,audio,clientrects,gpu")
    }

    @Test("-AppleLanguages carries the primary language as the last two arguments")
    func appleLanguagesFollowThePrimaryLanguage() {
        var fingerprint = FingerprintSettings(seed: 7)
        #expect(!fingerprint.arguments().contains("-AppleLanguages"))
        fingerprint.language = "de-DE"
        fingerprint.languages = ["de-DE", "de"]
        #expect(Array(fingerprint.arguments().suffix(2)) == ["-AppleLanguages", "<array><string>de-DE</string></array>"])
        #expect(fingerprint.arguments().filter { $0 == "-AppleLanguages" }.count == 1)
        // A generated list without a primary field still names the language.
        fingerprint.language = ""
        #expect(Array(fingerprint.arguments().suffix(2)) == ["-AppleLanguages", "<array><string>de-DE</string></array>"])
        // A hand-edited primary language wins over a stale generated list.
        fingerprint.language = "en-US"
        #expect(Array(fingerprint.arguments().suffix(2)) == ["-AppleLanguages", "<array><string>en-US</string></array>"])
        // Only a valid tag goes into the plist; validation rejects anything else before launch.
        fingerprint.language = "en</string>"
        #expect(!fingerprint.arguments().contains("-AppleLanguages"))
    }

    @Test("Choosing a platform drops what it cannot use")
    func adaptingToPlatform() {
        var fingerprint = FingerprintSettings(seed: 6)
        fingerprint.platform = .windows
        fingerprint.platformVersion = "19.0.0"
        fingerprint.adjustments = [.gpu, .canvas]
        fingerprint.adaptToPlatform()
        #expect(fingerprint.adjustments == [.gpu, .canvas])
        #expect(fingerprint.platformVersion == "19.0.0")

        fingerprint.platform = .linux
        fingerprint.adaptToPlatform()
        #expect(fingerprint.adjustments == [.canvas])

        fingerprint.platform = nil
        fingerprint.adaptToPlatform()
        #expect(fingerprint.platformVersion.isEmpty)
    }

    // MARK: Identity presets

    @Test("Identity presets set a whole identity and keep the seed, language, time zone and other adjustments")
    func identityPresets() throws {
        let mac26 = ["26.3.0", "26.3.1", "26.4.0", "26.4.1"]
        let expected: [(id: String, title: String, platform: BrowserPlatform, versions: Set<String>, brand: BrowserBrand)] = [
            ("win11-chrome", "Windows 11 · Chrome（实验性）", .windows, ["19.0.0"], .chrome),
            ("win11-edge", "Windows 11 · Edge（实验性）", .windows, ["19.0.0"], .edge),
            ("win10-chrome", "Windows 10 · Chrome（实验性）", .windows, ["10.0.0"], .chrome),
            ("macos27-chrome", "macOS 27 · Chrome", .macOS, ["27.0.0", "27.1.0", "27.2.0", "27.2.1"], .chrome),
            ("macos26-chrome", "macOS 26 · Chrome", .macOS, Set(mac26), .chrome),
            ("macos15-chrome", "macOS 15 · Chrome", .macOS, ["15.6.1", "15.7.0", "15.7.1", "15.7.2"], .chrome),
            ("linux-chrome", "Linux · Chrome", .linux, ["6.8.0", "6.14.0"], .chrome),
        ]
        #expect(IdentityPreset.all.map(\.id) == expected.map(\.id))
        #expect(IdentityPreset.all.map(\.title) == expected.map(\.title))
        #expect(IdentityPreset.all.filter(\.isExperimental).map(\.id) == ["win11-chrome", "win11-edge", "win10-chrome"])

        for item in expected {
            let preset = try #require(IdentityPreset.all.first { $0.id == item.id })
            // Both macOS GPUs, and a Linux start whose WebGL spoofing is off.
            for start in [(platform: BrowserPlatform.macOS, gpu: true, seed: seed(4244)),
                          (platform: .linux, gpu: false, seed: seed(4243))] {
                var fingerprint = FingerprintSettings(seed: start.seed)
                fingerprint.platform = start.platform
                fingerprint.platformVersion = start.platform == .linux ? "6.8.0" : "26.4.1"
                fingerprint.brand = .vivaldi
                fingerprint.brandVersion = "7.6"
                fingerprint.cpuCount = 32
                fingerprint.language = "ja-JP"
                fingerprint.timeZone = "Asia/Tokyo"
                fingerprint.adjustments = start.gpu ? [.font, .gpu, .clientRects] : [.font, .clientRects]
                preset.apply(to: &fingerprint)
                #expect(fingerprint.arguments().contains { $0.hasPrefix("--disable-spoofing=") && $0.contains("gpu") }
                        == (item.platform == .linux), "\(item.id) from \(start.platform)")

                #expect(fingerprint.platform == item.platform, "\(item.id)")
                #expect(item.versions.contains(fingerprint.platformVersion), "\(item.id)")
                #expect(fingerprint.brand == item.brand, "\(item.id)")
                // Chrome and Edge versions are left to the engine.
                #expect(fingerprint.brandVersion.isEmpty, "\(item.id)")
                let cpus = Self.hardware.gpu(for: item.platform, seed: start.seed)?.cpuCounts ?? [4, 8]
                #expect(cpus.contains(fingerprint.cpuCount ?? 0), "\(item.id) \(String(describing: fingerprint.cpuCount))")
                #expect(fingerprint.deviceMemory == Self.hardware.deviceMemory(seed: start.seed))
                #expect(fingerprint.seed == start.seed && fingerprint.language == "ja-JP" && fingerprint.timeZone == "Asia/Tokyo")
                #expect(fingerprint.adjustments == (item.platform == .linux ? [.font, .clientRects] : [.font, .gpu, .clientRects]),
                        "\(item.id)")
                let profile = try BrowserProfile(name: item.title, port: 9301, fingerprint: fingerprint).validated()
                let ids = Set(profile.consistencyIssues(engineVersion: Self.engine, exit: nil).map(\.id))
                let wanted: Set<String> = switch item.platform {
                case .macOS: []
                case .windows: Self.hostHints
                case .linux: Self.hostHints.union(["linux-webgl"])
                }
                #expect(ids == wanted, "\(item.id)")
            }
        }
    }

    // MARK: Hardware

    @Test("The hardware table follows the engine's seed arithmetic")
    func hardwareTable() throws {
        let table = Self.hardware
        #expect(table.engineMajor == BundledVersions.engineMajor)
        #expect(EngineHardwareTable.forEngine("148.0.7778.97") == table)
        #expect(EngineHardwareTable.forEngine("150.0.7871.186") == nil)
        #expect(table.macOS.map(\.model) == ["Apple M4", "Apple M2"])
        #expect(table.windows.count == 13)
        #expect(table.gpu(for: .macOS, seed: 22223)?.model == "Apple M2")
        #expect(table.gpu(for: .macOS, seed: 22224)?.model == "Apple M4")
        #expect(table.gpu(for: .windows, seed: 22223)?.renderer
                == "ANGLE (Intel, Intel(R) UHD Graphics (0x00009B41) Direct3D11 vs_5_0 ps_5_0, D3D11)")
        #expect(table.gpu(for: .windows, seed: 33334)?.model == "NVIDIA GeForce RTX 3060 Laptop GPU")
        #expect(table.gpu(for: nil, seed: 44445)?.model == "NVIDIA GeForce RTX 4060 Laptop GPU")
        #expect(table.gpu(for: .linux, seed: 1) == nil)
        #expect([11112, 33334, 22223].map(table.deviceMemory) == [8, 16, 32])
        #expect(table.defaultCPUCount(seed: 22223) == 20)
        #expect(Set(table.windows.flatMap(\.deviceMemory)) == [8, 16, 32])

        // M4 ships with 8 or 10 cores and at least 16 GB, the base M2 with 8 cores and at most 24 GB.
        #expect(table.exists(platform: .macOS, seed: 2, cpuCount: 10))
        #expect(table.exists(platform: .macOS, seed: 4, cpuCount: 8))
        #expect(!table.exists(platform: .macOS, seed: 4, cpuCount: 12))
        #expect(!table.exists(platform: .macOS, seed: 6, cpuCount: 10))
        #expect(table.exists(platform: .macOS, seed: 1, cpuCount: 8))
        #expect(!table.exists(platform: .macOS, seed: 1, cpuCount: 10))
        #expect(!table.exists(platform: .macOS, seed: 5, cpuCount: 8))
        #expect(table.exists(platform: .linux, seed: 5, cpuCount: 64))
        for residue in 0..<6 {
            #expect(table.macOSSeedExists(residue + 600) == ![0, 5].contains(residue), "\(residue)")
        }
    }

    @Test("New seeds never give a macOS GPU and memory that do not exist together")
    func newSeedsSkipImpossibleMachines() {
        var seen: Set<Int> = []
        for _ in 0..<2000 {
            let seed = FingerprintSettings.newSeed(excluding: [])
            #expect(![0, 5].contains(seed % 6), "\(seed)")
            seen.insert(seed % 6)
        }
        #expect(seen == [1, 2, 3, 4])
        let taken = Set(1...10)
        #expect(!taken.contains(FingerprintSettings.newSeed(excluding: taken)))
    }

    @Test("A combination that does not exist gets a hardware-impossible hint")
    func hardwareImpossibleHint() throws {
        var mac = FingerprintSettings(seed: 7)   // Apple M2, 16 GB
        mac.platform = .macOS
        mac.adjustments = [.canvas, .gpu]
        mac.cpuCount = 8
        #expect(!issueIDs(mac).contains("hardware-impossible"))
        mac.cpuCount = 10
        let message = try #require(issues(mac).first { $0.id == "hardware-impossible" }?.message)
        #expect(message.contains("Apple M2") && message.contains("10"))
        // M2 with 32 GB, from the seed alone.
        mac.seed = 11
        mac.cpuCount = 8
        #expect(issueIDs(mac).contains("hardware-impossible"))
        // M4 with 8 GB.
        mac.seed = 12
        mac.cpuCount = 10
        #expect(issueIDs(mac).contains("hardware-impossible"))
        // Without a CPU count the engine reports ((seed % 13) + 4) * 2.
        mac.seed = 22224
        mac.cpuCount = nil
        #expect(issueIDs(mac).contains("hardware-impossible"))
        // WebGL shows this Mac's own GPU when spoofing is off, and an unknown engine is not judged.
        mac.cpuCount = 12
        #expect(issueIDs(mac).contains("hardware-impossible"))
        #expect(!issueIDs(mac, engine: "150.0.7871.186").contains("hardware-impossible"))
        #expect(!issueIDs(mac, engine: nil).contains("hardware-impossible"))
        mac.adjustments = [.canvas]
        #expect(!issueIDs(mac).contains("hardware-impossible"))

        var windows = FingerprintSettings(seed: 44445)   // RTX 4060 Laptop
        windows.platform = .windows
        windows.adjustments = [.canvas, .gpu]
        windows.cpuCount = 4
        #expect(issueIDs(windows).contains("hardware-impossible"))
        windows.cpuCount = 16
        #expect(!issueIDs(windows).contains("hardware-impossible"))
    }

    @Test("Ten thousand sampled identities are all machines that exist")
    func sampledHardwareExists() {
        for index in 0..<10_000 {
            let seed = FingerprintSettings.newSeed(excluding: [])
            let preset = IdentityPreset.all[index % IdentityPreset.all.count]
            let fingerprint = IdentitySampler.sample(seed: seed, preset: preset)
            #expect(Self.hardware.exists(platform: fingerprint.platform, seed: seed, cpuCount: fingerprint.cpuCount),
                    "\(preset.id) \(seed) \(String(describing: fingerprint.cpuCount))")
            #expect(fingerprint.deviceMemory == Self.hardware.deviceMemory(seed: seed))
        }
    }

    // MARK: Randomizing

    @Test("A new random platform keeps its version consistent and follows the identity weights")
    func randomPlatformKeepsVersionConsistent() {
        var counts: [BrowserPlatform: Int] = [:]
        for _ in 0..<300 {
            var fingerprint = FingerprintSettings(seed: seed(14))
            fingerprint.platform = .macOS
            fingerprint.platformVersion = "26.2.0"
            fingerprint.adjustments = Set(FingerprintAdjustment.allCases)
            fingerprint.randomize([.platform], excluding: [])
            counts[fingerprint.platform!, default: 0] += 1
            #expect(!fingerprint.platformVersion.isEmpty)
            #expect(!issueIDs(fingerprint).contains("platform-version"), "\(fingerprint.platform!) \(fingerprint.platformVersion)")
            #expect(fingerprint.adjustments.contains(.gpu) == (fingerprint.platform != .linux))

            var unversioned = FingerprintSettings(seed: 12)
            unversioned.platform = .windows
            unversioned.randomize([.platform], excluding: [])
            #expect(unversioned.platformVersion.isEmpty)
        }
        // macOS carries 100 of the 121 weight points, Windows 20 and Linux 1.
        #expect(counts[.macOS, default: 0] > counts[.windows, default: 0])
        #expect(counts[.windows, default: 0] > 0)
    }

    @Test("A new random brand keeps its version consistent and never picks an experimental brand")
    func randomBrandKeepsVersionConsistent() throws {
        var seen: Set<BrowserBrand> = []
        for _ in 0..<300 {
            var versioned = FingerprintSettings(seed: 21)
            versioned.platform = .windows
            versioned.brand = .chrome
            versioned.brandVersion = "148.0.7778.217"
            versioned.randomize([.brand], excluding: [])
            #expect(matches(versioned.brandVersion, versioned.brand, platform: .windows),
                    "\(versioned.brand!) \(versioned.brandVersion)")

            var unversioned = FingerprintSettings(seed: 22)
            unversioned.brand = .edge
            unversioned.randomize([.brand], excluding: [])
            let brand = try #require(unversioned.brand)
            seen.insert(brand)
            #expect(unversioned.brandVersion.isEmpty, "\(brand) \(unversioned.brandVersion)")
            #expect(throws: Never.self) { try BrowserProfile(name: "R", port: 9301, fingerprint: unversioned).validated() }

            // A kept macOS platform has no Edge preset.
            var mac = FingerprintSettings(seed: 24)
            mac.platform = .macOS
            mac.randomize([.brand], excluding: [])
            #expect(mac.brand == .chrome)

            var everything = FingerprintSettings(seed: 23)
            everything.randomize(Set(FingerprintField.allCases), excluding: [])
            #expect(matches(everything.brandVersion, everything.brand, platform: everything.platform))
            var expected: Set<String> = switch everything.platform {
            case .linux: Self.hostHints.union(["linux-webgl"])
            case .windows where !everything.adjustments.contains(.gpu): Self.hostHints.union(["webgl-real-gpu"])
            case .windows: Self.hostHints
            default: []
            }
            if let platform = everything.platform, platform != .macOS, everything.fontProfile != nil {
                expected.insert("font-spoof-missing")
            }
            #expect(Set(issueIDs(everything)) == expected, "\(everything)")
        }
        #expect(seen.isSubset(of: [.chrome, .edge]) && seen.contains(.chrome))
    }

    @Test("Randomized brand versions are released builds: no .73, no .215 on Windows, none for Edge")
    func randomBrandVersionsAreReleased() {
        for platform in [BrowserPlatform.windows, .macOS] {
            for brand in BrowserBrand.allCases {
                for _ in 0..<60 {
                    var fingerprint = FingerprintSettings(seed: 25)
                    fingerprint.platform = platform
                    fingerprint.brand = brand
                    fingerprint.randomize([.brandVersion], excluding: [])
                    #expect(matches(fingerprint.brandVersion, brand, platform: platform), "\(platform) \(brand) \(fingerprint.brandVersion)")
                    #expect(!fingerprint.brandVersion.hasSuffix(".73"))
                    #expect(throws: Never.self) { try BrowserProfile(name: "R", port: 9301, fingerprint: fingerprint).validated() }
                }
            }
        }
    }

    @Test("Field-level platform and brand only produce preset combinations")
    func fieldRandomizationFollowsPresets() {
        let pairs = Set(IdentityPreset.all.map { "\($0.platform.rawValue)/\($0.brand.rawValue)" })
        for _ in 0..<500 {
            var fingerprint = FingerprintSettings(seed: 26)
            fingerprint.brand = .opera
            fingerprint.brandVersion = "132.0.0.0"
            fingerprint.randomize([.platform, .brand, .platformVersion], excluding: [])
            let pair = "\(fingerprint.platform!.rawValue)/\(fingerprint.brand!.rawValue)"
            #expect(pairs.contains(pair), "\(pair)")
            let versions = IdentityPreset.all.filter { $0.platform == fingerprint.platform }.flatMap(\.platformVersions)
            #expect(versions.contains(fingerprint.platformVersion))
        }
    }

    @Test("Field randomization keeps language and time zone paired")
    func languageAndTimeZoneStayPaired() {
        let languages: Set<String> = ["en-US", "en-GB", "zh-CN", "ja-JP", "de-DE",
                                      "fr-FR", "es-ES", "pt-BR", "ko-KR"]
        let zones: Set<String> = ["America/New_York", "America/Chicago", "America/Denver",
                                  "America/Los_Angeles", "Europe/London", "Asia/Shanghai",
                                  "Asia/Tokyo", "Europe/Berlin", "Europe/Paris",
                                  "Europe/Madrid", "America/Sao_Paulo", "Asia/Seoul"]
        for field in [FingerprintField.language, .timeZone] {
            for _ in 0..<50 {
                var fingerprint = FingerprintSettings(seed: 101)
                fingerprint.randomize([field], excluding: [])
                #expect(languages.contains(fingerprint.language))
                #expect(zones.contains(fingerprint.timeZone))
                #expect(fingerprint.languages?.first == fingerprint.language)
                #expect(fingerprint.languages?.count == 2)
            }
        }
    }

    @Test("CPU counts follow the GPU the seed gives WebGL, or the platform when WebGL is the Mac's")
    func cpuCountsFollowHardware() {
        let unspoofed: [(BrowserPlatform?, Set<Int>)] = [
            (.macOS, [8, 10, 12]), (.windows, [4, 8, 12, 16]), (.linux, [4, 8]), (nil, [4, 8, 12, 16]),
        ]
        for (platform, allowed) in unspoofed {
            for _ in 0..<100 {
                var fingerprint = FingerprintSettings(seed: 102)
                fingerprint.platform = platform
                fingerprint.randomize([.cpuCount], excluding: [])
                #expect(allowed.contains(fingerprint.cpuCount ?? 0),
                        "\(String(describing: platform)) \(String(describing: fingerprint.cpuCount))")
            }
        }
        // 102 is even (Apple M4) and 102 % 13 is 11 (RTX 4060 Laptop).
        for (platform, allowed) in [(BrowserPlatform.macOS, Set([8, 10])), (.windows, [16, 20])] {
            for _ in 0..<100 {
                var fingerprint = FingerprintSettings(seed: 102)
                fingerprint.platform = platform
                fingerprint.adjustments.insert(.gpu)
                fingerprint.randomize([.cpuCount], excluding: [])
                #expect(allowed.contains(fingerprint.cpuCount ?? 0), "\(platform)")
            }
        }
    }

    @Test("A new seed keeps a kept CPU count on a machine that exists")
    func newSeedFitsKeptCPU() {
        for cpus in [8, 10] {
            for _ in 0..<100 {
                var fingerprint = FingerprintSettings(seed: seed(14))
                fingerprint.platform = .macOS
                fingerprint.adjustments = [.canvas, .gpu]
                fingerprint.cpuCount = cpus
                fingerprint.randomize([.seed], excluding: [])
                #expect(fingerprint.cpuCount == cpus)
                #expect(fingerprint.seed != 14)
                #expect(Self.hardware.exists(platform: .macOS, seed: fingerprint.seed, cpuCount: cpus), "\(fingerprint.seed)")
                #expect(fingerprint.deviceMemory == Self.hardware.deviceMemory(seed: fingerprint.seed))
            }
        }
        // Randomizing the seed and the CPU together derives the count from the new GPU.
        for _ in 0..<100 {
            var fingerprint = FingerprintSettings(seed: seed(14))
            fingerprint.platform = .windows
            fingerprint.adjustments = [.canvas, .gpu]
            fingerprint.randomize([.seed, .cpuCount], excluding: [])
            #expect(Self.hardware.exists(platform: .windows, seed: fingerprint.seed, cpuCount: fingerprint.cpuCount))
        }
    }

    @Test("Randomized adjustments follow the platform")
    func adjustmentsFollowPlatform() {
        for platform in [BrowserPlatform.macOS, .windows, .linux] {
            for _ in 0..<50 {
                var fingerprint = FingerprintSettings(seed: 103)
                fingerprint.platform = platform
                fingerprint.adjustments = [.canvas, .clientRects, .font]
                fingerprint.randomize([.adjustments], excluding: [])
                #expect(fingerprint.adjustments.contains(.canvas))
                #expect(fingerprint.adjustments.contains(.clientRects))
                #expect(fingerprint.adjustments.contains(.gpu) == (platform != .linux))
                if platform == .macOS {
                    #expect(fingerprint.adjustments.contains(.font))
                } else {
                    #expect(!fingerprint.adjustments.contains(.font))
                }
            }
        }
        var unset = FingerprintSettings(seed: 104)
        unset.randomize([.adjustments], excluding: [])
        #expect(!unset.adjustments.contains(.gpu))
    }

    @Test("Changing platform clears values that cannot follow it and re-derives the hardware")
    func platformChangeClearsStaleValues() {
        for _ in 0..<50 {
            var fingerprint = FingerprintSettings(seed: seed(105))
            fingerprint.platform = .macOS
            fingerprint.platformVersion = "26.2.0"
            fingerprint.fontProfile = .macos26
            fingerprint.screenWidth = 1728
            fingerprint.screenHeight = 1117
            fingerprint.availWidth = 1728
            fingerprint.availHeight = 1080
            fingerprint.colorDepth = 30
            fingerprint.deviceScaleFactor = 2
            fingerprint.deviceMemory = 8
            fingerprint.cpuCount = 8
            fingerprint.touch = true
            fingerprint.adjustments = [.canvas, .clientRects, .font, .gpu]

            fingerprint.randomize([.platform], excluding: [])
            let platform = fingerprint.platform ?? .macOS
            #expect(fingerprint.screenWidth == nil)
            #expect(fingerprint.screenHeight == nil)
            #expect(fingerprint.availWidth == nil)
            #expect(fingerprint.availHeight == nil)
            #expect(fingerprint.colorDepth == nil)
            #expect(fingerprint.deviceScaleFactor == nil)
            // Memory comes from the seed on every platform.
            #expect(fingerprint.deviceMemory == Self.hardware.deviceMemory(seed: 105))
            #expect(Self.hardware.exists(platform: platform, seed: 105, cpuCount: fingerprint.cpuCount))
            #expect(fingerprint.touch == false)
            #expect(fingerprint.fontProfile?.platform == platform)
            #expect(fingerprint.adjustments.contains(.gpu) == (platform != .linux))
            if platform != .macOS {
                #expect(!fingerprint.adjustments.contains(.font))
            }
            #expect(throws: Never.self) {
                try BrowserProfile(name: "R", port: 9301, fingerprint: fingerprint).validated()
            }
        }
    }

    @Test("Randomizing every field never creates a cross-field contradiction")
    func randomEverythingIsCoherent() {
        // Only the known engine limitations may remain.
        let allowed: Set<String> = Self.hostHints.union(["linux-webgl", "font-spoof-missing"])
        for _ in 0..<200 {
            var fingerprint = FingerprintSettings(seed: Int.random(in: 1...100_000))
            fingerprint.randomize(Set(FingerprintField.allCases), excluding: [])
            let ids = Set(issueIDs(fingerprint))
            #expect(ids.isSubset(of: allowed), "\(fingerprint) -> \(ids)")
            if let platform = fingerprint.platform {
                #expect(fingerprint.fontProfile?.platform == platform)
            }
            #expect(fingerprint.languages?.first == fingerprint.language)
        }
    }

    @Test("Saving normalizes the language list and font profile")
    func savingNormalizesIdentityFields() throws {
        var fingerprint = FingerprintSettings(seed: 111)
        fingerprint.platform = .macOS
        fingerprint.platformVersion = "15.7.1"
        fingerprint.fontProfile = .macos26
        fingerprint.language = "ja-JP"
        fingerprint.languages = ["en-US", "en"]
        let profile = try BrowserProfile(name: "N", port: 9301, fingerprint: fingerprint).validated()
        #expect(profile.fingerprint.languages == ["ja-JP", "ja"])
        #expect(profile.fingerprint.fontProfile == .macos15)

        var cleared = profile.fingerprint
        cleared.language = ""
        cleared.languages = ["ja-JP", "ja"]
        let reopened = try BrowserProfile(name: "N", port: 9301, fingerprint: cleared).validated()
        #expect(reopened.fingerprint.languages == nil)
    }

    @Test("Engine-default platform clears platform-specific claims but keeps the seed's memory")
    func engineDefaultClearsPlatformClaims() {
        var fingerprint = FingerprintSettings(seed: 112)
        fingerprint.platform = .windows
        fingerprint.platformVersion = "19.0.0"
        fingerprint.fontProfile = .windows11
        fingerprint.screenWidth = 1920
        fingerprint.screenHeight = 1080
        fingerprint.availWidth = 1920
        fingerprint.availHeight = 1040
        fingerprint.colorDepth = 24
        fingerprint.deviceScaleFactor = 1
        fingerprint.deviceMemory = 8
        fingerprint.adaptToPlatform()
        #expect(fingerprint.fontProfile == .windows11)
        // A recorded memory follows what the engine reports for the seed.
        #expect(fingerprint.deviceMemory == 16)

        fingerprint.platform = nil
        fingerprint.adaptToPlatform()
        #expect(fingerprint.platformVersion.isEmpty)
        #expect(fingerprint.fontProfile == nil)
        #expect(fingerprint.screenWidth == nil)
        #expect(fingerprint.screenHeight == nil)
        #expect(fingerprint.colorDepth == nil)
        #expect(fingerprint.deviceScaleFactor == nil)
        #expect(fingerprint.deviceMemory == 16)
    }

    @Test("A new macOS version updates the font profile")
    func macOSVersionUpdatesFontProfile() {
        var versions: Set<String> = []
        for _ in 0..<200 {
            var fingerprint = FingerprintSettings(seed: 106)
            fingerprint.platform = .macOS
            fingerprint.fontProfile = .macos26
            fingerprint.randomize([.platformVersion], excluding: [])
            versions.insert(String(fingerprint.platformVersion.prefix(2)))
            #expect(fingerprint.fontProfile == (fingerprint.platformVersion.hasPrefix("15") ? .macos15 : .macos26))
        }
        #expect(versions == ["15", "26", "27"])
    }

    @Test("Randomizing anything leaves a Linux identity without WebGL spoofing")
    func randomizingLinuxDropsWebGL() {
        var fingerprint = FingerprintSettings(seed: 31)
        fingerprint.platform = .linux
        fingerprint.adjustments = Set(FingerprintAdjustment.allCases)
        fingerprint.randomize([.language], excluding: [])
        #expect(!fingerprint.adjustments.contains(.gpu))
        #expect(fingerprint.adjustments.contains(.canvas))
    }

    // MARK: Consistency checks

    @Test("Chrome and Edge versions must sit near the engine")
    func brandVersionAgainstEngine() {
        var fingerprint = FingerprintSettings(seed: 41)
        fingerprint.brand = .chrome
        fingerprint.brandVersion = "148.0.7778.215"
        #expect(issueIDs(fingerprint).isEmpty)
        fingerprint.brandVersion = "145.0.1.2"
        #expect(issueIDs(fingerprint).isEmpty)
        fingerprint.brandVersion = "149.0.1.2"
        #expect(issueIDs(fingerprint) == ["brand-version-ahead"])
        fingerprint.brandVersion = "144.0.1.2"
        #expect(issueIDs(fingerprint) == ["brand-version-behind"])
        #expect(issueIDs(fingerprint, engine: nil).isEmpty)

        fingerprint.brand = .edge
        fingerprint.brandVersion = " 150.0.3967.54 "
        let found = BrowserProfile(name: "E", port: 9301, fingerprint: fingerprint)
            .consistencyIssues(engineVersion: Self.engine, exit: nil)
        #expect(found.first == ConsistencyIssue(id: "brand-version-ahead", message: "Edge 版本 150.0.3967.54 高于内核版本 148"))
        #expect(found.map(\.id) == ["brand-version-ahead", "edge-ua-version"])
        fingerprint.brandVersion = ""
        #expect(issueIDs(fingerprint).isEmpty)
    }

    @Test("An explicit Edge version is flagged because the engine sends it unreduced")
    func edgeUserAgentVersion() throws {
        var fingerprint = FingerprintSettings(seed: 42)
        fingerprint.brand = .edge
        fingerprint.brandVersion = "148.0.3967.54"
        let message = try #require(issues(fingerprint).first { $0.id == "edge-ua-version" }?.message)
        #expect(message.contains("Edg/148.0.3967.54") && message.contains("Edg/148.0.0.0"))
        fingerprint.brandVersion = ""
        #expect(!issueIDs(fingerprint).contains("edge-ua-version"))
    }

    @Test("Opera and Vivaldi are marked experimental")
    func experimentalBrands() throws {
        var fingerprint = FingerprintSettings(seed: 43)
        fingerprint.brand = .opera
        fingerprint.brandVersion = "132.0.0.0"
        let opera = try #require(issues(fingerprint).first { $0.id == "brand-experimental" }?.message)
        #expect(opera.contains("UA-CH") && opera.contains("\(BundledVersions.engineMajor - 16)"))
        fingerprint.brand = .vivaldi
        fingerprint.brandVersion = "7.5"
        #expect(issueIDs(fingerprint) == ["brand-experimental"])
        fingerprint.brand = .chrome
        fingerprint.brandVersion = ""
        #expect(issueIDs(fingerprint).isEmpty)
    }

    @Test("Platform versions must fit the platform, macOS 27 included")
    func platformVersionAgainstPlatform() {
        let nextMac = max(27, ProcessInfo.processInfo.operatingSystemVersion.majorVersion + 1)
        let cases: [(BrowserPlatform, String, Bool)] = [
            (.macOS, "10.15.7", true), (.macOS, "26.2.0", true), (.macOS, "9.0", false), (.macOS, "27.2.1", true),
            (.macOS, "\(nextMac).0.0", true), (.macOS, "\(nextMac + 1).0.0", false),
            (.windows, "0.1.0", true), (.windows, "19.0.0", true), (.windows, "20.0.0", true), (.windows, "26.2.0", false),
            (.linux, "2.6.32", true), (.linux, "6.8.0", true), (.linux, "7.0", true), (.linux, "1.0", false), (.linux, "8.0", false),
        ]
        for (platform, version, fits) in cases {
            var fingerprint = FingerprintSettings(seed: 51)
            fingerprint.platform = platform
            fingerprint.platformVersion = version
            fingerprint.adjustments = [.gpu]
            #expect(issueIDs(fingerprint).contains("platform-version") == !fits, "\(platform) \(version)")
        }
        var windows = FingerprintSettings(seed: 52)
        windows.platform = .windows
        windows.platformVersion = "26.2.0"
        windows.adjustments = [.gpu]
        #expect(BrowserProfile(name: "W", port: 9301, fingerprint: windows).consistencyIssues(engineVersion: nil, exit: nil)
            .first?.message == "平台版本 26.2.0 与 Windows 不匹配（Windows 主版本应为 0–20）")
        windows.platformVersion = ""
        #expect(!issueIDs(windows).contains("platform-version"))
    }

    @Test("WebGL must agree with the platform: Linux and unspoofed Windows show this Mac's GPU")
    func webGLAgainstPlatform() {
        let cases: [(BrowserPlatform?, gpu: Bool, [String])] = [
            (nil, false, []), (nil, true, ["webgl-windows-gpu"]),
            (.windows, true, []), (.windows, false, ["webgl-real-gpu"]),
            (.macOS, true, []), (.macOS, false, []),
            (.linux, true, ["linux-webgl"]), (.linux, false, ["linux-webgl"]),
        ]
        for (platform, gpu, expected) in cases {
            var fingerprint = FingerprintSettings(seed: 61)
            fingerprint.platform = platform
            fingerprint.adjustments = gpu ? [.canvas, .gpu] : [.canvas]
            #expect(issueIDs(fingerprint).filter { $0.contains("webgl") } == expected,
                    "\(String(describing: platform)) gpu=\(gpu)")
        }
        var windows = FingerprintSettings(seed: 62)
        windows.platform = .windows
        windows.adjustments = []
        #expect(BrowserProfile(name: "W", port: 9301, fingerprint: windows).consistencyIssues(engineVersion: nil, exit: nil)
            .first?.message == "WebGL 改写已关闭，网页会读到本机真实显卡，与 Windows 身份不符")
    }

    @Test("Windows and Linux identities are told that WebGPU, voices and fonts stay this Mac's")
    func hostConstantsOnOtherPlatforms() throws {
        for platform in [BrowserPlatform?.none, .macOS] {
            var fingerprint = FingerprintSettings(seed: 63)
            fingerprint.platform = platform
            #expect(Set(issueIDs(fingerprint)).isDisjoint(with: Self.hostHints.union(["font-spoof-missing"])))
        }
        for platform in [BrowserPlatform.windows, .linux] {
            var fingerprint = FingerprintSettings(seed: 63)
            fingerprint.platform = platform
            fingerprint.fontProfile = FontProfile.default(for: platform)
            let found = issues(fingerprint)
            #expect(Self.hostHints.isSubset(of: Set(found.map(\.id))), "\(platform)")
            let font = try #require(found.first { $0.id == "font-spoof-missing" }?.message)
            // Turning the font switch on does not fix it, and the hint must not suggest it does.
            #expect(!font.contains("尚未启用"))
            #expect(font.contains("本机 macOS 字体"))
            fingerprint.adjustments.insert(.font)
            let synthetic = try #require(issues(fingerprint).first { $0.id == "font-spoof-missing" }?.message)
            #expect(synthetic.contains("按种子"))
        }
    }

    @Test("Shared exits and an old engine come from the context")
    func contextHints() throws {
        let fingerprint = FingerprintSettings(seed: 64)
        #expect(issueIDs(fingerprint, context: ConsistencyContext(profilesSharingExit: [])).isEmpty)
        let shared = try #require(issues(fingerprint, context: ConsistencyContext(profilesSharingExit: ["A", "B"]))
            .first { $0.id == "exit-shared" })
        #expect(shared.message.contains("「A」、「B」"))
        let many = try #require(issues(fingerprint, context: ConsistencyContext(profilesSharingExit: ["A", "B", "C", "D", "E"]))
            .first { $0.id == "exit-shared" })
        #expect(many.message.contains("等 5 个 Profile") && !many.message.contains("「D」"))

        #expect(!issueIDs(fingerprint, context: ConsistencyContext(engineMajorsBehindStable: 1)).contains("engine-behind"))
        let behind = try #require(issues(fingerprint, context: ConsistencyContext(engineMajorsBehindStable: 11))
            .first { $0.id == "engine-behind" })
        #expect(behind.message.contains("148") && behind.message.contains("11"))
    }

    @Test("A new Profile with default settings shows no consistency hints")
    func newProfileHasNoHints() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let draft = try ProfileStore(directory: directory).makeDraft()
            #expect(draft.fingerprint.platform != nil)
            #expect(draft.fingerprint.adjustments.contains(.gpu))
            #expect(draft.fingerprint.adjustments.contains(.audio))
            #expect(draft.fingerprint.languages?.isEmpty == false)
            #expect(draft.consistencyIssues(engineVersion: Self.engine, exit: nil).isEmpty)
        }
    }

    @Test("Time zone must match the proxy exit")
    func timeZoneAgainstExit() {
        let tokyo = ProxyExit(ip: "203.0.113.7", countryCode: "JP", city: "东京", timeZone: "Asia/Tokyo")
        var fingerprint = FingerprintSettings(seed: 71)
        fingerprint.timeZone = "Asia/Shanghai"
        #expect(issueIDs(fingerprint).isEmpty)
        #expect(BrowserProfile(name: "T", port: 9301, fingerprint: fingerprint)
            .consistencyIssues(engineVersion: nil, exit: tokyo).map(\.message)
            == ["时区 Asia/Shanghai 与出口 IP 所在地（东京, JP）的 Asia/Tokyo 不一致"])
        fingerprint.timeZone = "Asia/Tokyo"
        #expect(issueIDs(fingerprint, exit: tokyo).isEmpty)
        fingerprint.timeZone = "Asia/Shanghai"
        #expect(issueIDs(fingerprint, exit: ProxyExit(ip: "203.0.113.7")).isEmpty)

        // An empty time zone follows this Mac.
        fingerprint.timeZone = ""
        let local = TimeZone.current.identifier
        let elsewhere = local == "Asia/Tokyo" ? "Europe/Paris" : "Asia/Tokyo"
        #expect(issueIDs(fingerprint, exit: ProxyExit(ip: "203.0.113.7", timeZone: local)).isEmpty)
        let issues = BrowserProfile(name: "T", port: 9301, fingerprint: fingerprint)
            .consistencyIssues(engineVersion: nil, exit: ProxyExit(ip: "203.0.113.7", timeZone: elsewhere))
        #expect(issues.map(\.message) == ["本机时区 \(local) 与出口 IP 的 \(elsewhere) 不一致"])
    }

    @Test("Language must be spoken where the proxy exits")
    func languageAgainstExit() {
        let tokyo = ProxyExit(ip: "203.0.113.7", countryCode: "JP", city: "东京", timeZone: "", languages: ["ja-JP", "en"])
        var fingerprint = FingerprintSettings(seed: 81)
        fingerprint.language = "zh-CN"
        #expect(issueIDs(fingerprint).isEmpty)
        #expect(BrowserProfile(name: "L", port: 9301, fingerprint: fingerprint)
            .consistencyIssues(engineVersion: nil, exit: tokyo).map(\.message)
            == ["语言 zh-CN 与出口 IP 所在地（东京, JP）的常用语言 ja-JP、en 不一致"])
        fingerprint.language = "ja"
        #expect(issueIDs(fingerprint, exit: tokyo).isEmpty)
        fingerprint.language = "EN-gb"
        #expect(issueIDs(fingerprint, exit: tokyo).isEmpty)
        fingerprint.language = "zh-CN"
        #expect(issueIDs(fingerprint, exit: ProxyExit(ip: "203.0.113.7", countryCode: "JP")).isEmpty)

        // An empty language follows this Mac.
        fingerprint.language = ""
        let local = Locale.preferredLanguages.first ?? ""
        let primary = String(local.prefix { $0 != "-" && $0 != "_" })
        if !primary.isEmpty {
            #expect(issueIDs(fingerprint, exit: ProxyExit(ip: "203.0.113.7", languages: [primary])).isEmpty)
            let other = primary.lowercased() == "ja" ? "fr" : "ja"
            #expect(issueIDs(fingerprint, exit: ProxyExit(ip: "203.0.113.7", languages: [other])) == ["language"])
        }
    }
}
