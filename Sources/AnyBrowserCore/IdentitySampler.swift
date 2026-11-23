import Foundation

/// Builds a complete, internally consistent browser identity for a new Profile.
///
/// The seed remains the engine anchor for canvas, client rects and WebGL. Everything that
/// Stripe-style fingerprinting reads directly (screen, language, time zone, font set) is
/// chosen here as one bundle, instead of being left at the host machine's values.
public enum IdentitySampler {
    public struct Constraints: Sendable {
        /// Preset ids to sample from; nil means the default macOS-only set.
        public var presets: [String]?
        /// Keep the generated identity on these platforms, e.g. when regenerating a Windows Profile.
        public var platforms: [BrowserPlatform]?
        /// An explicit preset, used by the batch sheet and by "regenerate identity".
        public var preset: IdentityPreset?
        /// Language and time zone taken from the proxy exit; nil means sample the catalog.
        public var locale: LocaleHint?

        public init(presets: [String]? = nil, platforms: [BrowserPlatform]? = nil,
                    preset: IdentityPreset? = nil, locale: LocaleHint? = nil) {
            self.presets = presets
            self.platforms = platforms
            self.preset = preset
            self.locale = locale
        }
    }

    /// A validated language/time-zone pair. The proxy exit is authoritative when it is available;
    /// otherwise the sampler uses its own catalog.
    public struct LocaleHint: Equatable, Sendable {
        public let language: String
        public let timeZone: String
        public let languages: [String]

        public init?(language: String, timeZone: String, languages: [String]? = nil) {
            let primary = IdentitySampler.chromeLanguageTag(language)
            guard FingerprintSettings.isLanguageTag(primary),
                  FingerprintSettings.isTimeZone(timeZone) else { return nil }
            let base = primary.split(separator: "-").first.map(String.init) ?? primary
            var ordered: [String] = []
            for tag in (languages ?? []).map(IdentitySampler.chromeLanguageTag)
            where FingerprintSettings.isLanguageTag(tag) && !ordered.contains(tag) {
                ordered.append(tag)
            }
            if ordered.first != primary {
                ordered.removeAll { $0 == primary }
                ordered.insert(primary, at: 0)
            }
            if ordered.isEmpty {
                ordered = base == primary ? [primary] : [primary, base]
            } else if ordered.count == 1, base != primary {
                // A one-entry navigator.languages is rare; keep the base-language fallback.
                ordered.append(base)
            }
            self.language = primary
            self.timeZone = timeZone
            self.languages = ordered
        }

        /// Only the exit's first language is used, completed the way Chrome lists languages by
        /// default: ipapi.co returns every language of the country ("en-US,es-US,haw,fr").
        public init?(exit: ProxyExit) {
            let tags = exit.languages.map(IdentitySampler.chromeLanguageTag).filter(FingerprintSettings.isLanguageTag)
            let fallback = ProxyProbe.commonLanguages[exit.countryCode.uppercased()] ?? []
            guard let primary = tags.first ?? fallback.first else { return nil }
            self.init(language: primary, timeZone: exit.timeZone)
        }

        /// The Mac's own locale, used when a Profile has no proxy.
        public static var host: LocaleHint? {
            guard let language = Locale.preferredLanguages.first else { return nil }
            return LocaleHint(language: language, timeZone: TimeZone.current.identifier)
        }
    }

    /// A language tag as Chrome writes it. macOS reports `zh-Hans-CN` or `en_US`; Chrome uses
    /// `zh-CN` and `en-US`, and has no script subtags in its language lists.
    static func chromeLanguageTag(_ tag: String) -> String {
        let parts = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let first = parts.first else { return "" }
        let language = first.lowercased()
        var rest = Array(parts.dropFirst())
        var script: String?
        if let next = rest.first, next.count == 4, next.allSatisfy(\.isLetter) {
            script = next.lowercased()
            rest.removeFirst()
        }
        if let region = rest.first, region.count == 2 || region.count == 3 {
            rest[0] = region.uppercased()
        } else if language == "zh", let script {
            // A bare script stands for the region Chrome would use.
            rest.insert(script == "hant" ? "TW" : "CN", at: 0)
        }
        return ([language] + rest).joined(separator: "-")
    }

    private struct Weighted<Value> {
        let value: Value
        let weight: Int
    }

    private struct ScreenProfile {
        let width: Int
        let height: Int
        let availWidth: Int
        let availHeight: Int
        let colorDepth: Int
        let scale: Double
        let weight: Int
    }

    private struct LocaleProfile {
        let language: String
        let timeZone: String
        let weight: Int

