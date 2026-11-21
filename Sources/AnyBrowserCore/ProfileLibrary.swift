import Foundation

/// Profile import and export, cloning, batch creation and sidebar arrangement.
public enum ProfileLibrary {
    public static let format = "anybrowser-profiles"
    public static let version = 1
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
    }

    public struct BatchRequest: Sendable {
        public var count: Int
        public var prefix: String
        public var group: String
        public var preset: IdentityPreset?
        public var proxy: String

        public init(count: Int, prefix: String = "Profile", group: String = "", preset: IdentityPreset? = nil,
                    proxy: String = BrowserProfile.defaultProxy) {
            self.count = count
            self.prefix = prefix
            self.group = group
            self.preset = preset
            self.proxy = proxy
        }
    }

    // MARK: Export and import

    /// The export file. Without secrets, proxy credentials and per-Profile Passkey Box accounts are dropped.
    public static func export(_ profiles: [BrowserProfile], includeSecrets: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let entries = includeSecrets ? profiles : profiles.map(withoutSecrets)
        return try encoder.encode(Envelope(format: format, version: version, profiles: entries))
    }

    public static func withoutSecrets(_ profile: BrowserProfile) -> BrowserProfile {
        var value = profile
        // An address that does not parse cannot be shown to be free of credentials.
        value.proxy = (try? ProxyEndpoint.parse(profile.proxy))?.map(\.server) ?? ""
        value.passkeyBox = nil
        return value
    }

    /// New Profiles from an export file: each gets a new id, and a new port or seed when it collides
    /// with `takenPorts`/`takenSeeds` or an earlier entry. Entries that fail validation are skipped.
    public static func importProfiles(from data: Data, takenPorts: Set<Int>, takenSeeds: Set<Int>) throws -> ImportResult {
        guard data.count <= maxImportBytes else {
            throw ProfileError.invalid("文件过大，不是 AnyBrowser 导出的 Profile 文件。")
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == format else {
            throw ProfileError.invalid("不是 AnyBrowser 导出的 Profile 文件。")
        }
        guard header.version == version else {
            throw ProfileError.invalid("不支持此版本的 Profile 文件（版本 \(header.version.map(String.init) ?? "未知")）。")
        }
        guard let entries = try? JSONDecoder().decode(Entries.self, from: data).profiles else {
            throw ProfileError.invalid("Profile 文件缺少 Profile 列表。")
        }
        var ports = takenPorts
        var seeds = takenSeeds
        var result = ImportResult(profiles: [], skipped: 0)
        for entry in entries {
            guard var profile = try? entry.value?.validated() else {
                result.skipped += 1
                continue
            }
            profile.id = UUID()
            if ports.contains(profile.port) {
                guard let port = try? freePort(excluding: ports) else {
                    result.skipped += 1
                    continue
                }
                profile.port = port
            }
            if seeds.contains(profile.fingerprint.seed) {
                profile.fingerprint.seed = FingerprintSettings.newSeed(excluding: seeds)
            }
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

    /// A copy of a saved Profile with a new id, name, port and seed; everything else is kept.
    public static func clone(_ profile: BrowserProfile, existingNames: Set<String>,
                             takenPorts: Set<Int>, takenSeeds: Set<Int>) throws -> BrowserProfile {
        var copy = profile
        copy.id = UUID()
        copy.name = copyName(of: profile.name, existing: existingNames)
        copy.port = try freePort(excluding: takenPorts)
        copy.fingerprint.seed = FingerprintSettings.newSeed(excluding: takenSeeds)
        return try copy.validated()
    }

    /// Validated Profiles named `<prefix> <n>`, skipping names already in use.
    public static func batch(_ request: BatchRequest, existingNames: Set<String>,
                             takenPorts: Set<Int>, takenSeeds: Set<Int>) throws -> [BrowserProfile] {
        guard (1...maxBatch).contains(request.count) else {
            throw ProfileError.invalid("数量须为 1–\(maxBatch)。")
        }
        var prefix = request.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty { prefix = "Profile" }
        guard prefix.count <= 70 else { throw ProfileError.invalid("名称前缀最多 70 个字符。") }
        var names = existingNames
        var ports = takenPorts
        var seeds = takenSeeds
        var index = 0
        var result: [BrowserProfile] = []
        for _ in 0..<request.count {
            repeat { index += 1 } while names.contains("\(prefix) \(index)")
            var fingerprint = FingerprintSettings(seed: FingerprintSettings.newSeed(excluding: seeds))
            request.preset?.apply(to: &fingerprint)
            let profile = try BrowserProfile(name: "\(prefix) \(index)", port: freePort(excluding: ports),
                                             fingerprint: fingerprint, proxy: request.proxy,
                                             group: request.group).validated()
            names.insert(profile.name)
            ports.insert(profile.port)
            seeds.insert(profile.fingerprint.seed)
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

    // MARK: Sidebar

    /// Whether the name, group, notes or debug port contains `query`.
    public static func matches(_ profile: BrowserProfile, query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        return [profile.name, profile.group, profile.notes, String(profile.port)]
            .contains { $0.range(of: text, options: options) != nil }
    }

    /// Matching Profiles in sections ordered by group name, with Profiles without a group last.
    public static func sections(_ profiles: [BrowserProfile], query: String, sort: Sort,
                                lastLaunched: [UUID: Date]) -> [Section] {
        let ordered = sorted(profiles.filter { matches($0, query: query) }, by: sort, lastLaunched: lastLaunched)
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
        var profiles: [BrowserProfile]
    }

    private struct Header: Decodable {
        var format: String
        var version: Int?
    }

    private struct Entries: Decodable {
        var profiles: [Entry]
    }

    /// One entry of the list; nil when it is not a Profile, so a bad entry does not reject the file.
    private struct Entry: Decodable {
        var value: BrowserProfile?

        init(from decoder: Decoder) throws {
            value = try? BrowserProfile(from: decoder)
        }
    }
}

extension ProfileStore {
    /// Saves Profiles read from an export file and returns them with the number of skipped entries.
    public func importProfiles(from data: Data) throws -> ProfileLibrary.ImportResult {
        let plan = try ProfileLibrary.importProfiles(from: data, takenPorts: takenPorts, takenSeeds: takenSeeds)
        var result = ProfileLibrary.ImportResult(profiles: [], skipped: plan.skipped)
        for profile in plan.profiles {
            do {
                try save(profile)
                result.profiles.append(profile)
            } catch {
                result.skipped += 1
            }
        }
        return result
    }

    /// Saves a copy of a saved Profile; browser data is not copied.
    public func saveClone(of id: UUID) throws -> BrowserProfile {
        guard let original = profiles.first(where: { $0.id == id }) else {
            throw ProfileError.invalid("找不到要复制的 Profile。")
        }
        let copy = try ProfileLibrary.clone(original, existingNames: Set(profiles.map(\.name)),
                                            takenPorts: takenPorts, takenSeeds: takenSeeds)
        try save(copy)
        return copy
    }

    /// Validates every new Profile first, then saves them in order.
    public func saveBatch(_ request: ProfileLibrary.BatchRequest) throws -> [BrowserProfile] {
        let batch = try ProfileLibrary.batch(request, existingNames: Set(profiles.map(\.name)),
                                             takenPorts: takenPorts, takenSeeds: takenSeeds)
        for profile in batch { try save(profile) }
        return batch
    }
}
