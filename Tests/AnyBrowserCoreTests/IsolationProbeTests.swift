@testable import AnyBrowserCore
import Foundation
import Testing

/// What pages in separate Profiles on one Mac read from the real engine: no shared AnyBrowser
/// marker, the Profile's own language everywhere, and hardware that exists. These are the engine
/// upgrade gate for the shim, `-AppleLanguages` and `EngineHardwareTable`.
///
/// Debug ports 9340–9349 (plus `ANYBROWSER_TEST_PORT_OFFSET`). The probes use their own background tab.
@Suite(.serialized, .enabled(if: testAppPath != nil,
                             "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the isolation probes."))
struct IsolationProbeTests {
    private static let hardware = EngineHardwareTable.bundled

    private func profile(_ name: String, port: Int, seed: Int, platform: BrowserPlatform, brand: BrowserBrand = .chrome,
                         language: String = "en-US", timeZone: String = "America/New_York",
                         cpuCount: Int?? = .none) throws -> BrowserProfile {
        var fingerprint = FingerprintSettings(seed: seed)
        let preset = try #require(IdentityPreset.all.first { $0.platform == platform && $0.brand == brand })
        preset.apply(to: &fingerprint)
        if case let .some(count) = cpuCount { fingerprint.cpuCount = count }
        fingerprint.language = language
        fingerprint.timeZone = timeZone
        return try BrowserProfile(name: name, port: testPort(port), fingerprint: fingerprint, proxy: "").validated()
    }

    /// Starts the Profiles together, self-checks each one and stops them all.
    @MainActor
    private func probe(_ profiles: [BrowserProfile], label: String, exits: [ProxyExit] = [],
                       extra: String? = nil) async throws -> [(report: SelfCheckReport, extra: Any?)] {
        let storage = try scratchDirectory(label)
        defer { try? FileManager.default.removeItem(at: storage) }
        let runtime = BrowserRuntime(engine: try testEngine(), storage: storage)
        var results: [(report: SelfCheckReport, extra: Any?)] = []
        do {
            for profile in profiles { try await runtime.start(profile) }
            for (index, profile) in profiles.enumerated() {
                let endpoint = try #require(await runtime.devToolsEndpoint(for: profile.id))
                let exit = exits.indices.contains(index) ? exits[index] : nil
                let report = try await SelfCheck.run(endpoint: endpoint, profile: profile, exit: exit)
                var value: Any?
                if let extra { value = try await SelfCheck.evaluate(extra, endpoint: endpoint) }
                results.append((report, value))
            }
        } catch {
            for profile in profiles { try? await runtime.stop(profile.id) }
            throw error
        }
        for profile in profiles { try await runtime.stop(profile.id) }
        return results
    }

    private func expectPassed(_ report: SelfCheckReport, _ ids: [String], _ note: String) {
        for id in ids {
            let item = report.item(id)
            #expect(item?.status == .pass, "\(note) \(id): \(String(describing: item))")
        }
    }

    /// What lie detectors look at on `measureText` and the `TextMetrics` it returns.
    private static let lies = """
    (() => {
      const measure = CanvasRenderingContext2D.prototype.measureText;
      const context = document.createElement('canvas').getContext('2d');
      context.font = '18pt Arial';
      const metrics = context.measureText('Cwm fjordbank glyphs vext quiz');
      const width = Object.getOwnPropertyDescriptor(TextMetrics.prototype, 'width').get;
      let getterOnResult = null;
      try { getterOnResult = width.call(metrics); } catch (e) {}
      let stack = '';
      try { measure.call({}, 'x'); } catch (e) { stack = String(e.stack); }
      return {
        source: Function.prototype.toString.call(measure),
        own: Object.getOwnPropertyNames(measure).sort().join(','),
        prototype: 'prototype' in measure,
        metricsOwn: Object.getOwnPropertyNames(metrics).length,
        getterOnResult, width: metrics.width,
        widthGetter: width.name, widthGetterPrototype: 'prototype' in width,
        extensionFrameInMeasureText: stack.includes('chrome-extension://'),
      };
    })()
    """

