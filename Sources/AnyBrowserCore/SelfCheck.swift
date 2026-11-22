import Foundation
import Network

/// What a page in one Profile's running browser reads, from the main thread, a Worker and a
/// blob iframe.
public struct SelfCheckObservation: Codable, Equatable, Sendable {
    /// Values one JavaScript realm reports.
    public struct Realm: Codable, Equatable, Sendable {
        public var userAgent: String
        public var platform: String
        public var hardwareConcurrency: Int
        public var deviceMemory: Double?
        public var language: String
        public var languages: [String]
        public var timeZone: String
        public var locale: String
        /// `String(new Date(2026, 0, 15, 12))`, whose zone name is in ICU's language.
        public var dateString: String
        /// Width of an 18pt Arial pangram on an OffscreenCanvas.
        public var measureText: Double?
        public var webGLVendor: String?
        public var webGLRenderer: String?
    }

    public struct Frame: Codable, Equatable, Sendable {
        public var locale: String
        public var dateString: String
        public var measureText: Double?
        public var markers: [String]
    }

    public struct Brand: Codable, Equatable, Sendable {
        public var brand: String
        public var version: String
    }

    public struct ClientHints: Codable, Equatable, Sendable {
        public var brands: [Brand]
        public var fullVersionList: [Brand]
        public var platform: String
        public var platformVersion: String
        public var architecture: String
        public var bitness: String
        public var mobile: Bool
    }

    public struct Screen: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var availWidth: Int
        public var availHeight: Int
        public var colorDepth: Int
        public var devicePixelRatio: Double
    }

    public var main: Realm
    public var worker: Realm?
    public var frame: Frame?
    public var clientHints: ClientHints?
    public var screen: Screen
    /// The same measurement on a page `<canvas>`.
    public var canvasMeasureText: Double?
    /// Whether drawing the same Canvas twice gives the same pixels.
    public var canvasStable: Bool
    /// Window keys and symbols that mention AnyBrowser.
    public var markers: [String]
    /// The long zone name for the probe date in the Profile's language, as Intl formats it.
    public var expectedZoneName: String?
    /// The name Intl gives the Profile's and the exit's time zones. ICU keeps older names for some
    /// zones the configuration or the exit service spells the current way: Asia/Kolkata reads as
    /// Asia/Calcutta, Europe/Kyiv as Europe/Kiev.
    public var timeZoneNames: [String: String]?
}

/// The probe results compared item by item with the Profile's saved configuration.
public struct SelfCheckReport: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pass, fail
        /// Nothing configured to compare with, or a value the engine cannot set yet.
        case info
    }

    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var expected: String?
        public var observed: String
        public var status: Status
        /// What the user can do about a failure, when AnyBrowser knows.
        public var note: String?

        public init(id: String, title: String, expected: String?, observed: String, status: Status,
                    note: String? = nil) {
            self.id = id
            self.title = title
            self.expected = expected
            self.observed = observed
            self.status = status
            self.note = note
        }
    }

    public var profileID: UUID
    public var checkedAt: Date
    public var passed: Bool
    public var items: [Item]
    public var observation: SelfCheckObservation

    public init(profileID: UUID, checkedAt: Date, items: [Item], observation: SelfCheckObservation) {
        self.profileID = profileID
        self.checkedAt = checkedAt
        self.passed = !items.contains { $0.status == .fail }
        self.items = items
        self.observation = observation
    }

    public func item(_ id: String) -> Item? { items.first { $0.id == id } }
}

/// A runtime self-check: opens a background tab on a page served from this Mac's loopback
/// address, reads what the page sees, closes the tab and compares the values with the Profile.
/// Nothing is sent to an outside service.
public enum SelfCheck {
    public static func run(endpoint: URL, profile: BrowserProfile, exit: ProxyExit?) async throws -> SelfCheckReport {
        let zones = [timeZone(of: profile.fingerprint), exit?.timeZone ?? ""]
        let value = try await evaluate(probeScript(language: profile.fingerprint.primaryLanguage, timeZones: zones),
                                       endpoint: endpoint)
        guard JSONSerialization.isValidJSONObject(value) else {
            throw ProfileError.invalid("自检脚本没有返回结果。")
        }
        let observation = try JSONDecoder().decode(SelfCheckObservation.self,
                                                   from: JSONSerialization.data(withJSONObject: value))
        return report(for: profile, exit: exit, observation: observation)
    }