        var languages: [String] {
            let base = language.split(separator: "-").first.map(String.init) ?? language
            return base == language ? [language] : [language, base]
        }
    }

    /// New Profiles start on macOS because the bundled engine can already match the host's
    /// font rendering there. Windows/Linux remain available through an explicit preset.
    private static let defaultPresetIDs = ["macos27-chrome", "macos26-chrome", "macos15-chrome"]

    /// Shared by whole identities and by the field randomizer's platform, brand and platform version.
    private static let presetWeights: [String: Int] = [
        "macos27-chrome": 30,
        "macos26-chrome": 45,
        "macos15-chrome": 25,
        "win11-chrome": 10,
        "win10-chrome": 5,
        "win11-edge": 5,
        "linux-chrome": 1,
    ]

    private static let localeProfiles: [Weighted<LocaleProfile>] = [
        .init(value: .init(language: "en-US", timeZone: "America/New_York", weight: 30), weight: 30),
        .init(value: .init(language: "en-US", timeZone: "America/Chicago", weight: 10), weight: 10),
        .init(value: .init(language: "en-US", timeZone: "America/Denver", weight: 5), weight: 5),
        .init(value: .init(language: "en-US", timeZone: "America/Los_Angeles", weight: 15), weight: 15),
        .init(value: .init(language: "en-GB", timeZone: "Europe/London", weight: 10), weight: 10),
        .init(value: .init(language: "zh-CN", timeZone: "Asia/Shanghai", weight: 10), weight: 10),
        .init(value: .init(language: "ja-JP", timeZone: "Asia/Tokyo", weight: 5), weight: 5),
        .init(value: .init(language: "de-DE", timeZone: "Europe/Berlin", weight: 5), weight: 5),
        .init(value: .init(language: "fr-FR", timeZone: "Europe/Paris", weight: 5), weight: 5),
        .init(value: .init(language: "es-ES", timeZone: "Europe/Madrid", weight: 5), weight: 5),
        .init(value: .init(language: "pt-BR", timeZone: "America/Sao_Paulo", weight: 5), weight: 5),
        .init(value: .init(language: "ko-KR", timeZone: "Asia/Seoul", weight: 5), weight: 5),
    ]

    public static func sample(seed: Int, constraints: Constraints = .init()) -> FingerprintSettings {
        let presetIDs = constraints.presets
            ?? (constraints.platforms == nil ? defaultPresetIDs : IdentityPreset.all.map(\.id))
        let preset = constraints.preset ?? choosePreset(ids: presetIDs, platforms: constraints.platforms)
        var fingerprint = FingerprintSettings(seed: seed)
        preset.apply(to: &fingerprint)

        applyScreen(to: &fingerprint, for: preset.platform)

        let fallbackLocale = choose(localeProfiles)
            ?? LocaleProfile(language: "en-US", timeZone: "America/New_York", weight: 1)
        fingerprint.language = constraints.locale?.language ?? fallbackLocale.language
        fingerprint.languages = constraints.locale?.languages ?? fallbackLocale.languages
        fingerprint.timeZone = constraints.locale?.timeZone ?? fallbackLocale.timeZone

        fingerprint.touch = false
        fingerprint.fontProfile = fontProfile(for: preset.id, platform: preset.platform)
        // Audio and client rects are seed-derived and already work in this engine; they add
        // device separation beyond Canvas/GPU without claiming an unsupported value.
        fingerprint.adjustments.insert(.audio)
        // The font set is part of the platform identity and the preset always names a platform;
        // without the switch every page reads this Mac's own fonts whatever the Profile claims.
        fingerprint.adjustments.insert(.font)
        fingerprint.adaptToPlatform()
        return fingerprint
    }

    public static func sample(seed: Int, preset: IdentityPreset?) -> FingerprintSettings {
        sample(seed: seed, constraints: .init(preset: preset))
    }

    /// A language/time-zone pair from the same catalog the whole-identity sampler uses.
    /// The field-level randomizer calls this so it cannot produce `zh-CN + America/New_York`.
    static func sampleLocale() -> (language: String, timeZone: String, languages: [String]) {
        let locale = choose(localeProfiles)
            ?? LocaleProfile(language: "en-US", timeZone: "America/New_York", weight: 1)
        return (locale.language, locale.timeZone, locale.languages)
    }

