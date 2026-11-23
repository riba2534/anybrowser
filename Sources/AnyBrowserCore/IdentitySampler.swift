import Foundation

/// Builds a complete, internally consistent browser identity for a new Profile.
///
/// The seed remains the engine anchor for canvas, client rects and WebGL. Everything that
/// Stripe-style fingerprinting reads directly (screen, language, time zone, font set) is
/// chosen here as one bundle, instead of being left at the host machine's values.
///
/// A sample starts from a machine family — one preset together with the GPUs, memory, CPU
/// counts, screens, fonts and privacy posture real machines of that model ship with — and the
/// other fields are derived from it, never drawn independently. Every generated identity then
/// runs the consistency rules; a blocking one is redrawn, and a duplicate identity triple is
/// redrawn as well.
public enum IdentitySampler {
    /// How many identities one sample may generate before it falls back to the platform default.
    public static let maximumAttempts = 8

    public struct Constraints: Sendable {
        /// Preset ids to sample from; nil means the default macOS-only set.
        public var presets: [String]?
        /// Keep the generated identity on these platforms, e.g. when regenerating a Windows Profile.
        public var platforms: [BrowserPlatform]?
        /// An explicit preset, used by the batch sheet and by "regenerate identity".
        public var preset: IdentityPreset?
        /// Language and time zone taken from the proxy exit; nil means sample the catalog.
        public var locale: LocaleHint?
        /// Identity triples (`platform|seed|screenWidth`) already in use; a hit is redrawn.
        public var excluding: Set<String>
        /// An extra rule a generated identity must satisfy, used by tests and callers with
        /// requirements of their own. A rejection counts as a failed attempt.
        public var accepting: (@Sendable (FingerprintSettings) -> Bool)?

        public init(presets: [String]? = nil, platforms: [BrowserPlatform]? = nil,
                    preset: IdentityPreset? = nil, locale: LocaleHint? = nil,
                    excluding: Set<String> = [],
                    accepting: (@Sendable (FingerprintSettings) -> Bool)? = nil) {
            self.presets = presets
            self.platforms = platforms
            self.preset = preset
            self.locale = locale
            self.excluding = excluding
            self.accepting = accepting
        }
    }

    /// What one sample cost and whether it had to fall back.
    public struct SampleResult: Sendable {
        public let fingerprint: FingerprintSettings
        /// Identities generated before one was accepted (0 when the constraints allowed none).
        public let attempts: Int
        /// True when every attempt was rejected and the platform default family was used.
        public let usedFallback: Bool
        /// The machine family that was drawn, e.g. `macos26-chrome#0`.
        public let familyID: String?

