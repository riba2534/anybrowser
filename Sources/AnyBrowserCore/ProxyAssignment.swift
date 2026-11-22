import Foundation

/// Hands proxies from the library to Profiles created or edited together, so that each gets its
/// own exit, and looks up those exits for aligning language and time zone.
public enum ProxyAssignment {
    public enum Order: String, CaseIterable, Sendable {
        /// In library order, wrapping around when the library has fewer proxies than Profiles.
        case sequential
        /// A different proxy for each Profile, at random; fails when there are not enough.
        case randomUnique

        public var title: String {
            switch self {
            case .sequential: return "按顺序取自代理库"
            case .randomUnique: return "随机不重复"
            }
        }
    }

    /// How many of `profiles` use each entry, comparing normalized addresses.
    public static func usage(of entries: [ProxyEntry], by profiles: [BrowserProfile]) -> [UUID: Int] {
        usage(of: entries, users: users(of: profiles))
    }

    /// How many of `users` (see `users(of:)`) use each entry, leaving out the Profiles in `excluded`.
    public static func usage(of entries: [ProxyEntry], users: [String: [UUID]],
                             excluding excluded: Set<UUID> = []) -> [UUID: Int] {
        var usage: [UUID: Int] = [:]
        for entry in entries {
            let count = users[entry.url]?.filter { !excluded.contains($0) }.count ?? 0
            if count > 0 { usage[entry.id] = count }
        }
        return usage
    }

    /// The Profiles using each proxy, by normalized address, in the order of `profiles`.
    public static func users(of profiles: [BrowserProfile]) -> [String: [UUID]] {
        var users: [String: [UUID]] = [:]
        for profile in profiles {
            guard let endpoint = try? ProxyEndpoint.parse(profile.proxy, allowingSOCKSCredentials: true) else { continue }
            users[endpoint.url, default: []].append(profile.id)
        }
        return users
    }

    /// Addresses for `count` Profiles from `entries`. Entries no Profile uses yet (`usage` is zero)
    /// come first, so a second batch does not start over with the proxies the first one took;
    /// within each part the library order, or a random one, is kept. Throws when the library is
    /// empty, or for `randomUnique` when it has fewer entries than `count`.
    public static func pick<Generator: RandomNumberGenerator>(
        _ count: Int, from entries: [ProxyEntry], order: Order, usage: [UUID: Int] = [:],
        using generator: inout Generator
    ) throws -> [String] {
        guard count > 0 else { return [] }
        guard !entries.isEmpty else { throw ProfileError.invalid("代理库里没有可用的代理，请先在代理库添加。") }
        var free = entries.filter { (usage[$0.id] ?? 0) == 0 }
        var used = entries.filter { (usage[$0.id] ?? 0) > 0 }
        switch order {
        case .sequential:
            let candidates = free + used
            return (0..<count).map { candidates[$0 % candidates.count].url }
        case .randomUnique:
            guard entries.count >= count else {
                throw ProfileError.invalid("代理库只有 \(entries.count) 条代理，不够 \(count) 个 Profile 各用一条；请减少数量或改为按顺序分配。")
            }
            free.shuffle(using: &generator)
            used.shuffle(using: &generator)
            return (free + used).prefix(count).map(\.url)
        }
    }

    public static func pick(_ count: Int, from entries: [ProxyEntry], order: Order,
                            usage: [UUID: Int] = [:]) throws -> [String] {
        var generator = SystemRandomNumberGenerator()
        return try pick(count, from: entries, order: order, usage: usage, using: &generator)
    }

    /// Whether `pick` with `.sequential` hands some proxy to more than one of `count` Profiles.
    public static func repeats(_ count: Int, from entries: [ProxyEntry]) -> Bool {
        !entries.isEmpty && count > entries.count
    }

    // MARK: Exit lookups

    /// The outcome of looking up one proxy's exit.
    public enum Lookup: Equatable, Sendable {
        case found(ProxyExit)
        case failed(String)

        public var exit: ProxyExit? {
            if case .found(let exit) = self { return exit }
            return nil
        }
    }

