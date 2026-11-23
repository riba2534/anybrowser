@testable import AnyBrowserCore
import Foundation
import Testing

/// Windows are derived from the Profile's fake screen and clamped into it, so that the
/// `window.outer*` a page reads never outgrows `screen.*`.
struct WindowGeometryTests {
    private func macOS(seed: Int = 4243) -> FingerprintSettings {
        var fingerprint = FingerprintSettings(seed: seed)
        fingerprint.platform = .macOS
        fingerprint.screenWidth = 1512
        fingerprint.screenHeight = 982
        fingerprint.availWidth = 1512
        fingerprint.availHeight = 945
        return fingerprint
    }

    @Test("Without a window one is derived inside the Profile's screen", arguments: 1...32)
    func derivesWindow(seed: Int) throws {
        let fingerprint = macOS(seed: seed)
        let window = try #require(LaunchOptions().effectiveWindow(for: fingerprint))
        // The same seed always gives the same window.
        #expect(window == LaunchOptions().effectiveWindow(for: fingerprint))
        let screen = try #require(fingerprint.profileScreen)
        #expect(window.width >= screen.width * 72 / 100)
        #expect(window.width <= screen.width * 88 / 100)
        #expect(window.height >= screen.height * 68 / 100)
        #expect(window.height <= screen.height * 82 / 100)
        // At least 20 px stay free on the sides the size is clamped against.
        #expect(window.width <= screen.availWidth - 20)
        #expect(window.height <= screen.availHeight - 20)
        let x = try #require(window.x)
        let y = try #require(window.y)
        #expect(x >= 0 && x <= screen.width - window.width)
        #expect(y >= screen.topInset && y <= screen.height - window.height)
    }

    @Test("The derived window reaches the launch switches, size before position")
    func derivedWindowIsPassed() throws {
        let arguments = LaunchOptions().arguments(for: macOS())
        let size = arguments.firstIndex { $0.hasPrefix("--window-size=") }
        let position = arguments.firstIndex { $0.hasPrefix("--window-position=") }
        let sizeIndex = try #require(size)
        let positionIndex = try #require(position)
        #expect(positionIndex == sizeIndex + 1)
        #expect(arguments[sizeIndex].dropFirst("--window-size=".count)
            .split(separator: ",").count == 2)
        #expect(arguments[positionIndex].dropFirst("--window-position=".count)
            .split(separator: ",").count == 2)
    }

    @Test("A configured window is clamped into the screen")
    func configuredWindowIsClamped() throws {
        var windows = macOS()
        windows.platform = .windows
        windows.screenWidth = 1366
        windows.availWidth = 1366
        windows.screenHeight = 768
        windows.availHeight = 728
        let oversized = WindowLayout(width: 2000, height: 1200, x: 900, y: 700)
        let clamped = try #require(LaunchOptions(window: oversized).effectiveWindow(for: windows))
        #expect(clamped == WindowLayout(width: 1366, height: 728, x: 0, y: 40))
        // A window that fits keeps its size and place.
        let fitting = WindowLayout(width: 800, height: 500, x: 120, y: 60)
        #expect(LaunchOptions(window: fitting).effectiveWindow(for: windows) == fitting)
        // Without a position it is placed inside.
        let placed = try #require(LaunchOptions(window: WindowLayout(width: 800, height: 500))
            .effectiveWindow(for: windows))
        #expect(placed.x.map { (0...(1366 - 800)).contains($0) } == true)
        #expect(placed.y.map { (0...(768 - 500)).contains($0) } == true)
        // On macOS a configured y is kept below the menu bar.
        let mac = try #require(LaunchOptions(window: WindowLayout(width: 800, height: 500, x: 10, y: 0))
            .effectiveWindow(for: macOS()))
        #expect(mac.y == 37)
        #expect(mac.x == 10)
    }

    @Test("Without a screen the configured window passes unchanged, and none is invented")
    func withoutScreen() throws {
        let bare = FingerprintSettings(seed: 5)
        #expect(LaunchOptions().effectiveWindow(for: bare) == nil)
        let window = WindowLayout(width: 1280, height: 800, x: -20, y: 40)
        #expect(LaunchOptions(window: window).effectiveWindow(for: bare) == window)
        #expect(LaunchOptions(window: window).arguments(for: bare) == ["--window-size=1280,800", "--window-position=-20,40"])
        #expect(LaunchOptions().arguments(for: bare).isEmpty)
    }

    @Test("Grid cells stay inside the screen of the Profile they belong to")
    func frameClampingFollowsEachScreen() {
        let mac = ProfileScreen(platform: .macOS, width: 1512, height: 982, availWidth: 1512, availHeight: 945)
        let wins = ProfileScreen(platform: .windows, width: 1366, height: 768, availWidth: 1366, availHeight: 728)
        let fallback = WindowArrangement.Frame(left: 0, top: 25, width: 900, height: 700)
        let frames = WindowArrangement.frames(count: 3, screens: [wins, mac, nil], fallback: fallback)
        #expect(frames[0].left >= 0 && frames[0].left + frames[0].width <= wins.width)
        #expect(frames[0].top >= wins.topInset && frames[0].top + frames[0].height <= wins.height)
        #expect(frames[1].left >= 0 && frames[1].left + frames[1].width <= mac.width)
        #expect(frames[1].top >= mac.topInset && frames[1].top + frames[1].height <= mac.height)
        #expect(frames[2].left >= fallback.left && frames[2].left + frames[2].width <= fallback.left + fallback.width)
    }
}

