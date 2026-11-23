import Foundation

/// The display and font a Profile presents, hashed as one key: two Profiles that share it look
/// alike to a page even when their seeds differ, while sharing only the screen or only the font
/// says little. A Profile that claims neither shares the host display and fonts and is not compared.
public struct ScreenFontCombination: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var scale: Double?
    public var font: FontProfile?

    /// nil when the fingerprint claims neither a display nor a font.
    public init?(_ fingerprint: FingerprintSettings) {
        guard fingerprint.screenWidth != nil || fingerprint.screenHeight != nil
                || fingerprint.deviceScaleFactor != nil || fingerprint.fontProfile != nil else { return nil }
        width = fingerprint.screenWidth ?? 0
        height = fingerprint.screenHeight ?? 0
        scale = fingerprint.deviceScaleFactor
        font = fingerprint.fontProfile
    }

    /// The one combination as a set, or the empty set.
    public static func set(_ combination: ScreenFontCombination?) -> Set<Self> {
        combination.map { [$0] } ?? []
    }
}

/// Profile import and export, cloning, batch creation and sidebar arrangement.
public enum ProfileLibrary {
    public static let format = "anybrowser-profiles"
    /// Version 2 adds the export time and app version; its Profiles carry tags and status.
    /// Version 1 files read the same way, without those fields.
    public static let version = 2
    static let readableVersions: ClosedRange<Int> = 1...2
    static let maxNameLength = 80
    public static let maxBatch = 50
    static let maxImportBytes = 16 << 20

    public enum Sort: String, CaseIterable, Sendable {
        case created, name, recent

        public var title: String {
            switch self {
            case .created: return "创建顺序"
            case .name: return "名称"
            case .recent: return "最近启动"
            }
        }
    }

    /// Profiles of one group; `group` is empty for Profiles without one.
    public struct Section: Equatable, Sendable {
        public var group: String
        public var profiles: [BrowserProfile]
    }

    public struct ImportResult: Equatable, Sendable {
        public var profiles: [BrowserProfile]
        public var skipped: Int
        /// "第 <n> 条：<reason>" for each skipped entry, in file order.
        public var skippedReasons: [String] = []
        /// "第 <n> 条：<reason>" for imported entries that could not get a fresh display and font.
        public var warnings: [String] = []
    }

    public struct BatchRequest: Sendable {
        public var count: Int
        public var prefix: String
        public var group: String
        public var preset: IdentityPreset?
        public var proxy: String
        /// Locale taken from the shared proxy exit; nil means each Profile samples its own.
        public var locale: IdentitySampler.LocaleHint?

        public init(count: Int, prefix: String = "Profile", group: String = "", preset: IdentityPreset? = nil,
                    proxy: String = BrowserProfile.defaultProxy, locale: IdentitySampler.LocaleHint? = nil) {
            self.count = count
            self.prefix = prefix
            self.group = group
            self.preset = preset
            self.proxy = proxy
            self.locale = locale
        }
    }

    // MARK: Export and import

    /// The export file holding exactly `profiles`, in order, so any selection can be exported.
    /// Without secrets, proxy credentials and per-Profile Passkey Box accounts are dropped.
    public static func export(_ profiles: [BrowserProfile], includeSecrets: Bool, exportedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let entries = includeSecrets ? profiles : profiles.map(withoutSecrets)
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return try encoder.encode(Envelope(format: format, version: version, exportedAt: exportedAt,
                                           appVersion: app, profiles: entries))
    }

    public static func withoutSecrets(_ profile: BrowserProfile) -> BrowserProfile {
        var value = profile
        // An address that does not parse cannot be shown to be free of credentials.
        value.proxy = (try? ProxyEndpoint.parse(profile.proxy))?.map(\.server) ?? ""
        value.passkeyBox = nil
        return value
    }