    @Test("Pages, Workers and frames carry no AnyBrowser marker, and measureText reads true everywhere")
    @MainActor
    func noMarkersAndRealTextMetrics() async throws {
        let profiles = [
            try profile("Marker A", port: 9340, seed: 4244, platform: .macOS),
            try profile("Marker B", port: 9341, seed: 22223, platform: .macOS, language: "de-DE", timeZone: "Europe/Berlin"),
        ]
        for (report, extra) in try await probe(profiles, label: "isolation-markers", extra: Self.lies) {
            let seen = report.observation
            #expect(seen.markers.isEmpty, "\(seen.markers)")
            #expect(seen.frame?.markers.isEmpty == true, "\(String(describing: seen.frame))")
            // Workers are not scaled by the engine, so their width is the reference.
            let reference = try #require(seen.worker?.measureText)
            #expect(reference > 100)
            #expect(seen.main.measureText == reference)
            #expect(seen.canvasMeasureText == reference)
            #expect(seen.frame?.measureText == reference)
            expectPassed(report, ["markers", "measure-text", "canvas-stable"], "\(report.profileID)")

            let lies = try #require(extra as? [String: Any])
            #expect(lies["source"] as? String == "function measureText() { [native code] }")
            #expect(lies["own"] as? String == "length,name")
            #expect(lies["prototype"] as? Bool == false)
            #expect(lies["metricsOwn"] as? Int == 0)
            #expect(lies["getterOnResult"] as? Double == lies["width"] as? Double)
            #expect(lies["width"] as? Double == reference)
            #expect(lies["widthGetter"] as? String == "get width")
            #expect(lies["widthGetterPrototype"] as? Bool == false)
            #expect(lies["extensionFrameInMeasureText"] as? Bool == false)
        }
    }

    @Test("Date strings, Intl, Workers and blob frames follow the Profile language, not this Mac's")
    @MainActor
    func languageReachesEveryRealm() async throws {
        let cases: [(language: String, zone: String, zoneName: String, locales: Set<String>)] = [
            ("en-US", "America/New_York", "Eastern Standard Time", ["en-US"]),
            ("de-DE", "Europe/Berlin", "Mitteleuropäische Normalzeit", ["de", "de-DE"]),
        ]
        let profiles = try cases.enumerated().map { index, item in
            try profile("Language \(item.language)", port: 9340 + index, seed: index == 0 ? 1000 : 105,
                        platform: .macOS, language: item.language, timeZone: item.zone)
        }
        let results = try await probe(profiles, label: "isolation-language")
        for (item, result) in zip(cases, results) {
            let seen = result.report.observation
            #expect(SelfCheck.zoneName(seen.main.dateString) == item.zoneName, "\(seen.main.dateString)")
            #expect(item.locales.contains(seen.main.locale), "\(seen.main.locale)")
            #expect(seen.worker?.locale == seen.main.locale)
            #expect(seen.worker?.dateString == seen.main.dateString)
            #expect(seen.frame?.locale == seen.main.locale)
            #expect(seen.frame?.dateString == seen.main.dateString)
            #expect(seen.main.languages == [item.language, String(item.language.prefix(2))])
            #expect(seen.worker?.languages == seen.main.languages)
            expectPassed(result.report, ["languages", "locale", "date-string", "time-zone"], item.language)
        }
    }