    /// A logical CPU count for the machine behind the identity. With spoofed WebGL the seed fixes
    /// the GPU, and the count comes from the machines that ship with it; otherwise WebGL shows this
    /// Mac's GPU and only the platform is known.
    static func randomCPUCount(for platform: BrowserPlatform?, seed: Int, spoofsGPU: Bool) -> Int {
        if spoofsGPU, platform != nil, let gpu = EngineHardwareTable.bundled.gpu(for: platform, seed: seed),
           let count = gpu.cpuCounts.randomElement() {
            return count
        }
        let values: [Int]
        switch platform {
        case .macOS: values = [8, 10, 12]
        case .windows, nil: values = [4, 8, 12, 16]
        case .linux: values = [4, 8]
        }
        return values.randomElement()!
    }

    /// A preset drawn with the shared weights from those `accepts` allows; all presets when none is allowed.
    static func weightedPreset(where accepts: (IdentityPreset) -> Bool) -> IdentityPreset {
        let candidates = IdentityPreset.all.filter(accepts)
        let weighted = (candidates.isEmpty ? IdentityPreset.all : candidates)
            .map { Weighted(value: $0, weight: presetWeights[$0.id] ?? 1) }
        return choose(weighted) ?? IdentityPreset.all.first { $0.id == "macos26-chrome" }!
    }

    private static func choosePreset(ids: [String], platforms: [BrowserPlatform]?) -> IdentityPreset {
        let wanted = Set(ids)
        guard IdentityPreset.all.contains(where: { wanted.contains($0.id) }) else {
            return IdentityPreset.all.first { $0.id == "macos26-chrome" }!
        }
        let allowed = Set(platforms ?? [])
        let narrowed = IdentityPreset.all.contains { wanted.contains($0.id) && allowed.contains($0.platform) }
        return weightedPreset { wanted.contains($0.id) && (!narrowed || allowed.contains($0.platform)) }
    }

    private static func screenProfiles(for platform: BrowserPlatform) -> [Weighted<ScreenProfile>] {
        switch platform {
        case .macOS:
            return [
                screen(1728, 1117, 1728, 1080, 24, 2, 40),
                screen(1512, 982, 1512, 945, 24, 2, 30),
                screen(2560, 1440, 2560, 1410, 24, 2, 20),
                screen(1440, 900, 1440, 875, 24, 2, 10),
            ]
        case .windows:
            return [
                screen(1920, 1080, 1920, 1040, 24, 1, 45),
                screen(1536, 864, 1536, 824, 24, 1.25, 20),
                screen(2560, 1440, 2560, 1400, 24, 1, 20),
                screen(1366, 768, 1366, 728, 24, 1, 15),
            ]
        case .linux:
            return [
                screen(1920, 1080, 1920, 1080, 24, 1, 60),
                screen(2560, 1440, 2560, 1440, 24, 1, 20),
                screen(1366, 768, 1366, 768, 24, 1, 20),
            ]
        }
    }

    private static func screen(_ width: Int, _ height: Int, _ availWidth: Int, _ availHeight: Int,
                               _ colorDepth: Int, _ scale: Double, _ weight: Int) -> Weighted<ScreenProfile> {
        Weighted(value: ScreenProfile(width: width, height: height, availWidth: availWidth,
                                      availHeight: availHeight, colorDepth: colorDepth,
                                      scale: scale, weight: weight),
                 weight: weight)
    }

    /// Fills a screen for `platform` when the fingerprint has none. Profiles built by hand get the
    /// same coherent display a sampled one would.
    static func applyScreen(to fingerprint: inout FingerprintSettings, for platform: BrowserPlatform) {
        guard fingerprint.screenWidth == nil, let screen = choose(screenProfiles(for: platform)) else { return }
        fingerprint.screenWidth = screen.width
        fingerprint.screenHeight = screen.height
        fingerprint.availWidth = screen.availWidth
        fingerprint.availHeight = screen.availHeight
        fingerprint.colorDepth = screen.colorDepth
        fingerprint.deviceScaleFactor = screen.scale
    }

    private static func fontProfile(for presetID: String, platform: BrowserPlatform) -> FontProfile {
        switch presetID {
        case "macos26-chrome": return .macos26
        case "macos15-chrome": return .macos15
        case "win11-chrome", "win11-edge": return .windows11
        case "win10-chrome": return .windows10
        case "linux-chrome": return .linux68
        default:
            switch platform {
            case .macOS: return .macos26
            case .windows: return .windows11
            case .linux: return .linux68
            }
        }
    }

    private static func choose<Value>(_ items: [Weighted<Value>]) -> Value? {
        let total = items.reduce(0) { $0 + max(0, $1.weight) }
        guard total > 0 else { return items.first?.value }
        var roll = Int.random(in: 0..<total)
        for item in items {
            let weight = max(0, item.weight)
            if roll < weight { return item.value }
            roll -= weight
        }
        return items.last?.value
    }
}