    /// A copy must not inherit the original's device: the id goes, the memory follows the seed the
    /// copy ends up with, and the display and font move away from `combinations`. A combination that
    /// cannot be avoided is returned as a warning instead. Call after the id or seed was reassigned.
    @discardableResult
    static func renewDevice(in profile: inout BrowserProfile, excluding combinations: Set<ScreenFontCombination>,
                            seeds: Set<Int> = []) -> String? {
        profile.deviceIdentity = nil
        // A Profile that records no memory keeps it unset; one that does follows the new seed.
        if profile.fingerprint.deviceMemory != nil {
            profile.fingerprint.deviceMemory = EngineHardwareTable.bundled.deviceMemory(seed: profile.fingerprint.seed)
        }
        var used = seeds
        for round in 0..<combinationRounds {
            if round > 0 {
                // Every display and font is in use for now: another seed moves the rest of the
                // device as well, then the draw is tried again.
                used.insert(profile.fingerprint.seed)
                // The same hardware keeps the CPU count, which the seed's GPU has to match.
                profile.fingerprint.seed = FingerprintSettings.newSeed(excluding: used,
                                                                       sameHardwareAs: profile.fingerprint.seed)
                if profile.fingerprint.deviceMemory != nil {
                    profile.fingerprint.deviceMemory = EngineHardwareTable.bundled.deviceMemory(seed: profile.fingerprint.seed)
                }
            }
            if freshCombination(in: &profile.fingerprint, excluding: combinations) { return nil }
        }
        return exhaustedCombinations
    }

    static let exhaustedCombinations = "屏幕与字体组合已用尽，只能与已有 Profile 相同。"

    /// Displays a draw tries before the catalogue is taken as used up. The smallest catalogue has
    /// three entries, the rarest of which a draw misses well under once in a hundred times.
    static let combinationDraws = 256
    /// How often the seed is changed and the draw tried again.
    static let combinationRounds = 3

    /// Replaces `fingerprint`'s display and font with a combination outside `taken`, when one is
    /// free; false when all are taken and the drawn one repeats. The platform version follows a
    /// font that changed, because validation derives the font from it.
    @discardableResult
    public static func freshCombination(in fingerprint: inout FingerprintSettings,
                                 excluding taken: Set<ScreenFontCombination>) -> Bool {
        // A Profile without a platform shares the host Mac's display and claims no font.
        let platform = fingerprint.platform ?? .macOS
        let fonts = Self.fonts(for: platform, claimed: fingerprint.platform != nil)
        let (drawn, isFree) = drawDisplay(for: platform, fonts: fonts, excluding: taken)
        fingerprint.screenWidth = drawn.screenWidth
        fingerprint.screenHeight = drawn.screenHeight
        fingerprint.availWidth = drawn.availWidth
        fingerprint.availHeight = drawn.availHeight
        fingerprint.colorDepth = drawn.colorDepth
        fingerprint.deviceScaleFactor = drawn.deviceScaleFactor
        fingerprint.fontProfile = drawn.fontProfile
        if let platform = fingerprint.platform, let font = drawn.fontProfile {
            fingerprint.platformVersion = version(of: fingerprint.platformVersion, for: font, on: platform)
        }
        return isFree
    }

    /// The fonts `platform` can show; nil alone for a Profile that claims none.
    static func fonts(for platform: BrowserPlatform, claimed: Bool) -> [FontProfile?] {
        claimed ? FontProfile.allCases.filter { $0.platform == platform } : [nil]
    }

    /// Whether `taken` leaves any display and font free for `platform`.
    static func hasFreeCombination(for platform: BrowserPlatform, fonts: [FontProfile?],
                                   excluding taken: Set<ScreenFontCombination>) -> Bool {
        drawDisplay(for: platform, fonts: fonts, excluding: taken).isFree
    }

    /// One random display and font for `platform` outside `taken`, with whether a free one was
    /// found. When every combination is taken the last draw is still returned, so the caller has
    /// a usable display.
    private static func drawDisplay(for platform: BrowserPlatform, fonts: [FontProfile?],
                                    excluding taken: Set<ScreenFontCombination>) -> (fingerprint: FingerprintSettings, isFree: Bool) {
        var last: FingerprintSettings?
        for _ in 0..<combinationDraws {
            var probe = FingerprintSettings(seed: 1)
            probe.fontProfile = fonts.randomElement() ?? nil
            IdentitySampler.applyScreen(to: &probe, for: platform)
            if let combination = ScreenFontCombination(probe), !taken.contains(combination) {
                return (probe, true)
            }
            last = probe
        }
        return (last ?? FingerprintSettings(seed: 1), false)
    }