    /// Evaluates `expression` (awaiting a promise) in a background tab on the loopback probe page
    /// and returns its JSON value; the tab is closed again either way.
    static func evaluate(_ expression: String, endpoint: URL) async throws -> Any {
        let page = try await ProbePage.start()
        defer { page.stop() }
        let client = try DevToolsClient(endpoint: endpoint, timeout: 20)
        defer { client.close() }
        let created = try await client.send("Target.createTarget", ["url": page.url.absoluteString, "background": true])
        guard let target = created["targetId"] as? String else {
            throw ProfileError.invalid("浏览器没有打开自检标签。")
        }
        do {
            let attached = try await client.send("Target.attachToTarget", ["targetId": target, "flatten": true])
            guard let session = attached["sessionId"] as? String else {
                throw ProfileError.invalid("无法连接自检标签。")
            }
            try await waitForPage(client: client, session: session, url: page.url)
            let result = try await client.send("Runtime.evaluate", [
                "expression": expression, "awaitPromise": true, "returnByValue": true,
            ], sessionId: session)
            guard result["exceptionDetails"] == nil, let value = (result["result"] as? [String: Any])?["value"] else {
                throw ProfileError.invalid("自检脚本没有返回结果。")
            }
            _ = try? await client.send("Target.closeTarget", ["targetId": target])
            return value
        } catch {
            _ = try? await client.send("Target.closeTarget", ["targetId": target])
            throw error
        }
    }