        public init(fingerprint: FingerprintSettings, attempts: Int, usedFallback: Bool, familyID: String?) {
            self.fingerprint = fingerprint
            self.attempts = attempts
            self.usedFallback = usedFallback
            self.familyID = familyID
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

    struct Weighted<Value> {
        let value: Value
        let weight: Int
    }

    struct ScreenProfile {
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

    /// One machine model: a preset, one GPU (nil on Linux, whose WebGL stays the host's) and the
    /// memory, CPU, screen, font and posture values such a machine actually ships with. A whole
    /// identity is derived from one family, so its parts always describe the same machine.
    struct MachineFamily {
        let presetID: String
        let platform: BrowserPlatform
        let gpuIndex: Int?
        let memory: [Weighted<Int>]
        let cpus: [Weighted<Int>]
        let screens: [Weighted<Int>]
        let depths: [Weighted<Int>]
        let touchPercent: Int
        let audioPercent: Int
        /// Locale catalog indices this family leans to; nil uses the shared catalog.
        let locales: [Weighted<Int>]?
        let weight: Int

        var id: String { "\(presetID)#\(gpuIndex.map(String.init) ?? "host")" }
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

    /// How common each GPU on the platform is; index into the engine table.
    private static let macGPUWeights = [70, 30]
    /// Iris Xe laptops dominate, gaming and older UHD parts are rarer.
    private static let windowsGPUWeights = [8, 10, 6, 9, 9, 7, 8, 10, 4, 8, 7, 5, 8]

    private static let memoryWeights: [Int: Int] = [8: 30, 16: 55, 32: 15]

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

    private static let windowsLocales: [Weighted<Int>] = [
        weighted(0, 40), weighted(1, 8), weighted(2, 4), weighted(3, 16), weighted(4, 12),
        weighted(5, 6), weighted(6, 4), weighted(7, 3), weighted(8, 2), weighted(9, 2),
        weighted(10, 2), weighted(11, 1),
    ]

    private static let linuxLocales: [Weighted<Int>] = [
        weighted(0, 30), weighted(4, 20), weighted(5, 6), weighted(7, 14), weighted(8, 8),
        weighted(9, 6), weighted(10, 6), weighted(11, 4), weighted(1, 2), weighted(2, 1),
        weighted(3, 4),
    ]

    private static let macScreens: [Weighted<Int>] = [
        weighted(0, 30), weighted(1, 30), weighted(2, 12), weighted(3, 13), weighted(4, 15),
    ]
    private static let windowsScreens: [Weighted<Int>] = [
        weighted(0, 50), weighted(1, 22), weighted(2, 18), weighted(3, 10),
    ]
    private static let linuxScreens: [Weighted<Int>] = [
        weighted(0, 60), weighted(1, 20), weighted(2, 20),
    ]
    private static let macDepths: [Weighted<Int>] = [weighted(24, 88), weighted(30, 12)]
    private static let flatDepths: [Weighted<Int>] = [weighted(24, 100)]

    /// Every family the sampler may draw, whichever constraints narrow it. Built once from the
    /// engine table, so an engine upgrade updates the GPUs, CPU counts and memory with it.
    private static let familyCatalog: [MachineFamily] = buildFamilies()

    private static func buildFamilies() -> [MachineFamily] {
        var families: [MachineFamily] = []
        for preset in IdentityPreset.all {
            let base = presetWeights[preset.id] ?? 1
            switch preset.platform {
            case .macOS:
                // M4 machines ship with 16 or 32 GB, the base M2 with 8 or 16 GB.
                for (index, gpu) in EngineHardwareTable.bundled.macOS.enumerated() {
                    families.append(MachineFamily(
                        presetID: preset.id, platform: .macOS, gpuIndex: index,
                        memory: weightedMemory(gpu.deviceMemory), cpus: weightedCPUs(gpu.cpuCounts),
                        screens: macScreens, depths: macDepths, touchPercent: 0, audioPercent: 100,
                        locales: nil, weight: base * (index < macGPUWeights.count ? macGPUWeights[index] : 1)))
                }
            case .windows:
                for (index, gpu) in EngineHardwareTable.bundled.windows.enumerated() {
                    families.append(MachineFamily(
                        presetID: preset.id, platform: .windows, gpuIndex: index,
                        memory: weightedMemory(gpu.deviceMemory), cpus: weightedCPUs(gpu.cpuCounts),
                        screens: windowsScreens, depths: flatDepths, touchPercent: 14, audioPercent: 62,
                        locales: windowsLocales,
                        weight: base * (index < windowsGPUWeights.count ? windowsGPUWeights[index] : 1)))
                }
            case .linux:
                families.append(MachineFamily(
                    presetID: preset.id, platform: .linux, gpuIndex: nil,
                    memory: [weighted(8, 55), weighted(16, 35), weighted(32, 10)],
                    cpus: [weighted(4, 40), weighted(8, 60)],
                    screens: linuxScreens, depths: flatDepths, touchPercent: 7, audioPercent: 45,
                    locales: linuxLocales, weight: base))
            }
        }
        return families
    }

    private static func weighted(_ value: Int, _ weight: Int) -> Weighted<Int> {
        Weighted(value: value, weight: weight)
    }

    private static func weightedMemory(_ values: [Int]) -> [Weighted<Int>] {
        values.map { Weighted(value: $0, weight: memoryWeights[$0] ?? 10) }
    }

    /// The first CPU count of a GPU is the one its machines ship with most; later ones are rarer.
    private static func weightedCPUs(_ values: [Int]) -> [Weighted<Int>] {
        let weights = [55, 30, 15]
        return values.enumerated().map {
            Weighted(value: $0.element, weight: weights[min($0.offset, weights.count - 1)])
        }
    }

    /// Samples a whole identity. `seed` anchors the engine and is only moved when the drawn machine
    /// family needs another seed than the one passed in.
    public static func sample(seed: Int, constraints: Constraints = .init()) -> FingerprintSettings {
        sampleResult(seed: seed, constraints: constraints).fingerprint
    }

    public static func sample(seed: Int, preset: IdentityPreset?) -> FingerprintSettings {
        sample(seed: seed, constraints: .init(preset: preset))
    }

    /// Samples one whole identity: draw a family, derive every field from it, then re-draw while
    /// the identity is a duplicate or carries a blocking consistency issue. After `maximumAttempts`
    /// the platform's default family is used so the caller always gets a usable identity.
    public static func sampleResult(seed: Int, constraints: Constraints = .init()) -> SampleResult {
        let candidates = families(matching: constraints)
        var takenTriples = constraints.excluding
        var attempts = 0
        var last: FingerprintSettings?
        for _ in 0..<maximumAttempts {
            guard let drawn = chooseFamily(from: candidates) else { break }
            attempts += 1
            let fingerprint = generate(seed: seed, family: drawn, locale: constraints.locale)
            last = fingerprint
            guard !takenTriples.contains(fingerprint.identityTriple) else { continue }
            takenTriples.insert(fingerprint.identityTriple)
            guard isAcceptable(fingerprint, constraints: constraints) else { continue }
            return SampleResult(fingerprint: fingerprint, attempts: attempts,
                                usedFallback: false, familyID: drawn.id)
        }

        // The default family is a well-known machine; only duplicate triples can still push away.
        let family = defaultFamily(for: fallbackPlatform(for: constraints))
        var fallback: FingerprintSettings?
        for _ in 0..<maximumAttempts {
            let fingerprint = generate(seed: seed, family: family, locale: constraints.locale)
            fallback = fingerprint
            if !takenTriples.contains(fingerprint.identityTriple) { break }
        }
        return SampleResult(fingerprint: fallback ?? last ?? FingerprintSettings(seed: seed),
                            attempts: attempts, usedFallback: true, familyID: family.id)
    }

    /// A language/time-zone pair from the same catalog the whole-identity sampler uses.
    /// The field-level randomizer calls this so it cannot produce `zh-CN + America/New_York`.
    static func sampleLocale() -> (language: String, timeZone: String, languages: [String]) {
        let locale = choose(localeProfiles)
            ?? LocaleProfile(language: "en-US", timeZone: "America/New_York", weight: 1)
        return (locale.language, locale.timeZone, locale.languages)
    }

    // MARK: Families

    private static func families(matching constraints: Constraints) -> [MachineFamily] {
        let wanted: Set<String>
        if let preset = constraints.preset {
            wanted = [preset.id]
        } else if let ids = constraints.presets, !ids.isEmpty {
            wanted = Set(ids)
        } else if constraints.platforms != nil {
            wanted = Set(IdentityPreset.all.map(\.id))
        } else {
            wanted = Set(defaultPresetIDs)
        }
        var candidates = familyCatalog.filter { wanted.contains($0.presetID) }
        if let platforms = constraints.platforms, !platforms.isEmpty,
           candidates.contains(where: { platforms.contains($0.platform) }) {
            candidates = candidates.filter { platforms.contains($0.platform) }
        }
        return candidates
    }

    /// The weighted draw of one family from `candidates`; nil when none is allowed.
    private static func chooseFamily(from candidates: [MachineFamily]) -> MachineFamily? {
        choose(candidates.map { Weighted(value: $0, weight: $0.weight) })
    }

    /// A family of `platform` (and brand) for the field randomizer; a kept field narrows the draw.
    static func weightedFamily(platform: BrowserPlatform?, brand: BrowserBrand? = nil) -> MachineFamily? {
        let candidates = familyCatalog.filter { family in
            (platform == nil || family.platform == platform)
                && (brand == nil || preset(for: family)?.brand == brand)
        }
        return chooseFamily(from: candidates.isEmpty ? familyCatalog : candidates)
    }

    static func preset(for family: MachineFamily) -> IdentityPreset? {
        IdentityPreset.all.first { $0.id == family.presetID }
    }

    /// The family the seed's GPU belongs to on `platform`, narrowed to the identity's release line
    /// and brand; the Linux family has no GPU.
    static func family(for fingerprint: FingerprintSettings, platform: BrowserPlatform) -> MachineFamily? {
        var list = familyCatalog.filter { $0.platform == platform }
        if let major = fingerprint.platformVersion.split(separator: ".").first.map(String.init) {
            let sameLine = list.filter { family in
                preset(for: family)?.platformVersions.contains {
                    $0.split(separator: ".").first.map(String.init) == major
                } == true
            }
            if !sameLine.isEmpty { list = sameLine }
        }
        if let brand = fingerprint.brand {
            let sameBrand = list.filter { preset(for: $0)?.brand == brand }
            if !sameBrand.isEmpty { list = sameBrand }
        }
        let gpus = platform == .windows ? EngineHardwareTable.bundled.windows
            : platform == .macOS ? EngineHardwareTable.bundled.macOS : []
        let index = gpus.isEmpty ? nil : fingerprint.seed % gpus.count
        return list.first { $0.gpuIndex == index } ?? list.first
    }

    /// The most common family of a platform, used when every attempt was rejected.
    private static func defaultFamily(for platform: BrowserPlatform) -> MachineFamily {
        familyCatalog.filter { $0.platform == platform }.max { $0.weight < $1.weight }
            ?? familyCatalog[0]
    }

    private static func fallbackPlatform(for constraints: Constraints) -> BrowserPlatform {
        if let preset = constraints.preset { return preset.platform }
        if let platforms = constraints.platforms, let first = platforms.first { return first }
        if let ids = constraints.presets,
           let match = IdentityPreset.all.first(where: { ids.contains($0.id) }) { return match.platform }
        return .macOS
    }

    // MARK: Generation

    private static func generate(seed: Int, family: MachineFamily,
                                 locale: LocaleHint?) -> FingerprintSettings {
        let preset = preset(for: family)
        let memory = choose(family.memory) ?? EngineHardwareTable.bundled.deviceMemory(seed: seed)
        var fingerprint = FingerprintSettings(
            seed: newSeed(for: family, memory: memory, excluding: [], preferring: seed))
        fingerprint.platform = family.platform
        fingerprint.platformVersion = preset?.platformVersions.randomElement() ?? ""
        fingerprint.brand = preset?.brand
        fingerprint.deviceMemory = EngineHardwareTable.bundled.deviceMemory(seed: fingerprint.seed)
        fingerprint.cpuCount = randomCPU(for: family)
        applyRandomScreen(to: &fingerprint, family: family)
        fingerprint.fontProfile = fontCandidates(for: family.presetID).randomElement()
            ?? FontProfile.default(for: family.platform)
        // Touch screens are rare on laptops; macOS never has one.
        fingerprint.touch = family.touchPercent > 0
            && Int.random(in: 0..<100) < family.touchPercent

        let chosen: LocaleProfile
        if let locales = family.locales, let index = choose(locales),
           localeProfiles.indices.contains(index) {
            chosen = localeProfiles[index].value
        } else {
            chosen = choose(localeProfiles)
                ?? LocaleProfile(language: "en-US", timeZone: "America/New_York", weight: 1)
        }
        fingerprint.language = locale?.language ?? chosen.language
        fingerprint.languages = locale?.languages ?? chosen.languages
        fingerprint.timeZone = locale?.timeZone ?? chosen.timeZone

        var adjustments: Set<FingerprintAdjustment> = [.canvas, .clientRects, .font]
        if Int.random(in: 0..<100) < family.audioPercent { adjustments.insert(.audio) }
        if family.platform != .linux { adjustments.insert(.gpu) }
        fingerprint.adjustments = adjustments
        fingerprint.adaptToPlatform()
        return fingerprint
    }

    private static func isAcceptable(_ fingerprint: FingerprintSettings, constraints: Constraints) -> Bool {
        if let accepting = constraints.accepting, !accepting(fingerprint) { return false }
        let profile = BrowserProfile(name: "Sample", port: 9301, fingerprint: fingerprint)
        return !profile.consistencyIssues(engineVersion: BundledVersions.engine, exit: nil)
            .contains(where: \.isBlocking)
    }

    // MARK: Hardware

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

    /// A memory value of the family, used when the randomizer moves the memory.
    static func randomMemory(for family: MachineFamily) -> Int? {
        choose(family.memory)
    }

    /// A CPU count of the family, used when the randomizer moves the CPU.
    static func randomCPU(for family: MachineFamily) -> Int? {
        choose(family.cpus)
    }

    /// A seed the engine maps to `family`'s GPU and `memory`, avoiding `seeds`. The seed's GPU is
    /// `seed % count` and its memory `[8, 16, 32][seed % 3]`, so both are fixed over a period.
    /// `preferring` is kept when it already fits.
    static func newSeed(for family: MachineFamily?, memory: Int, excluding seeds: Set<Int>,
                        preferring candidate: Int? = nil) -> Int {
        guard let family else { return FingerprintSettings.newSeed(excluding: seeds) }
        let table = EngineHardwareTable.bundled
        let memoryIndex = table.deviceMemoryValues.firstIndex(of: memory) ?? memory % table.deviceMemoryValues.count
        let gpuCount = family.platform == .windows ? table.windows.count
            : family.platform == .macOS ? table.macOS.count : 1
        let period = lcm(gpuCount, table.deviceMemoryValues.count)
        // The residue class that satisfies both congruences; all seeds in it fit by construction.
        var residue = -1
        for value in 0..<period {
            if (family.gpuIndex == nil || value % gpuCount == family.gpuIndex!),
               value % table.deviceMemoryValues.count == memoryIndex {
                residue = value
                break
            }
        }
        guard residue >= 0 else { return FingerprintSettings.newSeed(excluding: seeds) }
        func free(_ value: Int) -> Bool {
            value >= 1 && !seeds.contains(value)
                && (family.platform != .macOS || table.macOSSeedExists(value))
        }
        if let candidate, candidate % period == residue, free(candidate) { return candidate }
        let steps = (Int(Int32.max) - residue) / period
        var last = max(1, residue == 0 ? period : residue)
        for _ in 0..<128 {
            let value = Int.random(in: 0...steps) * period + residue
            last = value
            if free(value) { return value }
        }
        return last
    }

    private static func lcm(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return a / x * b
    }

    /// A preset drawn with the shared weights from those `accepts` allows; all presets when none is allowed.
    static func weightedPreset(where accepts: (IdentityPreset) -> Bool) -> IdentityPreset {
        let candidates = IdentityPreset.all.filter(accepts)
        let weighted = (candidates.isEmpty ? IdentityPreset.all : candidates)
            .map { Weighted(value: $0, weight: presetWeights[$0.id] ?? 1) }
        return choose(weighted) ?? IdentityPreset.all.first { $0.id == "macos26-chrome" }!
    }

    private static func screenProfiles(for platform: BrowserPlatform) -> [Weighted<ScreenProfile>] {
        switch platform {
        case .macOS:
            return [
                screen(1512, 982, 1512, 945, 24, 2, 30),
                screen(1728, 1117, 1728, 1080, 24, 2, 30),
                screen(2560, 1440, 2560, 1410, 24, 2, 12),
                screen(1440, 900, 1440, 875, 24, 2, 13),
                // An external 1080p display on a Mac.
                screen(1920, 1080, 1920, 1055, 24, 2, 15),
            ]
        case .windows:
            return [
                screen(1920, 1080, 1920, 1040, 24, 1, 50),
                screen(1536, 864, 1536, 824, 24, 1.25, 22),
                screen(2560, 1440, 2560, 1400, 24, 1, 18),
                screen(1366, 768, 1366, 728, 24, 1, 10),
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
    /// same coherent display a sampled one would, from the family the seed selects.
    static func applyScreen(to fingerprint: inout FingerprintSettings, for platform: BrowserPlatform) {
        // A screen from another platform's catalogue does not fit the new one.
        let widths = Set(screenProfiles(for: platform).map(\.value.width))
        if let width = fingerprint.screenWidth, widths.contains(width) { return }
        guard let family = family(for: fingerprint, platform: platform) else { return }
        applyRandomScreen(to: &fingerprint, family: family)
    }

    /// Draws one of the family's screens, so a re-randomized screen stays on the same machine.
    static func applyRandomScreen(to fingerprint: inout FingerprintSettings, for platform: BrowserPlatform) {
        guard let family = family(for: fingerprint, platform: platform) else { return }
        applyRandomScreen(to: &fingerprint, family: family)
    }

    static func applyRandomScreen(to fingerprint: inout FingerprintSettings, family: MachineFamily) {
        let profiles = screenProfiles(for: family.platform)
        guard let index = choose(family.screens), profiles.indices.contains(index) else { return }
        let screen = profiles[index].value
        fingerprint.screenWidth = screen.width
        fingerprint.screenHeight = screen.height
        fingerprint.availWidth = screen.availWidth
        fingerprint.availHeight = screen.availHeight
        fingerprint.colorDepth = choose(family.depths) ?? screen.colorDepth
        fingerprint.deviceScaleFactor = screen.scale
    }

    /// The font sets that fit a preset's release line.
    static func fontCandidates(for presetID: String) -> [FontProfile] {
        switch presetID {
        case "macos27-chrome", "macos26-chrome": return [.macos26]
        case "macos15-chrome": return [.macos15]
        case "win11-chrome", "win11-edge": return [.windows11]
        case "win10-chrome": return [.windows10]
        case "linux-chrome": return [.linux68]
        default: return []
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