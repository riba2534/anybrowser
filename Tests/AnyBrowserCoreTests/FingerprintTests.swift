@testable import AnyBrowserCore
import Foundation
import Testing

struct FingerprintTests {
    private static let engine = "148.0.7778.215"

    private func disabledSpoofing(_ fingerprint: FingerprintSettings) -> String? {
        fingerprint.arguments().first { $0.hasPrefix("--disable-spoofing=") }
    }

    private func issueIDs(_ fingerprint: FingerprintSettings, engine: String? = engine,
                          exit: ProxyExit? = nil) -> [String] {
        BrowserProfile(name: "Check", port: 9301, fingerprint: fingerprint)
            .consistencyIssues(engineVersion: engine, exit: exit).map(\.id)
    }

    /// The brand version the randomizer may pick for a brand.
    private func matches(_ version: String, _ brand: BrowserBrand?) -> Bool {
        switch brand {
        case .chrome: return version.hasPrefix("148.0.7778.")
        case .edge: return version.hasPrefix("148.0.3967.")
        case .opera: return ["120.0", "121.0"].contains(version)
        case .vivaldi: return ["7.5", "7.6"].contains(version)
        case nil: return version.isEmpty
        }
    }

    // MARK: Linux and WebGL

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
        let expected: [(id: String, title: String, platform: BrowserPlatform, version: String,
                        brand: BrowserBrand, brandVersion: String, cpus: Set<Int>)] = [
            ("win11-chrome", "Windows 11 · Chrome", .windows, "19.0.0", .chrome, "148.0.7778.215", [4, 8, 12, 16]),
            ("win11-edge", "Windows 11 · Edge", .windows, "19.0.0", .edge, "148.0.3967.54", [4, 8, 12, 16]),
            ("win10-chrome", "Windows 10 · Chrome", .windows, "10.0.0", .chrome, "148.0.7778.215", [4, 8, 12, 16]),
            ("macos26-chrome", "macOS 26 · Chrome", .macOS, "26.2.0", .chrome, "148.0.7778.215", [8, 10, 12]),
            ("macos15-chrome", "macOS 15 · Chrome", .macOS, "15.7.1", .chrome, "148.0.7778.215", [8, 10, 12]),
            ("linux-chrome", "Linux · Chrome", .linux, "6.8.0", .chrome, "148.0.7778.215", [4, 8]),
        ]
        #expect(IdentityPreset.all.map(\.id) == expected.map(\.id))
        #expect(IdentityPreset.all.map(\.title) == expected.map(\.title))

