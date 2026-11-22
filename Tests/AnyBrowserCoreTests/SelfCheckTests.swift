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
            screen: .init(width: 2560, height: 1440, availWidth: 2560, availHeight: 1410, colorDepth: 24, devicePixelRatio: 2),
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

    @Test("The probe script embeds the Profile language as JSON and parses date zone names")
    func probeScript() {
        #expect(SelfCheck.probeScript(language: "de-DE").contains("const [profileLanguage] = [\"de-DE\"];"))
        #expect(SelfCheck.probeScript(language: "x'];alert(1)//").contains("[\"x'];alert(1)\\/\\/\"]"))
        #expect(SelfCheck.zoneName("Thu Jan 15 2026 12:00:00 GMT-0500 (Eastern Standard Time)") == "Eastern Standard Time")
        #expect(SelfCheck.zoneName("Invalid Date") == nil)
    }
}
