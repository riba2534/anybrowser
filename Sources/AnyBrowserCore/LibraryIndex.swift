import Foundation

/// What the sidebar shows, worked out again only when one of its inputs changes: the Profiles,
/// the search, the sort, the launch times or the recorded exits. The window redraws on every
/// keystroke in the editor, which changes none of them.
@MainActor
public final class LibraryIndex {
    public struct Inputs: Equatable {
        public var profiles: [BrowserProfile]
        public var query: String
        public var sort: ProfileLibrary.Sort
        public var lastLaunched: [UUID: Date]
        public var exits: [UUID: ProfileExitRecord]

        public init(profiles: [BrowserProfile], query: String, sort: ProfileLibrary.Sort,
                    lastLaunched: [UUID: Date], exits: [UUID: ProfileExitRecord] = [:]) {
            self.profiles = profiles
            self.query = query
            self.sort = sort
            self.lastLaunched = lastLaunched
            self.exits = exits
        }
    }

    public private(set) var sections: [ProfileLibrary.Section] = []
    /// The rows in the order they appear, for the arrow keys, ⇧-click and "select all".
    public private(set) var visibleIDs: [UUID] = []
    /// Group names in use, in display order.
    public private(set) var groups: [String] = []
    /// Tags in use, each once whatever its case, in display order.
    public private(set) var tags: [String] = []
    /// For each Profile whose last exit IP other Profiles share, those Profiles in store order.
    public private(set) var sharedExits: [UUID: [UUID]] = [:]
    /// How many times the sections were worked out, for tests.
    public private(set) var computations = 0
    private var inputs: Inputs?

    public init() {}

    /// Brings everything up to date with `inputs`; does nothing when they are unchanged.
    public func update(_ inputs: Inputs) {
        // Unchanged arrays and dictionaries share storage, so this is usually one pointer comparison.
        guard inputs != self.inputs else { return }
        let previous = self.inputs
        self.inputs = inputs
        computations += 1
        sections = ProfileLibrary.sections(inputs.profiles, query: inputs.query, sort: inputs.sort,
                                           lastLaunched: inputs.lastLaunched)
        visibleIDs = sections.flatMap { $0.profiles.map(\.id) }
        if previous?.profiles != inputs.profiles {
            groups = ProfileLibrary.groups(inputs.profiles)
            tags = Self.tags(inputs.profiles)
        }
        if previous?.profiles != inputs.profiles || previous?.exits != inputs.exits {
            sharedExits = Self.sharedExits(inputs.exits, among: inputs.profiles.map(\.id))
        }
    }

    static func tags(_ profiles: [BrowserProfile]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for tag in profiles.flatMap(\.tags) where seen.insert(tag.lowercased()).inserted { result.append(tag) }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Profiles grouped by the IP of their last exit, for each Profile in `ids` that shares it.
    /// Records of Profiles not in `ids` are ignored, as `ProxyLibrary.profilesSharingExit` does.
    public static func sharedExits(_ exits: [UUID: ProfileExitRecord], among ids: [UUID]) -> [UUID: [UUID]] {
        var byIP: [String: [UUID]] = [:]
        for id in ids {
            guard let ip = exits[id]?.exit.ip, !ip.isEmpty else { continue }
            byIP[ip, default: []].append(id)
        }
        var shared: [UUID: [UUID]] = [:]
        for members in byIP.values where members.count > 1 {
            for id in members { shared[id] = members.filter { $0 != id } }
        }
        return shared
    }
}

/// Keyboard and pointer selection in the sidebar. The Profile being edited and the Profiles
/// picked for batch actions stay separate, as in `LibraryModel`.
public enum LibrarySelection {
    /// The Profiles from `anchor` to `target` in `order`, both included, for a ⇧-click. Without
    /// an anchor in `order`, only `target`.
    public static func range(from anchor: UUID?, to target: UUID, in order: [UUID]) -> [UUID] {
        guard let end = order.firstIndex(of: target) else { return [] }
        guard let anchor, let start = order.firstIndex(of: anchor) else { return [target] }
        return Array(order[min(start, end)...max(start, end)])
    }

    /// The Profile one row up (`offset` -1) or down (+1) from `current`, staying at the ends.
    /// Without a current row in `order`, down starts at the top and up at the bottom.
    public static func step(from current: UUID?, by offset: Int, in order: [UUID]) -> UUID? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return offset < 0 ? order.last : order.first
        }
        return order[min(max(index + offset, 0), order.count - 1)]
    }
}

extension TrashedProfile {
    /// Whole days left before launch maintenance purges the entry, counting a started day as a
    /// day; 0 once it is due.
    public func daysRemaining(now: Date = Date(), retention days: Int = 30) -> Int {
        let left = Double(days) * 86400 - now.timeIntervalSince(deletedAt)
        return left <= 0 ? 0 : Int((left / 86400).rounded(.up))
    }
}

/// A copy of the Profile database in `Backups/`, described by its file name.
public struct DatabaseBackup: Equatable, Sendable, Identifiable {
    public var url: URL
    public var createdAt: Date
    /// The reason in the file name, e.g. `daily`.
    public var reason: String
    public var id: URL { url }

    /// Nil for a file that `ProfileStore.backup(reason:)` did not name.
    public init?(_ url: URL) {
        let name = url.lastPathComponent
        // profiles-<yyyyMMdd>-<HHmmss>-<SSS>-<reason>.sqlite3
        guard name.hasPrefix("profiles-"), name.hasSuffix(".sqlite3") else { return nil }
        let stem = name.dropFirst("profiles-".count).dropLast(".sqlite3".count)
        guard stem.count > 20, let date = Self.stamp.date(from: String(stem.prefix(19))),
              stem.dropFirst(19).first == "-" else { return nil }
        self.url = url
        createdAt = date
        reason = String(stem.dropFirst(20))
    }

    /// What made the backup, for the list.
    public var title: String {
        switch reason {
        case "daily": return "每日自动备份"
        case "upgrade": return "升级前的备份"
        case "replaced": return "恢复备份前的数据库"
        case "manual": return "手动备份"
        default: return reason
        }
    }

    private static var stamp: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }
}
