@testable import AnyBrowserCore
import Foundation
import Testing

struct SelfCheckTests {
    private static let hardware = EngineHardwareTable.bundled

    /// A German macOS identity on an Apple M2 with 16 GB (seed 4243).
    private func profile() throws -> BrowserProfile {
        var fingerprint = FingerprintSettings(seed: 4243)
        fingerprint.platform = .macOS
        fingerprint.platformVersion = "26.4.1"
        fingerprint.brand = .chrome
        fingerprint.cpuCount = 8
        fingerprint.language = "de-DE"
        fingerprint.timeZone = "Europe/Berlin"
        fingerprint.adjustments = [.canvas, .clientRects, .gpu]
        return try BrowserProfile(name: "S", port: 9301, fingerprint: fingerprint, proxy: "").validated()
    }

    /// What the engine reports for `profile()` when everything works.
    private func observation() -> SelfCheckObservation {
        let gpu = Self.hardware.macOS[1]
        let realm = SelfCheckObservation.Realm(
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36",
            platform: "MacIntel", hardwareConcurrency: 8, deviceMemory: 16, language: "de-DE", languages: ["de-DE", "de"],
            timeZone: "Europe/Berlin", locale: "de",
            dateString: "Thu Jan 15 2026 12:00:00 GMT+0100 (Mitteleuropäische Normalzeit)",
            measureText: 337.4765625, webGLVendor: gpu.vendor, webGLRenderer: gpu.renderer)
        return SelfCheckObservation(
            main: realm, worker: realm,
            frame: .init(locale: "de", dateString: realm.dateString, measureText: 337.4765625, markers: []),
            clientHints: .init(brands: [.init(brand: "Chromium", version: "148"), .init(brand: "Google Chrome", version: "148"),
                                        .init(brand: "Not/A)Brand", version: "99")],
                               fullVersionList: [.init(brand: "Chromium", version: "148.0.7778.97"),
                                                 .init(brand: "Google Chrome", version: "148.0.7778.97")],
                               platform: "macOS", platformVersion: "26.4.1", architecture: "arm", bitness: "64", mobile: false),
            screen: .init(width: 2560, height: 1440, availWidth: 2560, availHeight: 1410, colorDepth: 24, devicePixelRatio: 2,
                          availTop: 0, availLeft: 0),
            media: .init(maxWidth: .init(js: true, css: true), minWidth: .init(js: false, css: false),
                         minHeight: .init(js: true, css: true), minResolution: .init(js: true, css: true)),
            window: .init(outerWidth: 2048, outerHeight: 1210, innerWidth: 2048, innerHeight: 1122),
            canvasMeasureText: 337.4765625, canvasStable: true, markers: [],
            expectedZoneName: "Mitteleuropäische Normalzeit")
    }

    private func failures(_ observation: SelfCheckObservation, profile: BrowserProfile? = nil,
                          exit: ProxyExit? = nil) throws -> [String] {
        try SelfCheck.report(for: profile ?? self.profile(), exit: exit, observation: observation)
            .items.filter { $0.status == .fail }.map(\.id)
    }

    @Test("A browser that reads back its configuration passes every item")
    func matchingObservationPasses() throws {
        let report = SelfCheck.report(for: try profile(), exit: nil, observation: observation())
        #expect(report.passed, "\(report.items.filter { $0.status == .fail })")
        #expect(report.item("brand-version")?.status == .info)
        #expect(report.item("brand-version")?.observed == "148.0.7778.97")
        #expect(report.item("screen")?.status == .info)
        #expect(report.item("hardware")?.status == .pass)
        #expect(report.item("date-string")?.observed == "Mitteleuropäische Normalzeit · Worker Mitteleuropäische Normalzeit · iframe Mitteleuropäische Normalzeit")
    }