    /// Looks up the exit of each distinct non-empty address in `proxies` (compared normalized), at
    /// most `limit` at a time, and returns the outcomes by normalized address. `progress` gets the
    /// number done and the total after each lookup, `completed` each outcome with how long the
    /// lookup took. An address that does not parse fails without a lookup.
    @MainActor
    public static func lookUpExits(_ proxies: [String], limit: Int = 4,
                                   lookup: @escaping @Sendable (ProxyEndpoint) async throws -> ProxyExit,
                                   progress: (Int, Int) -> Void = { _, _ in },
                                   completed: (String, Lookup, TimeInterval) -> Void = { _, _, _ in }) async -> [String: Lookup] {
        var endpoints: [ProxyEndpoint] = []
        var seen: Set<String> = []
        var results: [String: Lookup] = [:]
        for proxy in proxies {
            do {
                guard let endpoint = try ProxyEndpoint.parse(proxy, allowingSOCKSCredentials: true),
                      seen.insert(endpoint.url).inserted else { continue }
                endpoints.append(endpoint)
            } catch {
                results[normalized(proxy)] = .failed(error.localizedDescription)
            }
        }
        let total = endpoints.count
        progress(0, total)
        await withTaskGroup(of: (String, Lookup, TimeInterval).self) { group in
            var next = 0
            func start() {
                let endpoint = endpoints[next]
                next += 1
                group.addTask {
                    let started = ProcessInfo.processInfo.systemUptime
                    let outcome: Lookup
                    do {
                        outcome = .found(try await lookup(endpoint))
                    } catch {
                        outcome = .failed(error.localizedDescription)
                    }
                    return (endpoint.url, outcome, ProcessInfo.processInfo.systemUptime - started)
                }
            }
            while next < min(max(1, limit), total) { start() }
            var done = 0
            while let (url, outcome, duration) = await group.next() {
                results[url] = outcome
                done += 1
                completed(url, outcome, duration)
                progress(done, total)
                if next < total { start() }
            }
        }
        return results
    }

    /// The key `lookUpExits` files `proxy` under: its normalized address, or the trimmed text when
    /// it does not parse.
    public static func normalized(_ proxy: String) -> String {
        (try? ProxyEndpoint.parse(proxy, allowingSOCKSCredentials: true))?.url
            ?? proxy.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The language and time zone a Profile behind `proxy` should use: the Mac's own without a
    /// proxy, the exit's otherwise. Nil with the reason when the exit is unknown or says neither.
    public static func locale(for proxy: String, in lookups: [String: Lookup])
        -> (hint: IdentitySampler.LocaleHint?, failure: String?) {
        guard !proxy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (.host, nil) }
        switch lookups[normalized(proxy)] {
        case .found(let exit)?:
            guard let hint = IdentitySampler.LocaleHint(exit: exit) else {
                return (nil, "出口 \(exit.ip) 没有可用的时区和语言信息。")
            }
            return (hint, nil)
        case .failed(let reason)?:
            return (nil, reason)
        case nil:
            return (nil, "没有检测这个代理的出口。")
        }
    }
}

extension ProfileLibrary {
    /// Validated Profiles named `<prefix> <n>` as `batch(_:existingNames:takenPorts:takenSeeds:)`
    /// makes them, except that the i-th Profile uses `proxies[i]` and samples its identity with
    /// `locales[i]` (nil samples language and time zone freely). The request's own proxy and
    /// locale are not used.
    public static func batch(_ request: BatchRequest, proxies: [String], locales: [IdentitySampler.LocaleHint?],
                             existingNames: Set<String>, takenPorts: Set<Int>, takenSeeds: Set<Int>) throws -> [BrowserProfile] {
        guard (1...maxBatch).contains(request.count) else {
            throw ProfileError.invalid("数量须为 1–\(maxBatch)。")
        }
        guard proxies.count == request.count, locales.count == request.count else {
            throw ProfileError.invalid("代理数量与 Profile 数量不一致。")
        }
        var names = existingNames
        var ports = takenPorts
        var seeds = takenSeeds
        var result: [BrowserProfile] = []
        for index in 0..<request.count {
            var single = request
            single.count = 1
            single.proxy = proxies[index]
            single.locale = locales[index]
            let profile = try batch(single, existingNames: names, takenPorts: ports, takenSeeds: seeds)[0]
            names.insert(profile.name)
            ports.insert(profile.port)
            seeds.insert(profile.fingerprint.seed)
            result.append(profile)
        }
        return result
    }
}

extension ProfileStore {
    /// Saves a batch whose Profiles each have their own proxy and locale, all or none.
    public func saveBatch(_ request: ProfileLibrary.BatchRequest, proxies: [String],
                          locales: [IdentitySampler.LocaleHint?]) throws -> [BrowserProfile] {
        try requireWritable()
        let batch = try ProfileLibrary.batch(request, proxies: proxies, locales: locales,
                                             existingNames: Set(profiles.map(\.name)),
                                             takenPorts: takenPorts, takenSeeds: takenSeeds)
        return try saveAll(batch)
    }
}