    /// `version` unless validation would derive another font than `font` from it.
    private static func version(of version: String, for font: FontProfile, on platform: BrowserPlatform) -> String {
        guard FontProfile.default(for: platform, version: version) != font else { return version }
        switch platform {
        case .macOS: return font == .macos15 ? "15.0.0" : "26.0.0"
        case .windows: return font == .windows10 ? "10.0.0" : "19.0.0"
        case .linux: return version
        }
    }

    /// New Profiles from an export file: each gets a new id, and a new port or seed when it collides
    /// with `takenPorts`/`takenSeeds`, an earlier entry or `takenCombinations`. Entries that fail
    /// validation are skipped with the reason; a display and font that cannot be avoided is reported
    /// in `warnings` instead.
    public static func importProfiles(from data: Data, takenPorts: Set<Int>, takenSeeds: Set<Int>,
                                      takenCombinations: Set<ScreenFontCombination> = []) throws -> ImportResult {
        guard data.count <= maxImportBytes else {
            throw ProfileError.invalid("文件过大，不是 AnyBrowser 导出的 Profile 文件。")
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == format else {
            throw ProfileError.invalid("不是 AnyBrowser 导出的 Profile 文件。")
        }
        guard let fileVersion = header.version, readableVersions.contains(fileVersion) else {
            let newer = (header.version ?? 0) > version ? "，请升级 AnyBrowser 后再导入" : ""
            throw ProfileError.invalid("不支持此版本的 Profile 文件（版本 \(header.version.map(String.init) ?? "未知")）\(newer)。")
        }
        guard let entries = try? JSONDecoder().decode(Entries.self, from: data).profiles else {
            throw ProfileError.invalid("Profile 文件缺少 Profile 列表。")
        }
        var ports = takenPorts
        var seeds = takenSeeds
        var combinations = takenCombinations
        var result = ImportResult(profiles: [], skipped: 0)
        func skip(_ index: Int, _ reason: String) {
            result.skipped += 1
            result.skippedReasons.append("第 \(index + 1) 条：\(reason)")
        }
        for (index, entry) in entries.enumerated() {
            var profile: BrowserProfile
            switch entry.value {
            case .success(let value):
                do {
                    profile = try value.validated()
                } catch {
                    skip(index, error.localizedDescription)
                    continue
                }
            case .failure(let error):
                skip(index, ProfileStore.readFailure(error, below: entry.path.count))
                continue
            }
            profile.id = UUID()
            if ports.contains(profile.port) {
                guard let port = try? freePort(excluding: ports) else {
                    skip(index, "没有可分配的调试端口。")
                    continue
                }
                profile.port = port
            }
            if seeds.contains(profile.fingerprint.seed) {
                profile.fingerprint.seed = FingerprintSettings.newSeed(excluding: seeds,
                                                                       sameHardwareAs: profile.fingerprint.seed)
            }
            if let warning = renewDevice(in: &profile, excluding: combinations, seeds: seeds) {
                result.warnings.append("第 \(index + 1) 条：\(warning)")
            }
            combinations.formUnion(ScreenFontCombination.set(ScreenFontCombination(profile.fingerprint)))
            ports.insert(profile.port)
            seeds.insert(profile.fingerprint.seed)
            result.profiles.append(profile)
        }
        return result
    }

    /// Reads a file chosen for import without loading more than an export can hold.
    public static func contents(of url: URL) throws -> Data {
        try PrivateFile.read(url, limit: maxImportBytes, failure: "无法读取文件「\(url.lastPathComponent)」。")
    }

    /// Writes an export only the current user can read, replacing any file at `url`.
    public static func writePrivately(_ data: Data, to url: URL) throws {
        try PrivateFile.write(data, to: url, failure: "无法写入文件「\(url.lastPathComponent)」。")
    }

    // MARK: New Profiles

    /// A copy of a saved Profile with a new id, name, port, seed, display and font; everything else
    /// is kept.
    public static func clone(_ profile: BrowserProfile, existingNames: Set<String>,
                             takenPorts: Set<Int>, takenSeeds: Set<Int>,
                             takenCombinations: Set<ScreenFontCombination> = []) throws -> BrowserProfile {
        var copy = profile
        copy.id = UUID()
        copy.name = copyName(of: profile.name, existing: existingNames)
        copy.port = try freePort(excluding: takenPorts)
        copy.fingerprint.seed = FingerprintSettings.newSeed(excluding: takenSeeds, sameHardwareAs: profile.fingerprint.seed)
        // A copy with the same device id would look like the same device to Stripe.
        renewDevice(in: &copy, excluding: takenCombinations.union(ScreenFontCombination.set(ScreenFontCombination(profile.fingerprint))),
                    seeds: takenSeeds)
        copy.deviceIdentity = DeviceIdentity.mint()
        return try copy.validated()
    }

    /// Validated Profiles named `<prefix> <n>`, skipping names already in use and moving each off
    /// the ports, seeds and display and font combinations taken here or by an earlier Profile.
    public static func batch(_ request: BatchRequest, existingNames: Set<String>,
                             takenPorts: Set<Int>, takenSeeds: Set<Int>,
                             takenCombinations: Set<ScreenFontCombination> = []) throws -> [BrowserProfile] {
        guard (1...maxBatch).contains(request.count) else {
            throw ProfileError.invalid("数量须为 1–\(maxBatch)。")
        }
        var prefix = request.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty { prefix = "Profile" }
        guard prefix.count <= 70 else { throw ProfileError.invalid("名称前缀最多 70 个字符。") }
        var names = existingNames
        var ports = takenPorts
        var seeds = takenSeeds
        var combinations = takenCombinations
        var index = 0
        var result: [BrowserProfile] = []
        for _ in 0..<request.count {
            repeat { index += 1 } while names.contains("\(prefix) \(index)")
            // Every Profile in a batch gets its own bundle, not one preset copied N times.
            var fingerprint = IdentitySampler.sample(
                seed: FingerprintSettings.newSeed(excluding: seeds),
                constraints: .init(preset: request.preset, locale: request.locale))
            freshCombination(in: &fingerprint, excluding: combinations)
            let profile = try BrowserProfile(name: "\(prefix) \(index)", port: freePort(excluding: ports),
                                             fingerprint: fingerprint, proxy: request.proxy,
                                             group: request.group).validated()
            names.insert(profile.name)
            ports.insert(profile.port)
            seeds.insert(profile.fingerprint.seed)
            combinations.formUnion(ScreenFontCombination.set(ScreenFontCombination(profile.fingerprint)))
            result.append(profile)
        }
        return result
    }

    static func freePort(excluding ports: Set<Int>) throws -> Int {
        guard let port = (9222...65535).first(where: { !ports.contains($0) })
                ?? (1024..<9222).first(where: { !ports.contains($0) }) else {
            throw ProfileError.invalid("没有可分配的调试端口。")
        }
        return port
    }

    static func copyName(of name: String, existing: Set<String>) -> String {
        var index = 1
        while true {
            let suffix = index == 1 ? " 副本" : " 副本 \(index)"
            let stem = String(name.prefix(maxNameLength - suffix.count)).trimmingCharacters(in: .whitespaces)
            let candidate = stem + suffix
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }

    /// What an import brings in beyond fingerprints and names, worth a look when the file comes
    /// from someone else; nil when there is nothing of the kind.
    public static func importReview(_ profiles: [BrowserProfile]) -> String? {
        let accounts = profiles.compactMap(\.passkeyBox)
        let hosts = Set(accounts.compactMap { URLComponents(string: $0.serverURL)?.host }).sorted()
        let defaultProxy = try? ProxyEndpoint.parse(BrowserProfile.defaultProxy)
        let extensions = profiles.filter { !$0.launch.extensionDirectories.isEmpty }.count
        let startPages = profiles.filter { !$0.launch.startURLs.isEmpty }.count
        // No proxy at all is not counted: only an address someone else chose routes the traffic.
        let proxies = profiles.filter { profile in
            guard let endpoint = try? ProxyEndpoint.parse(profile.proxy) else { return false }
            return endpoint != defaultProxy
        }.count
        let counts: [(count: Int, text: String)] = [
            (accounts.count, "使用单独的 Passkey Box 账号（\(hosts.joined(separator: "、"))）"),
            (extensions, "加载额外扩展"),
            (startPages, "设置了启动网址"),
            (proxies, "使用其他代理"),
        ]
        let present = counts.filter { $0.count > 0 }.map { "\($0.count) 个\($0.text)" }
        guard !present.isEmpty else { return nil }
        return "其中 \(present.joined(separator: "，"))。请确认文件来源可信，必要时在编辑器里检查。"
    }

    // MARK: Batch actions

    /// Why a Profile cannot be removed right now, or nil when it can.
    public static func removalBlocker(state: BrowserRunState, busy: Bool, batchRunning: Bool) -> String? {
        if batchRunning { return "批量操作进行中，完成后再移除 Profile。" }
        if busy { return "该 Profile 正在执行另一个操作，请稍后再移除。" }
        switch state {
        case .running, .starting, .stopping: return "请先停止此 Profile 的浏览器，再移除。"
        case .stopped, .failed: return nil
        }
    }

    public struct BatchOutcome: Equatable, Sendable {
        public var succeeded = 0
        public var skipped = 0
        /// "<name>：<reason>" per Profile.
        public var failures: [String] = []
        public var warnings: [String] = []

        public init() {}

        /// One notice for the whole batch, e.g. "已启动 2 个 Profile，跳过 1 个。"
        public func summary(verb: String) -> String {
            var text = "已\(verb) \(succeeded) 个 Profile"
            if skipped > 0 { text += "，跳过 \(skipped) 个" }
            text += "。"
            if !failures.isEmpty { text += "\(failures.count) 个未能\(verb)：\(failures.joined(separator: "；"))。" }
            if !warnings.isEmpty { text += "提醒：\(warnings.joined(separator: "；"))" }
            return text
        }
    }

    // MARK: Sidebar

    /// A sidebar search. `tag:`, `status:` and `group:` terms (quoted when the value has spaces)
    /// each narrow the result; the rest of the text must appear in the name, group, notes, debug
    /// port or a tag. A status matches by its raw value or its Chinese title.
    struct Query {
        private(set) var text: String
        private(set) var tags: [String] = []
        private(set) var statuses: [String] = []
        private(set) var groups: [String] = []
        private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

        init(_ query: String) {
            text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var words: [String] = []
            var found = false
            for word in Self.words(text) {
                // The full-width colon is what Chinese input methods type.
                let parts = word.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "：" })
                let value = parts.count == 2 ? String(parts[1]).replacingOccurrences(of: "\"", with: "") : ""
                switch parts.count == 2 ? parts[0].lowercased() : nil {
                case "tag": tags.append(value)
                case "status": statuses.append(value)
                case "group": groups.append(value)
                default:
                    words.append(word)
                    continue
                }
                found = true
            }
            // Without terms the text is matched as typed, spaces included.
            if found { text = words.joined(separator: " ") }
            tags.removeAll(where: \.isEmpty)
            statuses.removeAll(where: \.isEmpty)
            groups.removeAll(where: \.isEmpty)
        }

        /// Splits at spaces outside double quotes.
        private static func words(_ text: String) -> [String] {
            var words: [String] = []
            var current = ""
            var quoted = false
            for character in text {
                if character == "\"" { quoted.toggle() }
                if character.isWhitespace, !quoted {
                    if !current.isEmpty { words.append(current) }
                    current = ""
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty { words.append(current) }
            return words
        }

        private static func contains(_ value: String, _ part: String) -> Bool {
            value.range(of: part, options: options) != nil
        }

        func matches(_ profile: BrowserProfile) -> Bool {
            guard tags.allSatisfy({ tag in profile.tags.contains { Self.contains($0, tag) } }),
                  groups.allSatisfy({ Self.contains(profile.group, $0) }),
                  statuses.allSatisfy({ status in
                      profile.accountStatus.map { Self.contains($0.rawValue, status) || Self.contains($0.title, status) } ?? false
                  }) else { return false }
            guard !text.isEmpty else { return true }
            return ([profile.name, profile.group, profile.notes, String(profile.port)] + profile.tags)
                .contains { Self.contains($0, text) }
        }
    }

    /// Whether `profile` matches the sidebar search `query`; see `Query`.
    public static func matches(_ profile: BrowserProfile, query: String) -> Bool {
        Query(query).matches(profile)
    }

    /// Matching Profiles in sections ordered by group name, with Profiles without a group last.
    public static func sections(_ profiles: [BrowserProfile], query: String, sort: Sort,
                                lastLaunched: [UUID: Date]) -> [Section] {
        let search = Query(query)
        let ordered = sorted(profiles.filter(search.matches), by: sort, lastLaunched: lastLaunched)
        var groups: [String: [BrowserProfile]] = [:]
        for profile in ordered { groups[profile.group, default: []].append(profile) }
        return groups.keys
            .sorted { a, b in
                if a.isEmpty != b.isEmpty { return b.isEmpty }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            .map { Section(group: $0, profiles: groups[$0]!) }
    }

    /// Existing group names in display order.
    public static func groups(_ profiles: [BrowserProfile]) -> [String] {
        Set(profiles.map(\.group)).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func sorted(_ profiles: [BrowserProfile], by sort: Sort, lastLaunched: [UUID: Date]) -> [BrowserProfile] {
        // Indices keep creation order among equal keys.
        let indexed = Array(profiles.enumerated())
        let ordered: [(offset: Int, element: BrowserProfile)]
        switch sort {
        case .created:
            ordered = indexed
        case .name:
            ordered = indexed.sorted { a, b in
                let order = a.element.name.localizedStandardCompare(b.element.name)
                return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
            }
        case .recent:
            ordered = indexed.sorted { a, b in
                let first = lastLaunched[a.element.id] ?? .distantPast
                let second = lastLaunched[b.element.id] ?? .distantPast
                return first == second ? a.offset < b.offset : first > second
            }
        }
        return ordered.map(\.element)
    }

    private struct Envelope: Encodable {
        var format: String
        var version: Int
        var exportedAt: Date
        var appVersion: String?
        var profiles: [BrowserProfile]
    }

    private struct Header: Decodable {
        var format: String
        var version: Int?
    }

    private struct Entries: Decodable {
        var profiles: [Entry]
    }

    /// One entry of the list, or why it is not a Profile, so a bad entry does not reject the file.
    private struct Entry: Decodable {
        var value: Result<BrowserProfile, Error>
        /// Where the entry sits in the file, left out of the reason.
        var path: [CodingKey]

        init(from decoder: Decoder) throws {
            value = Result { try BrowserProfile(from: decoder) }
            path = decoder.codingPath
        }
    }
}

extension ProfileStore {
    /// Saves the Profiles read from an export file in one transaction, so a failure leaves nothing
    /// half imported, and returns them with the entries skipped and why.
    public func importProfiles(from data: Data) throws -> ProfileLibrary.ImportResult {
        try requireWritable()
        var result = try ProfileLibrary.importProfiles(from: data, takenPorts: takenPorts, takenSeeds: takenSeeds,
                                                      takenCombinations: takenScreenFontCombinations)
        result.profiles = try saveAll(result.profiles)
        return result
    }

    /// The export file for the saved Profiles in `ids`, in creation order; for exporting a selection.
    /// Ids that are not saved Profiles are left out.
    public func exportProfiles(_ ids: Set<UUID>, includeSecrets: Bool) throws -> Data {
        try ProfileLibrary.export(profiles.filter { ids.contains($0.id) }, includeSecrets: includeSecrets)
    }

    /// Saves a copy of a saved Profile; browser data is not copied.
    public func saveClone(of id: UUID) throws -> BrowserProfile {
        guard let original = profiles.first(where: { $0.id == id }) else {
            throw ProfileError.invalid("找不到要复制的 Profile。")
        }
        let copy = try ProfileLibrary.clone(original, existingNames: Set(profiles.map(\.name)),
                                            takenPorts: takenPorts, takenSeeds: takenSeeds,
                                            takenCombinations: takenScreenFontCombinations)
        try save(copy)
        return copy
    }

    /// Validates every new Profile first, then saves them all in one transaction.
    public func saveBatch(_ request: ProfileLibrary.BatchRequest) throws -> [BrowserProfile] {
        let batch = try ProfileLibrary.batch(request, existingNames: Set(profiles.map(\.name)),
                                             takenPorts: takenPorts, takenSeeds: takenSeeds,
                                             takenCombinations: takenScreenFontCombinations)
        try saveAll(batch)
        return batch
    }
}