        for item in expected {
            let preset = try #require(IdentityPreset.all.first { $0.id == item.id })
            // Also start from a Linux identity, whose WebGL spoofing is off.
            for start in [(platform: BrowserPlatform.macOS, gpu: true), (platform: .linux, gpu: false)] {
                var fingerprint = FingerprintSettings(seed: 4242)
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
                #expect(fingerprint.platformVersion == item.version, "\(item.id)")
                #expect(fingerprint.brand == item.brand, "\(item.id)")
                #expect(fingerprint.brandVersion == item.brandVersion, "\(item.id)")
                #expect(item.cpus.contains(fingerprint.cpuCount ?? 0), "\(item.id)")
                #expect(fingerprint.seed == 4242 && fingerprint.language == "ja-JP" && fingerprint.timeZone == "Asia/Tokyo")
                #expect(fingerprint.adjustments == (item.platform == .linux ? [.font, .clientRects] : [.font, .gpu, .clientRects]),
                        "\(item.id)")
                let profile = try BrowserProfile(name: item.title, port: 9301, fingerprint: fingerprint).validated()
                #expect(profile.consistencyIssues(engineVersion: Self.engine, exit: nil).map(\.id)
                        == (item.platform == .linux ? ["linux-webgl"] : []), "\(item.id)")
            }
        }
    }

    // MARK: Randomizing

    @Test("A new random platform keeps its version consistent")
    func randomPlatformKeepsVersionConsistent() {
        var seen: Set<BrowserPlatform> = []
        for _ in 0..<200 {
            var fingerprint = FingerprintSettings(seed: 11)
            fingerprint.platform = .macOS
            fingerprint.platformVersion = "26.2.0"
            fingerprint.adjustments = Set(FingerprintAdjustment.allCases)
            fingerprint.randomize([.platform], excluding: [])
            seen.insert(fingerprint.platform!)
            #expect(!fingerprint.platformVersion.isEmpty)
            #expect(!issueIDs(fingerprint).contains("platform-version"), "\(fingerprint.platform!) \(fingerprint.platformVersion)")
            #expect(fingerprint.adjustments.contains(.gpu) == (fingerprint.platform != .linux))

            var unversioned = FingerprintSettings(seed: 12)
            unversioned.platform = .windows
            unversioned.randomize([.platform], excluding: [])
            #expect(unversioned.platformVersion.isEmpty)
        }
        #expect(seen == Set(BrowserPlatform.allCases))
    }

    @Test("A new random brand keeps its version consistent")
    func randomBrandKeepsVersionConsistent() throws {
        var seen: Set<BrowserBrand> = []
        for _ in 0..<200 {
            var versioned = FingerprintSettings(seed: 21)
            versioned.brand = .chrome
            versioned.brandVersion = "148.0.7778.215"
            versioned.randomize([.brand], excluding: [])
            #expect(matches(versioned.brandVersion, versioned.brand), "\(versioned.brand!) \(versioned.brandVersion)")

            var unversioned = FingerprintSettings(seed: 22)
            unversioned.brand = .edge
            unversioned.randomize([.brand], excluding: [])
            let brand = try #require(unversioned.brand)
            seen.insert(brand)
            if brand == .opera || brand == .vivaldi {
                #expect(matches(unversioned.brandVersion, brand), "\(brand) \(unversioned.brandVersion)")
            } else {
                #expect(unversioned.brandVersion.isEmpty, "\(brand) \(unversioned.brandVersion)")
            }
            #expect(throws: Never.self) { try BrowserProfile(name: "R", port: 9301, fingerprint: unversioned).validated() }

            var everything = FingerprintSettings(seed: 23)
            everything.randomize(Set(FingerprintField.allCases), excluding: [])
            #expect(matches(everything.brandVersion, everything.brand))
            var expected: [String] = switch everything.platform {
            case .linux: ["linux-webgl"]
            case .windows where !everything.adjustments.contains(.gpu): ["webgl-real-gpu"]
            default: []
            }
            if let platform = everything.platform, platform != .macOS,
               everything.fontProfile != nil, !everything.adjustments.contains(.font) {
                expected.append("font-spoof-missing")
            }
            #expect(issueIDs(everything) == expected, "\(everything)")
        }
        #expect(seen == Set(BrowserBrand.allCases))
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

    @Test("CPU counts follow the platform")
    func cpuCountsFollowPlatform() {
        let cases: [(BrowserPlatform?, Set<Int>)] = [
            (.macOS, [8, 10, 12]),
            (.windows, [4, 6, 8, 12, 16]),
            (.linux, [2, 4, 8]),
            (nil, [4, 8, 12, 16]),
        ]
        for (platform, allowed) in cases {
            for _ in 0..<100 {
                var fingerprint = FingerprintSettings(seed: 102)
                fingerprint.platform = platform
                fingerprint.randomize([.cpuCount], excluding: [])
                #expect(allowed.contains(fingerprint.cpuCount ?? 0),
                        "\(String(describing: platform)) \(String(describing: fingerprint.cpuCount))")
            }
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

    @Test("Changing platform clears values that cannot follow it")
    func platformChangeClearsStaleValues() {
        for _ in 0..<50 {
            var fingerprint = FingerprintSettings(seed: 105)
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
            #expect(fingerprint.deviceMemory == nil)
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
        // Only the known engine limitations may remain: Linux WebGL and non-macOS font spoofing.
        let allowed: Set<String> = ["linux-webgl", "font-spoof-missing"]
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

    @Test("Engine-default platform clears platform-specific claims")
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

        fingerprint.platform = nil
        fingerprint.adaptToPlatform()
        #expect(fingerprint.platformVersion.isEmpty)
        #expect(fingerprint.fontProfile == nil)
        #expect(fingerprint.screenWidth == nil)
        #expect(fingerprint.screenHeight == nil)
        #expect(fingerprint.colorDepth == nil)
        #expect(fingerprint.deviceScaleFactor == nil)
        #expect(fingerprint.deviceMemory == nil)
    }

    @Test("A new macOS version updates the font profile")
    func macOSVersionUpdatesFontProfile() {
        for _ in 0..<50 {
            var fingerprint = FingerprintSettings(seed: 106)
            fingerprint.platform = .macOS
            fingerprint.fontProfile = .macos26
            fingerprint.randomize([.platformVersion], excluding: [])
            #expect(fingerprint.fontProfile == (fingerprint.platformVersion.hasPrefix("15") ? .macos15 : .macos26))
        }
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
        let issues = BrowserProfile(name: "E", port: 9301, fingerprint: fingerprint)
            .consistencyIssues(engineVersion: Self.engine, exit: nil)
        #expect(issues == [ConsistencyIssue(id: "brand-version-ahead", message: "Edge 版本 150.0.3967.54 高于内核版本 148")])
        fingerprint.brandVersion = ""
        #expect(issueIDs(fingerprint).isEmpty)

        fingerprint.brand = .opera
        fingerprint.brandVersion = "120.0"
        #expect(issueIDs(fingerprint).isEmpty)
        fingerprint.brand = .vivaldi
        fingerprint.brandVersion = "7.5"
        #expect(issueIDs(fingerprint).isEmpty)
    }

    @Test("Platform versions must fit the platform")
    func platformVersionAgainstPlatform() {
        let cases: [(BrowserPlatform, String, Bool)] = [
            (.macOS, "10.15.7", true), (.macOS, "26.2.0", true), (.macOS, "9.0", false), (.macOS, "27.0.0", false),
            (.windows, "0.1.0", true), (.windows, "19.0.0", true), (.windows, "20.0.0", true), (.windows, "26.2.0", false),
            (.linux, "2.6.32", true), (.linux, "6.8.0", true), (.linux, "7.0", true), (.linux, "1.0", false), (.linux, "8.0", false),
        ]
        for (platform, version, fits) in cases {
            var fingerprint = FingerprintSettings(seed: 51)
            fingerprint.platform = platform
            fingerprint.platformVersion = version
            fingerprint.adjustments = [.gpu]
            let expected = (fits ? [] : ["platform-version"]) + (platform == .linux ? ["linux-webgl"] : [])
            #expect(issueIDs(fingerprint) == expected, "\(platform) \(version)")
        }
        var windows = FingerprintSettings(seed: 52)
        windows.platform = .windows
        windows.platformVersion = "26.2.0"
        windows.adjustments = [.gpu]
        #expect(BrowserProfile(name: "W", port: 9301, fingerprint: windows).consistencyIssues(engineVersion: nil, exit: nil)
            .map(\.message) == ["平台版本 26.2.0 与 Windows 不匹配（Windows 主版本应为 0–20）"])
        windows.platformVersion = ""
        #expect(issueIDs(windows).isEmpty)
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
            #expect(issueIDs(fingerprint) == expected, "\(String(describing: platform)) gpu=\(gpu)")
        }
        var windows = FingerprintSettings(seed: 62)
        windows.platform = .windows
        windows.adjustments = []
        #expect(BrowserProfile(name: "W", port: 9301, fingerprint: windows).consistencyIssues(engineVersion: nil, exit: nil)
            .map(\.message) == ["WebGL 改写已关闭，网页会读到本机真实显卡，与 Windows 身份不符"])
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