    @Test("A Profile language that reads as this Mac's locale is reported as undecidable, not as a pass")
    func hostLocaleIsUndecidable() throws {
        var chinese = try profile()
        chinese.fingerprint.language = "zh-SG"
        var seen = observation()
        seen.main.locale = "zh-CN"
        seen.worker?.locale = "zh-CN"
        seen.frame?.locale = "zh-CN"
        let onChineseMac = try #require(SelfCheck.report(for: chinese, exit: nil, observation: seen,
                                                         hostLanguages: ["zh-Hans-CN"]).item("locale"))
        #expect(onChineseMac.status == .info)
        #expect(onChineseMac.note?.contains("无法据此判断") == true)
        let onEnglishMac = try #require(SelfCheck.report(for: chinese, exit: nil, observation: seen,
                                                         hostLanguages: ["en-US"]).item("locale"))
        #expect(onEnglishMac.status == .pass && onEnglishMac.note == nil)
        // A German Profile falling back to this Chinese Mac still fails.
        let german = try #require(SelfCheck.report(for: try profile(), exit: nil, observation: seen,
                                                   hostLanguages: ["zh-Hans-CN"]).item("locale"))
        #expect(german.status == .fail)
    }

    @Test("Each kind of leak fails its own item")
    func leaksFail() throws {
        var marked = observation()
        marked.markers = ["__ANYBROWSER_INTL__"]
        #expect(try failures(marked) == ["markers"])

        var hostLanguage = observation()
        hostLanguage.worker?.locale = "zh-CN"
        hostLanguage.worker?.dateString = "Thu Jan 15 2026 12:00:00 GMT+0100 (中欧标准时间)"
        #expect(try failures(hostLanguage) == ["locale", "date-string"])

        // A browser that restarted itself lost -AppleLanguages and reads this Mac's language everywhere.
        var restarted = observation()
        restarted.main.locale = "zh-CN"
        restarted.worker?.locale = "zh-CN"
        restarted.frame?.locale = "zh-CN"
        let locale = try #require(SelfCheck.report(for: profile(), exit: nil, observation: restarted).item("locale"))
        #expect(locale.status == .fail)
        #expect(locale.note == "语言与 Profile 不一致：可能是浏览器自行重启过，请从 AnyBrowser 重启此 Profile")
        #expect(SelfCheck.report(for: try profile(), exit: nil, observation: hostLanguage).item("locale")?.note == nil)
        #expect(SelfCheck.report(for: try profile(), exit: nil, observation: observation()).items.allSatisfy { $0.note == nil })

        var hostDate = observation()
        hostDate.main.dateString = "Thu Jan 15 2026 12:00:00 GMT+0100 (中欧标准时间)"
        hostDate.worker?.dateString = hostDate.main.dateString
        hostDate.frame?.dateString = hostDate.main.dateString
        #expect(try failures(hostDate) == ["date-string"])

        var brokenText = observation()
        brokenText.main.measureText = 0.0015734002554705154
        #expect(try failures(brokenText) == ["measure-text"])

        var otherGPU = observation()
        otherGPU.main.webGLRenderer = Self.hardware.macOS[0].renderer
        otherGPU.main.hardwareConcurrency = 12
        otherGPU.worker?.hardwareConcurrency = 12
        #expect(try failures(otherGPU) == ["hardware-concurrency", "webgl", "hardware"])

        var unstable = observation()
        unstable.canvasStable = false
        #expect(try failures(unstable) == ["canvas-stable"])
    }

    @Test("Edge must send the reduced UA token, and the exit is compared when known")
    func edgeAndExit() throws {
        var edge = try profile()
        edge.fingerprint.brand = .edge
        var seen = observation()
        seen.clientHints?.brands.append(.init(brand: "Microsoft Edge", version: "148"))
        seen.clientHints?.fullVersionList.append(.init(brand: "Microsoft Edge", version: "148.0.3967.54"))
        seen.main.userAgent += " Edg/148.0.0.0"
        #expect(try failures(seen, profile: edge).isEmpty)
        seen.main.userAgent = seen.main.userAgent.replacingOccurrences(of: "Edg/148.0.0.0", with: "Edg/148.0.3967.54")
        #expect(try failures(seen, profile: edge) == ["edge-user-agent"])

        let tokyo = ProxyExit(ip: "203.0.113.7", countryCode: "JP", timeZone: "Asia/Tokyo", languages: ["ja-JP"])
        #expect(try failures(observation(), exit: tokyo) == ["exit-time-zone", "exit-language"])
        let berlin = ProxyExit(ip: "203.0.113.8", countryCode: "DE", timeZone: "Europe/Berlin", languages: ["de-DE"])
        #expect(try failures(observation(), exit: berlin).isEmpty)
    }

    /// `observation()` as the engine reads a Profile in `language`, whose UI localization is `locale`.
    private func observation(language: String, locale: String, timeZone: String, zoneName: String) -> SelfCheckObservation {
        var seen = observation()
        let base = String(language.prefix { $0 != "-" })
        seen.main.language = language
        seen.main.languages = [language, base]
        seen.main.locale = locale
        seen.main.timeZone = timeZone
        seen.main.dateString = "Thu Jan 15 2026 12:00:00 GMT+0000 (\(zoneName))"
        seen.worker = seen.main
        seen.frame?.locale = locale
        seen.frame?.dateString = seen.main.dateString
        seen.expectedZoneName = zoneName
        return seen
    }

    @Test("Chromium's localization of a regional language and ICU's name of a renamed zone pass; this Mac's language fails")
    func regionalLanguagesAndRenamedZones() throws {
        // What an identity generated for an Indian exit reads: Chromium has no en-IN localization,
        // and ICU calls Asia/Kolkata by its old name.
        var india = try profile()
        india.fingerprint.apply(try #require(IdentitySampler.LocaleHint(language: "en-IN", timeZone: "Asia/Kolkata")))
        let exit = ProxyExit(ip: "203.0.113.9", countryCode: "IN", timeZone: "Asia/Kolkata", languages: ["en-IN", "hi-IN"])
        var seen = observation(language: "en-IN", locale: "en-GB", timeZone: "Asia/Calcutta", zoneName: "India Standard Time")
        seen.timeZoneNames = ["Asia/Kolkata": "Asia/Calcutta"]
        let report = SelfCheck.report(for: india, exit: exit, observation: seen)
        #expect(report.passed, "\(report.items.filter { $0.status == .fail })")
        #expect(report.item("locale")?.expected == "en-IN（Chromium 读作 en-GB）")
        #expect(report.item("time-zone")?.expected == "Asia/Kolkata（Chromium 读作 Asia/Calcutta）")
        #expect(report.item("exit-time-zone")?.status == .pass)

        // Another zone, or no names from the page, is still a different zone.
        var elsewhere = seen
        elsewhere.main.timeZone = "Asia/Shanghai"
        elsewhere.worker?.timeZone = "Asia/Shanghai"
        #expect(try failures(elsewhere, profile: india, exit: exit) == ["time-zone", "exit-time-zone"])
        var unnamed = seen
        unnamed.timeZoneNames = nil
        #expect(try failures(unnamed, profile: india, exit: exit) == ["time-zone", "exit-time-zone"])

        // The locale Chromium picks for each language passes, this Mac's language fails: within the
        // same base language too, so a zh-HK Profile that came back in zh-CN is caught.
        let cases: [(language: String, locale: String, host: String)] = [
            ("en-AU", "en-GB", "en-US"), ("en-NZ", "en-GB", "zh-CN"), ("es-AR", "es-MX", "es-ES"), ("es-ES", "es-ES", "es-MX"),
            ("zh-HK", "zh-HK", "zh-CN"), ("zh-MO", "zh-HK", "zh-CN"), ("zh-SG", "zh-CN", "zh-TW"), ("pt-BR", "pt-BR", "pt-PT"),
            ("pt-AO", "pt-PT", "pt-BR"), ("de-AT", "de", "zh-CN"), ("fr-CA", "fr-CA", "fr"), ("ja-JP", "ja", "en-US"),
        ]
        for item in cases {
            var regional = try profile()
            regional.fingerprint.language = item.language
            let read = observation(language: item.language, locale: item.locale, timeZone: "Europe/Berlin",
                                   zoneName: "Mitteleuropäische Normalzeit")
            #expect(try failures(read, profile: regional).isEmpty, "\(item.language) read as \(item.locale)")
            let restarted = observation(language: item.language, locale: item.host, timeZone: "Europe/Berlin",
                                        zoneName: "Mitteleuropäische Normalzeit")
            #expect(try failures(restarted, profile: regional) == ["locale"], "\(item.language) read as \(item.host)")
        }
    }

    @Test("matchMedia and a style sheet must give the same answer to the same media question")
    func mediaQueriesMustAgree() throws {
        #expect(try failures(observation()).isEmpty)

        // The injection layer patched matchMedia but the style sheet still sees the real viewport.
        var bypassed = observation()
        bypassed.media?.minWidth.css = true
        bypassed.media?.maxWidth.js = false
        #expect(try failures(bypassed) == ["media-css-js"])
        let item = try #require(SelfCheck.report(for: profile(), exit: nil, observation: bypassed).item("media-css-js"))
        #expect(item.status == .fail)
        #expect(item.observed.contains("max-width JS 否 · CSS 是"))
        #expect(item.observed.contains("min-width JS 否 · CSS 是"))
        #expect(item.note != nil)

        var absent = observation()
        absent.media = nil
        let info = try #require(SelfCheck.report(for: profile(), exit: nil, observation: absent).item("media-css-js"))
        #expect(info.status == .info)
        #expect(try failures(absent).isEmpty)
    }

    @Test("The usable screen area must stay inside the screen")
    func screenAvailStaysInside() throws {
        #expect(try failures(observation()).isEmpty)

        var spilledDown = observation()
        spilledDown.screen.availTop = 60
        #expect(try failures(spilledDown) == ["screen-avail-consistency"])
        var spilledRight = observation()
        spilledRight.screen.availLeft = 20
        #expect(try failures(spilledRight) == ["screen-avail-consistency"])

        var noScreen = observation()
        noScreen.screen.availTop = nil
        noScreen.screen.availLeft = nil
        let info = try #require(SelfCheck.report(for: profile(), exit: nil, observation: noScreen)
            .item("screen-avail-consistency"))
        #expect(info.status == .info)
        #expect(info.observed.contains("没有屏幕"))
        #expect(try failures(noScreen).isEmpty)
    }

    @Test("The probe script embeds the Profile language and time zones as JSON and parses date zone names")
    func probeScript() {
        #expect(SelfCheck.probeScript(language: "de-DE").contains("const [profileLanguage] = [\"de-DE\"];"))
        #expect(SelfCheck.probeScript(language: "x'];alert(1)//").contains("[\"x'];alert(1)\\/\\/\"]"))
        #expect(SelfCheck.probeScript(language: "en-IN", timeZones: ["Asia/Kolkata", ""])
            .contains("const timeZones = [\"Asia\\/Kolkata\"];"))
        #expect(SelfCheck.probeScript(language: "en-IN").contains("const timeZones = [];"))
        #expect(SelfCheck.probeScript(language: "de-DE").contains("--anybrowser-media"))
        #expect(SelfCheck.probeScript(language: "de-DE").contains("min-resolution: ${devicePixelRatio || 1}dppx"))
        #expect(SelfCheck.zoneName("Thu Jan 15 2026 12:00:00 GMT-0500 (Eastern Standard Time)") == "Eastern Standard Time")
        #expect(SelfCheck.zoneName("Invalid Date") == nil)
    }
}
