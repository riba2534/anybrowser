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
            let primary = language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard FingerprintSettings.isLanguageTag(primary),
                  FingerprintSettings.isTimeZone(timeZone) else { return nil }
            let base = primary.split(separator: "-").first.map(String.init) ?? primary
            var ordered = (languages ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter(FingerprintSettings.isLanguageTag)
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

        public init?(exit: ProxyExit) {
            let tags = exit.languages.filter(FingerprintSettings.isLanguageTag)
            let fallback = ProxyProbe.commonLanguages[exit.countryCode.uppercased()] ?? []
            let ordered = tags.isEmpty ? fallback : tags
            guard let primary = ordered.first else { return nil }
            self.init(language: primary, timeZone: exit.timeZone, languages: ordered)
        }

        /// The Mac's own locale, used when a Profile has no proxy.
        public static var host: LocaleHint? {
            guard let language = Locale.preferredLanguages.first else { return nil }
            return LocaleHint(language: language, timeZone: TimeZone.current.identifier)
        }
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
    private static let defaultPresetIDs = ["macos26-chrome", "macos15-chrome"]

    /// Fingerprint Chromium 148 accepts `--fingerprint-screen-*`, but in a windowed probe both
    /// `screen.width/height` and `availWidth/Height` still reported the host display. Keep the
    /// fields for a future engine, but do not claim a screen the browser will not report.
    private static let screenSpoofingSupported = false

    private static let presetWeights: [String: Int] = [
        "macos26-chrome": 60,
        "macos15-chrome": 40,
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

        if screenSpoofingSupported {
            let screen = choose(screenProfiles(for: preset.platform))
                ?? ScreenProfile(width: 1920, height: 1080, availWidth: 1920, availHeight: 1040,
                                 colorDepth: 24, scale: 1, weight: 1)
            fingerprint.screenWidth = screen.width
            fingerprint.screenHeight = screen.height
            fingerprint.availWidth = screen.availWidth
            fingerprint.availHeight = screen.availHeight
            fingerprint.colorDepth = screen.colorDepth
            fingerprint.deviceScaleFactor = screen.scale
        }

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

    /// CPU counts that are plausible for the selected platform.
    static func randomCPUCount(for platform: BrowserPlatform?) -> Int {
        let values: [Int]
        switch platform {
        case .macOS: values = [8, 10, 12]
        case .windows: values = [4, 6, 8, 12, 16]
        case .linux: values = [2, 4, 8]
        case nil: values = [4, 8, 12, 16]
        }
        return values.randomElement()!
    }

    private static func choosePreset(ids: [String], platforms: [BrowserPlatform]?) -> IdentityPreset {
        let wanted = Set(ids)
        var candidates = IdentityPreset.all.filter { wanted.contains($0.id) }
        if let platforms, !platforms.isEmpty {
            let allowed = Set(platforms)
            let narrowed = candidates.filter { allowed.contains($0.platform) }
            if !narrowed.isEmpty { candidates = narrowed }
        }
        let weighted = candidates.map { Weighted(value: $0, weight: presetWeights[$0.id] ?? 1) }
        return choose(weighted) ?? IdentityPreset.all.first { $0.id == "macos26-chrome" }!
    }

    private static func screenProfiles(for platform: BrowserPlatform) -> [Weighted<ScreenProfile>] {
        switch platform {
        case .macOS:
            return [
                screen(1728, 1117, 1728, 1080, 30, 2, 40),
                screen(1512, 982, 1512, 945, 30, 2, 30),
                screen(2560, 1440, 2560, 1410, 30, 2, 20),
                screen(1440, 900, 1440, 875, 30, 2, 10),
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
