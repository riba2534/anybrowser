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

    @Test("Identity presets set a whole identity and keep the seed, language, time zone and adjustments")
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
            for _ in 0..<20 {
                var fingerprint = FingerprintSettings(seed: 4242)
                fingerprint.platform = .macOS
                fingerprint.platformVersion = "26.4.1"
                fingerprint.brand = .vivaldi
                fingerprint.brandVersion = "7.6"
                fingerprint.cpuCount = 32
                fingerprint.language = "ja-JP"
                fingerprint.timeZone = "Asia/Tokyo"
                fingerprint.adjustments = [.font, .gpu, .clientRects]
                preset.apply(to: &fingerprint)

                #expect(fingerprint.platform == item.platform, "\(item.id)")
                #expect(fingerprint.platformVersion == item.version, "\(item.id)")
                #expect(fingerprint.brand == item.brand, "\(item.id)")
                #expect(fingerprint.brandVersion == item.brandVersion, "\(item.id)")
                #expect(item.cpus.contains(fingerprint.cpuCount ?? 0), "\(item.id)")
                #expect(fingerprint.seed == 4242 && fingerprint.language == "ja-JP" && fingerprint.timeZone == "Asia/Tokyo")
                #expect(fingerprint.adjustments == (item.platform == .linux ? [.font, .clientRects] : [.font, .gpu, .clientRects]),
                        "\(item.id)")
                let profile = try BrowserProfile(name: item.title, port: 9301, fingerprint: fingerprint).validated()
                #expect(profile.consistencyIssues(engineVersion: Self.engine, exit: nil).isEmpty, "\(item.id)")
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
            #expect(issueIDs(everything).isEmpty, "\(everything)")
        }
        #expect(seen == Set(BrowserBrand.allCases))
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
            fingerprint.adjustments = []
            #expect(issueIDs(fingerprint) == (fits ? [] : ["platform-version"]), "\(platform) \(version)")
        }
        var windows = FingerprintSettings(seed: 52)
        windows.platform = .windows
        windows.platformVersion = "26.2.0"
        #expect(BrowserProfile(name: "W", port: 9301, fingerprint: windows).consistencyIssues(engineVersion: nil, exit: nil)
            .map(\.message) == ["平台版本 26.2.0 与 Windows 不匹配（Windows 主版本应为 0–20）"])
        windows.platformVersion = ""
        #expect(issueIDs(windows).isEmpty)
    }

    @Test("Linux with WebGL spoofing on is flagged")
    func linuxWithWebGL() {
        var fingerprint = FingerprintSettings(seed: 61)
        fingerprint.adjustments = [.gpu]
        #expect(issueIDs(fingerprint).isEmpty)
        fingerprint.platform = .windows
        #expect(issueIDs(fingerprint).isEmpty)
        fingerprint.platform = .linux
        #expect(issueIDs(fingerprint) == ["linux-webgl"])
        fingerprint.adjustments = [.canvas]
        #expect(issueIDs(fingerprint).isEmpty)
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