    /// A new tab starts on about:blank, where content scripts do not run; the probe has to wait
    /// for the loopback page itself.
    private static func waitForPage(client: DevToolsClient, session: String, url: URL) async throws {
        for _ in 0..<100 {
            let result = try await client.send("Runtime.evaluate", [
                "expression": "document.readyState === 'complete' && location.href", "returnByValue": true,
            ], sessionId: session)
            if ((result["result"] as? [String: Any])?["value"] as? String) == url.absoluteString { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ProfileError.invalid("自检页面没有加载完成。")
    }

    // MARK: Comparison

    /// `hostLanguages` are this Mac's preferred languages, which a browser that lost
    /// `-AppleLanguages` falls back to.
    static func report(for profile: BrowserProfile, exit: ProxyExit?, observation: SelfCheckObservation,
                       checkedAt: Date = Date(), hostLanguages: [String] = Locale.preferredLanguages) -> SelfCheckReport {
        let fingerprint = profile.fingerprint
        let seen = observation.main
        let hints = observation.clientHints
        let hardware = EngineHardwareTable.bundled
        var items: [SelfCheckReport.Item] = []
        func add(_ id: String, _ title: String, expected: String?, observed: String, _ status: SelfCheckReport.Status,
                 note: String? = nil) {
            items.append(.init(id: id, title: title, expected: expected, observed: observed, status: status,
                               note: status == .pass ? nil : note))
        }
        func judge(_ ok: Bool) -> SelfCheckReport.Status { ok ? .pass : .fail }

        let markers = observation.markers + (observation.frame?.markers ?? [])
        add("markers", "页面上的 AnyBrowser 标记", expected: "无",
            observed: markers.isEmpty ? "无" : markers.joined(separator: ", "), judge(markers.isEmpty))

        // Without a platform the engine reports this Mac.
        let platform = fingerprint.platform ?? .macOS
        let uaPlatform = hints?.platform ?? ""
        let token: (ua: String, navigator: String) = switch platform {
        case .macOS: ("Macintosh; Intel Mac OS X 10_15_7", "MacIntel")
        case .windows: ("Windows NT 10.0; Win64; x64", "Win32")
        case .linux: ("X11; Linux x86_64", "Linux x86_64")
        }
        add("platform", "平台", expected: platform.title,
            observed: "\(uaPlatform) · \(seen.platform)",
            judge(uaPlatform == platform.title && seen.platform == token.navigator && seen.userAgent.contains(token.ua)))

        let platformVersion = hints?.platformVersion ?? ""
        if fingerprint.platformVersion.isEmpty {
            add("platform-version", "平台版本", expected: nil, observed: platformVersion, .info)
        } else {
            add("platform-version", "平台版本", expected: fingerprint.platformVersion, observed: platformVersion,
                judge(platformVersion == fingerprint.platformVersion))
        }

        let brands = hints?.brands.map(\.brand) ?? []
        let fullVersions = hints?.fullVersionList ?? []
        let brandName: String? = switch fingerprint.brand {
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        default: nil
        }
        let suffix: String? = switch fingerprint.brand {
        case .edge: "Edg/"
        case .opera: "OPR/"
        case .vivaldi: "Vivaldi/"
        default: nil
        }
        let uaToken = suffix.flatMap { Self.token($0, in: seen.userAgent) }
        let brandOK = brandName.map(brands.contains) ?? !brands.contains("Google Chrome")
        add("brand", "浏览器品牌", expected: fingerprint.brand?.rawValue ?? "引擎默认（Chromium）",
            observed: ([brands.joined(separator: ", ")] + [uaToken].compactMap { $0 }).joined(separator: " · "),
            judge(brandOK && (suffix == nil || uaToken != nil)))

        let observedVersion = brandName.flatMap { name in fullVersions.first { $0.brand == name }?.version }
            ?? uaToken.map { String($0.drop { $0 != "/" }.dropFirst()) }
            ?? fullVersions.first { $0.brand == "Chromium" }?.version ?? ""
        if fingerprint.brandVersion.isEmpty {
            add("brand-version", "品牌版本", expected: nil, observed: observedVersion, .info)
        } else {
            add("brand-version", "品牌版本", expected: fingerprint.brandVersion, observed: observedVersion,
                judge(observedVersion == fingerprint.brandVersion))
        }
        if fingerprint.brand == .edge {
            // Real Edge reduces its UA token the same way Chrome does.
            let major = observedVersion.split(separator: ".").first.map(String.init) ?? ""
            let expected = "Edg/\(major).0.0.0"
            add("edge-user-agent", "Edge 的 UA 版本", expected: expected, observed: uaToken ?? "",
                judge(uaToken == expected))
        }

        let cpus = fingerprint.cpuCount ?? hardware.defaultCPUCount(seed: fingerprint.seed)
        add("hardware-concurrency", "逻辑 CPU", expected: String(cpus),
            observed: Self.pair(String(seen.hardwareConcurrency), observation.worker.map { String($0.hardwareConcurrency) }),
            judge(seen.hardwareConcurrency == cpus && observation.worker.map { $0.hardwareConcurrency == cpus } != false))

        let memory = Double(hardware.deviceMemory(seed: fingerprint.seed))
        add("device-memory", "设备内存", expected: "\(Self.number(memory)) GB",
            observed: Self.pair(seen.deviceMemory.map { "\(Self.number($0)) GB" } ?? "无",
                                observation.worker.map { $0.deviceMemory.map { "\(Self.number($0)) GB" } ?? "无" }),
            judge(seen.deviceMemory == memory && observation.worker.map { $0.deviceMemory == memory } != false))

        let renderer = seen.webGLRenderer ?? ""
        let workerRenderer = observation.worker?.webGLRenderer
        let spoofsGPU = fingerprint.adjustments.contains(.gpu) && fingerprint.platform != .linux
        if spoofsGPU, let gpu = hardware.gpu(for: fingerprint.platform, seed: fingerprint.seed) {
            add("webgl", "WebGL 显卡", expected: gpu.renderer, observed: Self.pair(renderer, workerRenderer),
                judge(renderer == gpu.renderer && (workerRenderer == nil || workerRenderer == renderer)))
        } else {
            add("webgl", "WebGL 显卡（本机）", expected: nil, observed: renderer, .info)
        }
        // What the page reads must be one machine, whatever the configuration says.
        let gpuSet = platform == .macOS ? hardware.macOS : hardware.windows
        if spoofsGPU, fingerprint.platform != nil, let gpu = gpuSet.first(where: { $0.renderer == renderer }) {
            let readMemory = seen.deviceMemory.map { Int($0) } ?? 0
            add("hardware", "硬件组合", expected: "\(gpu.model) · \(Self.list(gpu.cpuCounts)) 个 CPU · \(Self.list(gpu.deviceMemory)) GB",
                observed: "\(gpu.model) · \(seen.hardwareConcurrency) 个 CPU · \(readMemory) GB",
                judge(gpu.cpuCounts.contains(seen.hardwareConcurrency) && gpu.deviceMemory.contains(readMemory)))
        }

        let language = fingerprint.primaryLanguage
        let realms = [observation.worker.map { ("Worker", $0.locale, $0.dateString) },
                      observation.frame.map { ("iframe", $0.locale, $0.dateString) }].compactMap { $0 }
        if language.isEmpty {
            add("languages", "语言列表", expected: nil, observed: seen.languages.joined(separator: ", "), .info)
        } else {
            let expected = fingerprint.acceptLanguages
            add("languages", "语言列表", expected: expected.joined(separator: ", "),
                observed: seen.languages.joined(separator: ", "),
                judge(seen.language == language && seen.languages == expected
                      && observation.worker.map { $0.languages == expected } != false))
            let mapped = engineLocale(for: language)
            let localeOK = seen.locale == language || seen.locale == mapped
            // When the Profile's language reads as the same locale as this Mac's, a browser that lost
            // its language parameter looks exactly like one that kept it.
            let indistinguishable = localeOK && mapped != nil && mapped == engineLocale(preferences: hostLanguages)
            let realmsAgree = realms.allSatisfy { $0.1 == seen.locale }
            // A restart from inside the browser (chrome://restart, the settings page) rebuilds argv
            // without `-AppleLanguages`, so ICU falls back to this Mac's languages.
            add("locale", "Intl 默认语言",
                expected: mapped.map { $0 == language ? language : "\(language)（Chromium 读作 \($0)）" } ?? language,
                observed: ([seen.locale] + realms.map { "\($0.0) \($0.1)" }).joined(separator: " · "),
                !(localeOK && realmsAgree) ? .fail : indistinguishable ? .info : .pass,
                note: !localeOK ? "语言与 Profile 不一致：可能是浏览器自行重启过，请从 AnyBrowser 重启此 Profile"
                    : realmsAgree && indistinguishable
                        ? "Profile 语言和本机语言在浏览器里都读作 \(mapped ?? language)，无法据此判断语言参数是否仍然生效" : nil)
            let zoneName = Self.zoneName(seen.dateString)
            add("date-string", "Date 字符串的时区名", expected: observation.expectedZoneName,
                observed: ([zoneName ?? seen.dateString] + realms.map { "\($0.0) \(Self.zoneName($0.2) ?? $0.2)" })
                    .joined(separator: " · "),
                judge(zoneName != nil && zoneName == observation.expectedZoneName
                      && realms.allSatisfy { $0.2 == seen.dateString }))
        }

        // Either spelling of a renamed zone is the same zone; the page says which one ICU uses.
        let zoneNames = observation.timeZoneNames ?? [:]
        func isZone(_ observed: String, _ configured: String) -> Bool {
            observed == configured || observed == zoneNames[configured]
        }
        func zoneTitle(_ zone: String) -> String {
            zoneNames[zone].map { $0 == zone ? zone : "\(zone)（Chromium 读作 \($0)）" } ?? zone
        }
        let zone = Self.timeZone(of: fingerprint)
        add("time-zone", "时区", expected: zoneTitle(zone),
            observed: Self.pair(seen.timeZone, observation.worker?.timeZone),
            judge(isZone(seen.timeZone, zone) && observation.worker.map { isZone($0.timeZone, zone) } != false))
        if let exit, !exit.timeZone.isEmpty {
            add("exit-time-zone", "时区与出口", expected: zoneTitle(exit.timeZone), observed: seen.timeZone,
                judge(isZone(seen.timeZone, exit.timeZone)))
        }
        if let exit, !exit.languages.isEmpty {
            let spoken = Set(exit.languages.compactMap { $0.split(separator: "-").first?.lowercased() })
            let primary = seen.language.split(separator: "-").first?.lowercased() ?? ""
            add("exit-language", "语言与出口", expected: exit.languages.prefix(3).joined(separator: ", "),
                observed: seen.language, judge(spoken.contains(primary)))
        }

        let screen = observation.screen
        let screenText = "\(screen.width)×\(screen.height)（可用 \(screen.availWidth)×\(screen.availHeight)）"
            + " @\(Self.number(screen.devicePixelRatio))x · \(screen.colorDepth)bit"
        if let width = fingerprint.screenWidth, let height = fingerprint.screenHeight {
            add("screen", "屏幕", expected: "\(width)×\(height)", observed: screenText,
                judge(screen.width == width && screen.height == height))
        } else {
            add("screen", "屏幕（跟随本机）", expected: nil, observed: screenText, .info)
        }

        // Workers are not affected by the engine's text-metrics factor, so they are the reference.
        let measured = [seen.measureText, observation.canvasMeasureText, observation.frame?.measureText]
        let reference = observation.worker?.measureText
        let plausible = measured.allSatisfy { ($0 ?? 0) > 100 }
        add("measure-text", "Canvas 文本宽度", expected: reference.map(Self.number),
            observed: measured.map { $0.map(Self.number) ?? "无" }.joined(separator: " · "),
            judge(plausible && (reference == nil || measured.allSatisfy { $0 == reference })))
        add("canvas-stable", "Canvas 两次读取", expected: "一致", observed: observation.canvasStable ? "一致" : "不一致",
            judge(observation.canvasStable))

        return SelfCheckReport(profileID: profile.id, checkedAt: checkedAt, items: items, observation: observation)
    }

    /// The zone name in a `Date.prototype.toString` result, e.g. "Eastern Standard Time".
    static func zoneName(_ dateString: String) -> String? {
        guard dateString.hasSuffix(")"), let open = dateString.lastIndex(of: "(") else { return nil }
        return String(dateString[dateString.index(after: open)..<dateString.index(before: dateString.endIndex)])
    }

    /// The zone the browser runs in: the Profile's, or this Mac's when it has none.
    static func timeZone(of fingerprint: FingerprintSettings) -> String {
        fingerprint.timeZone.isEmpty ? TimeZone.current.identifier : fingerprint.timeZone
    }

    /// The Intl locale pages get for `language`. Chromium runs in the UI localization Cocoa picks
    /// for `-AppleLanguages` among the ones the engine ships, and Foundation makes the same pick
    /// here: en-AU and en-IN become en-GB, en-CA en-US, zh-MO zh-HK, pt-AO pt-PT, es-AR es-419,
    /// de-AT de, a language without a localization en. ICU then takes `es` as es-ES and `es-419` as es-MX.
    static func engineLocale(for language: String) -> String? {
        engineLocale(preferences: [language])
    }

    /// The Intl locale for a list of preferred languages, as Cocoa picks among the engine's.
    static func engineLocale(preferences: [String]) -> String? {
        guard !preferences.isEmpty,
              let picked = Bundle.preferredLocalizations(from: engineLocalizations, forPreferences: preferences).first else {
            return nil
        }
        switch picked {
        case "en": return "en-US"
        case "es": return "es-ES"
        case "es_419": return "es-MX"
        default: return picked.replacingOccurrences(of: "_", with: "-")
        }
    }

    /// The `.lproj` folders of the bundled engine's Chromium.app; IsolationProbeTests compares
    /// them with the engine.
    static let engineLocalizations = """
        af am ar as az be bg bn bs ca cs cy da de el en en_GB es es_419 et eu fa fi fil fr fr_CA gl gu he hi \
        hr hu hy id is it ja ka kk km kn ko ky lo lt lv mk ml mn mr ms my nb ne nl or pa pl pt_BR pt_PT ro \
        ru si sk sl sq sr sr_Latn sv sw ta te th tr uk ur uz vi zh_CN zh_HK zh_TW zu
        """.split(separator: " ").map(String.init)

    /// `Edg/148.0.0.0` for prefix `Edg/`.
    private static func token(_ prefix: String, in userAgent: String) -> String? {
        userAgent.split(separator: " ").first { $0.hasPrefix(prefix) }.map(String.init)
    }

    private static func pair(_ main: String, _ worker: String?) -> String {
        guard let worker, worker != main else { return main }
        return "\(main) · Worker \(worker)"
    }

    private static func list(_ values: [Int]) -> String {
        values.map(String.init).joined(separator: "/")
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    // MARK: Probe

    /// The probe as one expression. `language` is only used to format the expected zone name, and
    /// `timeZones` only to ask Intl for their names.
    static func probeScript(language: String, timeZones: [String] = []) -> String {
        let json = { (values: [String]) in
            (try? JSONSerialization.data(withJSONObject: values)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        }
        return probeTemplate.replacingOccurrences(of: "__LANGUAGES__", with: json([language]))
            .replacingOccurrences(of: "__TIME_ZONES__", with: json(timeZones.filter { !$0.isEmpty }))
    }

    private static let probeTemplate = #"""
    (async () => {
      const [profileLanguage] = __LANGUAGES__;
      const timeZones = __TIME_ZONES__;
      const text = 'Cwm fjordbank glyphs vext quiz';
      const read = () => {
        let measureText = null, webGLVendor = null, webGLRenderer = null;
        try {
          const context = new OffscreenCanvas(16, 16).getContext('2d');
          context.font = '18pt Arial';
          measureText = context.measureText('Cwm fjordbank glyphs vext quiz').width;
        } catch (e) {}
        try {
          const gl = new OffscreenCanvas(1, 1).getContext('webgl');
          const info = gl.getExtension('WEBGL_debug_renderer_info');
          webGLVendor = gl.getParameter(info.UNMASKED_VENDOR_WEBGL);
          webGLRenderer = gl.getParameter(info.UNMASKED_RENDERER_WEBGL);
        } catch (e) {}
        const intl = Intl.DateTimeFormat().resolvedOptions();
        return {
          userAgent: navigator.userAgent, platform: navigator.platform,
          hardwareConcurrency: navigator.hardwareConcurrency, deviceMemory: navigator.deviceMemory ?? null,
          language: navigator.language, languages: Array.from(navigator.languages),
          timeZone: intl.timeZone, locale: intl.locale, dateString: String(new Date(2026, 0, 15, 12)),
          measureText, webGLVendor, webGLRenderer,
        };
      };
      const markersOf = (scope) => Object.getOwnPropertyNames(scope).filter((key) => /anybrowser/i.test(key))
        .concat(Object.getOwnPropertySymbols(scope).map(String).filter((name) => /anybrowser/i.test(name)));
      const settle = (start, timeout) => new Promise((resolve) => {
        const timer = setTimeout(() => resolve(null), timeout);
        start((value) => { clearTimeout(timer); resolve(value); });
      });

      const main = read();
      let clientHints = null;
      try {
        const data = navigator.userAgentData;
        const high = await data.getHighEntropyValues(['platformVersion', 'architecture', 'bitness', 'fullVersionList']);
        const brands = (list) => (list || []).map((item) => ({ brand: item.brand, version: item.version }));
        clientHints = {
          brands: brands(data.brands), fullVersionList: brands(high.fullVersionList), platform: data.platform,
          platformVersion: high.platformVersion || '', architecture: high.architecture || '',
          bitness: high.bitness || '', mobile: data.mobile,
        };
      } catch (e) {}

      const draw = () => {
        const canvas = document.createElement('canvas');
        canvas.width = 240;
        canvas.height = 60;
        const context = canvas.getContext('2d');
        context.textBaseline = 'alphabetic';
        context.fillStyle = '#f60';
        context.fillRect(125, 1, 62, 20);
        context.fillStyle = '#069';
        context.font = '11pt Arial';
        context.fillText(text, 2, 15);
        context.fillStyle = 'rgba(102, 204, 0, 0.7)';
        context.font = '18pt Arial';
        context.fillText(text, 4, 45);
        return canvas.toDataURL();
      };
      const page = document.createElement('canvas').getContext('2d');
      page.font = '18pt Arial';

      const worker = await settle((done) => {
        try {
          const source = `postMessage((${read.toString()})());`;
          const thread = new Worker(URL.createObjectURL(new Blob([source], { type: 'text/javascript' })));
          thread.onmessage = (event) => { thread.terminate(); done(event.data); };
          thread.onerror = () => { thread.terminate(); done(null); };
        } catch (e) { done(null); }
      }, 5000);

      const frame = await settle((done) => {
        const token = String(Math.random());
        const html = '<!doctype html><script>(() => { const c = document.createElement("canvas").getContext("2d");'
          + ' c.font = "18pt Arial"; parent.postMessage({ token: ' + JSON.stringify(token) + ','
          + ' locale: Intl.DateTimeFormat().resolvedOptions().locale, dateString: String(new Date(2026, 0, 15, 12)),'
          + ' measureText: c.measureText(' + JSON.stringify(text) + ').width,'
          + ' markers: (' + markersOf.toString() + ')(window) }, "*"); })()<\/script>';
        const element = document.createElement('iframe');
        const listen = (event) => {
          if (!event.data || event.data.token !== token) return;
          window.removeEventListener('message', listen);
          element.remove();
          const { token: _, ...value } = event.data;
          done(value);
        };
        window.addEventListener('message', listen);
        element.src = URL.createObjectURL(new Blob([html], { type: 'text/html' }));
        document.body.appendChild(element);
      }, 5000);

      let expectedZoneName = null;
      try {
        expectedZoneName = new Intl.DateTimeFormat(profileLanguage || undefined, { timeZoneName: 'long' })
          .formatToParts(new Date(2026, 0, 15, 12)).find((part) => part.type === 'timeZoneName').value;
      } catch (e) {}
      const timeZoneNames = {};
      for (const zone of timeZones) {
        try {
          timeZoneNames[zone] = new Intl.DateTimeFormat('en', { timeZone: zone }).resolvedOptions().timeZone;
        } catch (e) {}
      }

      return {
        main, worker, frame, clientHints,
        screen: { width: screen.width, height: screen.height, availWidth: screen.availWidth,
          availHeight: screen.availHeight, colorDepth: screen.colorDepth, devicePixelRatio },
        canvasMeasureText: page.measureText(text).width,
        canvasStable: draw() === draw(),
        markers: markersOf(window),
        expectedZoneName, timeZoneNames,
      };
    })()
    """#
}

/// A one-page HTTP server on a random loopback port for the self-check tab.
private final class ProbePage: @unchecked Sendable {
    let url: URL
    private let listener: NWListener

    private init(listener: NWListener, url: URL) {
        self.listener = listener
        self.url = url
    }

    static func start() async throws -> ProbePage {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "anybrowser.selfcheck.page")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in
                let body = "<!doctype html><meta charset=utf-8><title>Self check</title><body></body>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Cache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        listener.cancel()
                        continuation.resume(throwing: ProfileError.invalid("自检页面没有可用端口。"))
                    }
                case .failed(let error), .waiting(let error):
                    guard once.claim() else { return }
                    listener.cancel()
                    continuation.resume(throwing: ProfileError.invalid("无法启动自检页面：\(error.localizedDescription)"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return ProbePage(listener: listener, url: URL(string: "http://127.0.0.1:\(port)/")!)
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.cancel()
    }
}