@MainActor
struct HeadlessWindowLaunchTests {
    @Test("A headless launch still passes the window switches")
    func headlessCarriesWindow() async throws {
        let fixture = try FakeEngineFixture("window-headless")
        var profile = fixture.profile(port: freeTestPort())
        profile.fingerprint.platform = .windows
        profile.fingerprint.screenWidth = 1920
        profile.fingerprint.screenHeight = 1080
        profile.fingerprint.availWidth = 1920
        profile.fingerprint.availHeight = 1040
        try fixture.configure(profile, ["targets": #"[{"targetId":"ntp","type":"page","url":"chrome://newtab/"}]"#])
        try await fixture.run([profile]) {
            try await fixture.runtime.start(profile, overrides: LaunchOverrides(headless: true))
            guard case let .running(pid, _, true) = fixture.runtime.status(for: profile.id) else {
                Issue.record("Not running: \(fixture.runtime.status(for: profile.id))")
                return
            }
            let arguments = try #require(ProcessInspection.arguments(pid))
            #expect(arguments.contains("--headless=new"))
            let size = try #require(arguments.first { $0.hasPrefix("--window-size=") })
            let position = try #require(arguments.first { $0.hasPrefix("--window-position=") })
            let values = size.dropFirst("--window-size=".count).split(separator: ",").compactMap { Int($0) }
            #expect(values.count == 2)
            let width = try #require(values.first)
            let height = try #require(values.last)
            #expect(width <= 1920 - 20 && height <= 1040 - 20)
            let place = position.dropFirst("--window-position=".count).split(separator: ",").compactMap { Int($0) }
            #expect(place.count == 2)
            let x = try #require(place.first)
            let y = try #require(place.last)
            #expect(x >= 0 && x <= 1920 - width)
            #expect(y >= 0 && y <= 1080 - height)
        }
    }
}

/// The window half of the self-check: `outer` must stay within `screen`, `inner` within `avail`,
/// and the chrome between them must fit the platform.
struct SelfCheckWindowTests {
    private func profile(_ platform: BrowserPlatform = .macOS) throws -> BrowserProfile {
        var fingerprint = FingerprintSettings(seed: 4243)
        fingerprint.platform = platform
        fingerprint.brand = .chrome
        fingerprint.cpuCount = 8
        fingerprint.language = "de-DE"
        fingerprint.timeZone = "Europe/Berlin"
        fingerprint.adjustments = [.canvas, .clientRects]
        fingerprint.screenWidth = 2560
        fingerprint.screenHeight = 1440
        fingerprint.availWidth = 2400
        fingerprint.availHeight = 1410
        fingerprint.colorDepth = 24
        fingerprint.deviceScaleFactor = 2
        return try BrowserProfile(name: "W", port: 9303, fingerprint: fingerprint, proxy: "").validated()
    }

    private func observation(_ platform: BrowserPlatform = .macOS,
                             outerWidth: Int = 2048, outerHeight: Int = 1210,
                             innerWidth: Int = 2048, innerHeight: Int = 1122) -> SelfCheckObservation {
        let ua: String
        let token: String
        let hint: String
        switch platform {
        case .macOS:
            ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
            token = "MacIntel"
            hint = "macOS"
        case .windows:
            ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
            token = "Win32"
            hint = "Windows"
        case .linux:
            ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
            token = "Linux x86_64"
            hint = "Linux"
        }
        let memory = Double(EngineHardwareTable.bundled.deviceMemory(seed: 4243))
        let realm = SelfCheckObservation.Realm(
            userAgent: ua, platform: token, hardwareConcurrency: 8, deviceMemory: memory,
            language: "de-DE", languages: ["de-DE", "de"], timeZone: "Europe/Berlin", locale: "de",
            dateString: "Thu Jan 15 2026 12:00:00 GMT+0100 (Mitteleuropäische Normalzeit)",
            measureText: 337.4765625, webGLVendor: "Google Inc.", webGLRenderer: "ANGLE")
        return SelfCheckObservation(
            main: realm, worker: realm,
            frame: .init(locale: "de", dateString: realm.dateString, measureText: 337.4765625, markers: []),
            clientHints: .init(brands: [.init(brand: "Chromium", version: "148"), .init(brand: "Google Chrome", version: "148")],
                               fullVersionList: [.init(brand: "Google Chrome", version: "148.0.7778.97")],
                               platform: hint, platformVersion: "", architecture: "arm", bitness: "64", mobile: false),
            screen: .init(width: 2560, height: 1440, availWidth: 2400, availHeight: 1410,
                          colorDepth: 24, devicePixelRatio: 2),
            window: .init(outerWidth: outerWidth, outerHeight: outerHeight,
                          innerWidth: innerWidth, innerHeight: innerHeight),
            canvasMeasureText: 337.4765625, canvasStable: true, markers: [],
            expectedZoneName: "Mitteleuropäische Normalzeit")
    }

    private func report(_ seen: SelfCheckObservation, platform: BrowserPlatform = .macOS) throws -> SelfCheckReport {
        SelfCheck.report(for: try profile(platform), exit: nil, observation: seen)
    }

    @Test("A window inside the screen with the platform's chrome passes, on every platform")
    func plausibleWindowsPass() throws {
        let cases: [(platform: BrowserPlatform, outer: (Int, Int), inner: (Int, Int))] = [
            (.macOS, (2048, 1210), (2048, 1122)),
            (.windows, (2064, 1250), (2048, 1210)),
            (.linux, (2048, 1242), (2048, 1210)),
        ]
        for item in cases {
            let report = try report(observation(item.platform, outerWidth: item.outer.0,
                                                outerHeight: item.outer.1,
                                                innerWidth: item.inner.0, innerHeight: item.inner.1),
                                    platform: item.platform)
            #expect(report.item("window-frame")?.status == .pass, "\(item.platform)")
            #expect(report.passed, "\(item.platform): \(report.items.filter { $0.status == .fail })")
        }
    }

    @Test("A headless page has no frame to compare, and its viewport still fits")
    func headlessHasNoFrame() throws {
        let seen = observation(outerWidth: 0, outerHeight: 0, innerWidth: 1244, innerHeight: 683)
        let report = try report(seen)
        #expect(report.item("window-frame")?.status == .info)
        #expect(report.item("window-frame")?.observed == "0 / 0（无窗口模式）")
        #expect(report.item("window-outer-width")?.status == .pass)
        #expect(report.item("window-outer-height")?.status == .pass)
        #expect(report.item("window-inner-width")?.status == .pass)
        #expect(report.item("window-inner-height")?.status == .pass)
        #expect(report.passed)
    }

    @Test("A window that outgrows the screen fails its own item")
    func outerTooBig() throws {
        let wide = try report(observation(outerWidth: 2600, innerWidth: 2600))
        #expect(wide.item("window-outer-width")?.status == .fail)
        #expect(wide.item("window-outer-width")?.observed == "2600")

        let tall = try report(observation(outerHeight: 1460, innerHeight: 1372))
        #expect(tall.item("window-outer-height")?.status == .fail)
        #expect(tall.item("window-outer-height")?.observed == "1460")
    }

    @Test("A viewport that outgrows the usable screen fails its own item")
    func innerTooBig() throws {
        let wide = try report(observation(outerWidth: 2500, innerWidth: 2450))
        #expect(wide.item("window-inner-width")?.status == .fail)
        #expect(wide.item("window-inner-width")?.observed == "2450")

        let tall = try report(observation(outerHeight: 1440, innerHeight: 1420))
        #expect(tall.item("window-inner-height")?.status == .fail)
        #expect(tall.item("window-inner-height")?.observed == "1420")
    }

    @Test("Chrome of another platform, or too much of it, fails the frame item")
    func implausibleChromeFails() throws {
        // A macOS identity with Windows chrome.
        let wrongPlatform = try report(observation(outerWidth: 2064, outerHeight: 1250,
                                                   innerWidth: 2048, innerHeight: 1210))
        #expect(wrongPlatform.item("window-frame")?.status == .fail)

        // A macOS window with a 110 px tall chrome instead of 88 px.
        let tall = try report(observation(outerHeight: 1210, innerHeight: 1100))
        #expect(tall.item("window-frame")?.status == .fail)
        #expect(tall.items.filter { $0.status == .fail }.map(\.id) == ["window-frame"])
        #expect(tall.item("window-frame")?.observed == "0 / 110")
    }

    @Test("A window taller than its screen is the failure a server sees first")
    func fullScreenWindowFails() throws {
        // A default window on a short screen: `outer` outgrows `screen`, the viewport still fits.
        var seen = observation(outerWidth: 1200, outerHeight: 1366, innerWidth: 1200, innerHeight: 1278)
        seen.screen.width = 1200
        seen.screen.height = 1360
        seen.screen.availWidth = 1200
        seen.screen.availHeight = 1300
        let report = try report(seen)
        #expect(report.item("window-outer-width")?.status == .pass)
        #expect(report.item("window-outer-height")?.status == .fail)
        #expect(report.item("window-inner-width")?.status == .pass)
        #expect(report.item("window-inner-height")?.status == .pass)
        #expect(report.item("window-frame")?.status == .pass)
    }

    @Test("Without window sizes the window items are left out")
    func missingWindowHasNoItems() throws {
        var seen = observation()
        seen.window = nil
        let report = try report(seen)
        #expect(report.item("window-outer-width") == nil)
        #expect(report.item("window-frame") == nil)
    }
}