    @Test("-AppleLanguages opens no tab of its own and sends nothing through the proxy")
    @MainActor
    func appleLanguagesStayOffTheNetwork() async throws {
        let stub = try await ProxyStub.start(credentials: nil) { _ in
            .init(status: 200, body: "<!doctype html><title>proxied</title>")
        }
        defer { stub.stop() }
        var proxied = try profile("Proxied", port: 9340, seed: 4244, platform: .macOS,
                                  language: "de-DE", timeZone: "Europe/Berlin")
        proxied.proxy = "http://127.0.0.1:\(stub.port)"
        let storage = try scratchDirectory("isolation-proxy")
        defer { try? FileManager.default.removeItem(at: storage) }
        let runtime = BrowserRuntime(engine: try testEngine(), storage: storage)
        try await runtime.start(proxied)
        do {
            // Long enough for a start-up tab to have asked the proxy for its page and favicon.
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let pages = try await DevToolsPage.waitForTargets(port: proxied.port) { targets in
                targets.contains { $0["type"] as? String == "page" }
            }.filter { $0["type"] as? String == "page" }.compactMap { $0["url"] as? String }
            #expect(pages.allSatisfy { !$0.contains("(") && !$0.localizedCaseInsensitiveContains("array") }, "\(pages)")
            let targets = stub.requests.map(\.target)
            #expect(!targets.contains { $0.contains("(") || $0.contains("%28") || $0.localizedCaseInsensitiveContains("de-de") },
                    "\(targets)")

            let endpoint = try #require(await runtime.devToolsEndpoint(for: proxied.id))
            let report = try await SelfCheck.run(endpoint: endpoint, profile: proxied, exit: nil)
            #expect(report.observation.main.locale == "de")
            expectPassed(report, ["locale", "date-string", "languages"], "proxied")
            try await runtime.stop(proxied.id)
        } catch {
            try? await runtime.stop(proxied.id)
            throw error
        }
    }

    @Test("The GPU, memory and CPU count the engine derives from seeds match EngineHardwareTable")
    @MainActor
    func hardwareMatchesTheTable() async throws {
        // Both macOS GPUs and all three memory sizes; Windows GPUs 2, 5, 11 and 12; one Profile
        // without a CPU count, for which the engine reports ((seed % 13) + 4) * 2.
        let profiles = [
            try profile("M4 32", port: 9342, seed: 4244, platform: .macOS),
            try profile("M2 16", port: 9343, seed: 4243, platform: .macOS),
            try profile("M2 8", port: 9344, seed: 105, platform: .macOS),
            try profile("M4 16", port: 9345, seed: 1000, platform: .macOS),
            try profile("RTX 4060", port: 9346, seed: 44445, platform: .windows),
            try profile("RTX 3060", port: 9347, seed: 33334, platform: .windows, cpuCount: .some(nil)),
            try profile("Radeon", port: 9348, seed: 4243, platform: .windows),
            try profile("UHD A78B", port: 9349, seed: 1000, platform: .windows),
        ]
        let results = try await probe(profiles, label: "isolation-hardware")
        for (profile, result) in zip(profiles, results) {
            let seen = result.report.observation
            let seed = profile.fingerprint.seed
            let gpu = try #require(Self.hardware.gpu(for: profile.fingerprint.platform, seed: seed))
            #expect(seen.main.webGLRenderer == gpu.renderer, "\(profile.name)")
            #expect(seen.main.webGLVendor == gpu.vendor, "\(profile.name)")
            #expect(seen.worker?.webGLRenderer == gpu.renderer, "\(profile.name)")
            #expect(seen.main.deviceMemory == Double(Self.hardware.deviceMemory(seed: seed)), "\(profile.name)")
            #expect(seen.worker?.deviceMemory == seen.main.deviceMemory)
            let cpus = profile.fingerprint.cpuCount ?? Self.hardware.defaultCPUCount(seed: seed)
            #expect(seen.main.hardwareConcurrency == cpus, "\(profile.name)")
            #expect(seen.worker?.hardwareConcurrency == cpus)
            #expect(gpu.cpuCounts.contains(seen.main.hardwareConcurrency), "\(profile.name)")
            #expect(gpu.deviceMemory.contains(Int(seen.main.deviceMemory ?? 0)), "\(profile.name)")
            // The measureText factor of every seed is divided out exactly.
            #expect(seen.main.measureText == seen.worker?.measureText, "\(profile.name)")
            expectPassed(result.report, ["webgl", "device-memory", "hardware-concurrency", "hardware", "measure-text"],
                         profile.name)
        }
    }

    @Test("Edge sends a reduced Edg/<major>.0.0.0 token and a released build in UA-CH")
    @MainActor
    func edgeUserAgentIsReduced() async throws {
        let edge = try profile("Edge", port: 9340, seed: 44445, platform: .windows, brand: .edge)
        #expect(edge.fingerprint.brandVersion.isEmpty)
        let report = try #require(try await probe([edge], label: "isolation-edge").first?.report)
        let seen = report.observation
        #expect(seen.main.userAgent.hasSuffix(" Edg/\(BundledVersions.engineMajor).0.0.0"), "\(seen.main.userAgent)")
        let full = seen.clientHints?.fullVersionList.first { $0.brand == "Microsoft Edge" }?.version
        #expect(["148.0.3967.54", "148.0.3967.96", "148.0.3967.83", "148.0.3967.70"].contains(full ?? ""),
                "\(String(describing: full))")
        expectPassed(report, ["edge-user-agent", "brand", "platform"], "Edge")
    }

    @Test("A generated identity passes its whole self-check, and the report round-trips as JSON")
    @MainActor
    func generatedIdentityPassesSelfCheck() async throws {
        var fingerprint = IdentitySampler.sample(seed: FingerprintSettings.newSeed(excluding: []))
        fingerprint.apply(try #require(IdentitySampler.LocaleHint(language: "ja-JP", timeZone: "Asia/Tokyo")))
        let generated = try BrowserProfile(name: "Generated", port: testPort(9349), fingerprint: fingerprint,
                                           proxy: "").validated()
        let report = try #require(try await probe([generated], label: "isolation-selfcheck").first?.report)
        #expect(report.passed, "\(report.items.filter { $0.status == .fail })")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SelfCheckReport.self, from: encoder.encode(report))
        #expect(decoded.items == report.items)
        #expect(decoded.observation == report.observation)
    }

    @Test("Identities generated for exits pass their whole self-check where Chromium maps the language and ICU renames the zone")
    @MainActor
    func exitIdentitiesPassSelfCheck() async throws {
        // The first language of each exit, as ProxyProbe fills it in, has no localization of its own
        // (en-IN reads as en-GB, es-AR as es-MX, zh-MO as zh-HK, de-AT as de), and ICU keeps the
        // old name of several zones (Asia/Calcutta, America/Buenos_Aires, Europe/Kiev, Asia/Saigon).
        let places = [
            ("IN", "Asia/Kolkata"), ("AU", "Australia/Sydney"), ("NZ", "Pacific/Auckland"),
            ("AR", "America/Argentina/Buenos_Aires"), ("MO", "Asia/Macau"), ("AT", "Europe/Vienna"),
            ("UA", "Europe/Kyiv"), ("VN", "Asia/Ho_Chi_Minh"), ("CA", "America/Toronto"), ("SG", "Asia/Singapore"),
        ]
        let exits = places.enumerated().map { index, place in
            ProxyExit(ip: "203.0.113.\(index + 1)", countryCode: place.0, timeZone: place.1,
                      languages: ProxyProbe.commonLanguages[place.0] ?? [])
        }
        var seeds: Set<Int> = []
        let profiles = try exits.enumerated().map { index, exit in
            let seed = FingerprintSettings.newSeed(excluding: seeds)
            seeds.insert(seed)
            var fingerprint = IdentitySampler.sample(seed: seed)
            fingerprint.apply(try #require(IdentitySampler.LocaleHint(exit: exit)))
            return try BrowserProfile(name: "Exit \(exit.countryCode)", port: testPort(9340 + index),
                                      fingerprint: fingerprint, proxy: "").validated()
        }
        let results = try await probe(profiles, label: "isolation-exits", exits: exits)
        for (profile, result) in zip(profiles, results) {
            let report = result.report
            let language = profile.fingerprint.language
            #expect(report.passed, "\(language) \(profile.fingerprint.timeZone): \(report.items.filter { $0.status == .fail })")
            expectPassed(report, ["languages", "locale", "date-string", "time-zone", "exit-time-zone", "exit-language"],
                         language)
            #expect(report.observation.main.locale == SelfCheck.engineLocale(for: language), "\(language)")
        }
        let read = Dictionary(uniqueKeysWithValues: zip(profiles, results).map {
            ($0.fingerprint.language, "\($1.report.observation.main.locale) \($1.report.observation.main.timeZone)")
        })
        #expect(read["en-IN"] == "en-GB Asia/Calcutta")
        #expect(read["es-AR"] == "es-MX America/Buenos_Aires")
        #expect(read["zh-MO"] == "zh-HK Asia/Macau")
        #expect(read["uk-UA"] == "uk Europe/Kiev")
    }

    @Test("SelfCheck maps languages with the localizations the engine ships")
    func engineLocalizations() throws {
        let engine = URL(fileURLWithPath: try #require(testAppPath))
            .appendingPathComponent("Contents/Frameworks/Chromium.app", isDirectory: true)
        let localizations = try #require(Bundle(url: engine)?.localizations)
        #expect(localizations.sorted() == SelfCheck.engineLocalizations.sorted())
    }
}
