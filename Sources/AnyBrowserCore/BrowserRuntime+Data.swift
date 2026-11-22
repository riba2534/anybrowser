import Darwin
import Foundation

extension BrowserRuntime {
    /// Clears site data so a new identity does not carry the old device's.
    ///
    /// A stopped Profile loses the data files of every site: cookies, local and session storage,
    /// IndexedDB, service workers and the HTTP and code caches, including the cache directory
    /// Chromium keeps under ~/Library/Caches. It is signed out everywhere; extension storage,
    /// preferences, history and bookmarks stay. `LaunchOverrides.resetSiteData` deletes the same.
    ///
    /// A running Profile is cleared through DevTools for the payment and verification sites in
    /// `siteOrigins` only: their cookies, including domain-wide and partitioned ones and Stripe's
    /// device cookies on any site, their storage, and the whole HTTP cache. Its open pages can
    /// write data back until the browser restarts, so a new identity is better applied by stopping
    /// the browser and starting it with `resetSiteData`.
    public func clearSiteData(for id: UUID) async throws {
        try await clearSiteData(for: id, origins: siteOrigins, cookieNames: stripeDeviceCookies)
    }

    /// Same as above with an explicit origin list, used by tests and future site lists. A
    /// running Profile loses the cookies these origins can read or set and the HTTP cache.
    public func clearSiteData(for id: UUID, origins: [String]) async throws {
        try await clearSiteData(for: id, origins: origins, cookieNames: [])
    }

    private func clearSiteData(for id: UUID, origins: [String], cookieNames: Set<String>) async throws {
        switch status(for: id) {
        case .running:
            try await clearSiteDataThroughDevTools(for: id, origins: origins, cookieNames: cookieNames)
        case .starting, .stopping:
            throw ProfileError.invalid("请等此 Profile 的浏览器启动/停止完成，再重新生成身份。")
        case .stopped, .failed:
            try await clearSiteDataOnDisk(for: id)
        }
    }

    private func clearSiteDataThroughDevTools(for id: UUID, origins: [String], cookieNames: Set<String>) async throws {
        guard let endpoint = await devToolsEndpoint(for: id) else {
            throw ProfileError.invalid("浏览器调试接口未就绪，请稍后重试。")
        }
        let client = try DevToolsClient(endpoint: endpoint)
        defer { client.close() }
        // The Network domain and Storage.clearDataForOrigin only answer in a page session; a blank
        // background tab serves when no page is open.
        let targets = try await client.send("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
        let pages = targets.filter { $0["type"] as? String == "page" }
        var opened: String?
        let targetId: String
        if let page = pages.first(where: { ($0["url"] as? String)?.hasPrefix("http") == true }) ?? pages.first,
           let existing = page["targetId"] as? String {
            targetId = existing
        } else {
            let created = try await client.send("Target.createTarget", ["url": "about:blank", "background": true])
            guard let blank = created["targetId"] as? String else {
                throw ProfileError.invalid("无法打开标签页以清理站点数据。")
            }
            targetId = blank
            opened = blank
        }
        var failures: [String] = []
        do {
            let attached = try await client.send("Target.attachToTarget", ["targetId": targetId, "flatten": true])
            guard let sessionId = attached["sessionId"] as? String else {
                throw ProfileError.invalid("无法连接页面以清理站点数据。")
            }
            let hosts = origins.compactMap { URLComponents(string: $0)?.host?.lowercased() }
            let cookies = try await client.send("Network.getAllCookies", sessionId: sessionId)["cookies"] as? [[String: Any]] ?? []
            for cookie in cookies where Self.cookie(cookie, matches: hosts, names: cookieNames) {
                guard let name = cookie["name"] as? String, let domain = cookie["domain"] as? String else { continue }
                var match: [String: Any] = ["name": name, "domain": domain, "path": cookie["path"] as? String ?? "/"]
                // A partitioned (CHIPS) cookie is only found with its partition key.
                if let key = cookie["partitionKey"] { match["partitionKey"] = key }
                do {
                    _ = try await client.send("Network.deleteCookies", match, sessionId: sessionId)
                } catch {
                    failures.append("Cookie \(name)@\(domain)（\(error.localizedDescription)）")
                }
            }
            for origin in origins {
                do {
                    _ = try await client.send("Storage.clearDataForOrigin",
                                              ["origin": origin, "storageTypes": "all"],
                                              sessionId: sessionId)
                } catch {
                    failures.append("\(origin)（\(error.localizedDescription)）")
                }
            }
            // The HTTP cache cannot be cleared per site, and clearDataForOrigin leaves it alone.
            do {
                _ = try await client.send("Network.clearBrowserCache", sessionId: sessionId)
            } catch {
                failures.append("HTTP 缓存（\(error.localizedDescription)）")
            }
        } catch {
            if let opened { _ = try? await client.send("Target.closeTarget", ["targetId": opened]) }
            throw error
        }
        if let opened { _ = try? await client.send("Target.closeTarget", ["targetId": opened]) }
        if !failures.isEmpty {
            throw ProfileError.invalid("以下站点的数据未能清理：\(failures.joined(separator: "；"))")
        }
    }

    /// True for a cookie one of `hosts` reads or sets: on the host itself, on a parent domain
    /// (`.stripe.com` for m.stripe.com) or below it (`.app.link.com` for link.com). `names` match
    /// on every domain.
    nonisolated static func cookie(_ cookie: [String: Any], matches hosts: [String], names: Set<String>) -> Bool {
        guard let name = cookie["name"] as? String, let raw = cookie["domain"] as? String else { return false }
        if names.contains(name) { return true }
        let lowered = raw.lowercased()
        let domain = lowered.hasPrefix(".") ? String(lowered.dropFirst()) : lowered
        guard !domain.isEmpty else { return false }
        return hosts.contains { $0 == domain || $0.hasSuffix("." + domain) || domain.hasSuffix("." + $0) }
    }

    private func clearSiteDataOnDisk(for id: UUID) async throws {
        let root = dataDirectory(for: id)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard (try? PrivateDirectory.check(root)) != nil else {
            throw ProfileError.invalid("浏览器资料路径异常，已停止清理站点数据。")
        }
        guard !profileInUse(root) else {
            throw ProfileError.invalid("此 Profile 的浏览器资料正在使用，请先停止浏览器。")
        }
        let lock = try lockDirectory(root)
        defer { close(lock) }
        try await removeSiteData(for: id)
    }

    /// Deletes the site-data files of a Profile whose browser is not running, and its separate
    /// cache directory. The caller holds the data directory's lock.
    func removeSiteData(for id: UUID) async throws {
        let root = dataDirectory(for: id)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard (try? PrivateDirectory.check(root)) != nil,
              root.path.hasPrefix(storage.path + "/"),
              ProcessInspection.canonicalURL(storage, isDirectory: true)?.path == storage.path else {
            throw ProfileError.invalid("浏览器资料路径异常，已停止清理站点数据。")
        }
        var cache: URL?
        if let separate = separateCacheDirectory(for: id), let caches {
            do {
                if try verifiedForRemoval(separate, within: caches) { cache = separate }
            } catch {
                throw ProfileError.invalid("浏览器缓存路径异常（\(separate.path)），已停止清理站点数据。")
            }
        }
        let failures: [String] = await Task.detached {
            var failures = siteDataPaths.compactMap { relative -> String? in
                do {
                    try removeSiteDataIfPresent(root.appendingPathComponent(relative), under: root)
                    return nil
                } catch {
                    return "\(relative)（\(error.localizedDescription)）"
                }
            }
            // Only caches live there; the whole directory goes.
            if let cache {
                do {
                    try FileManager.default.removeItem(at: cache)
                } catch {
                    failures.append("\(cache.path)（\(error.localizedDescription)）")
                }
            }
            return failures
        }.value
        if !failures.isEmpty {
            throw ProfileError.invalid("以下站点数据未能清理：\(failures.joined(separator: "；"))")
        }
    }

    /// Deletes a Profile's browser data, cache and extension directories, and nothing else. With
    /// `keepingBrowserData`, only the extension directory goes: AnyBrowser writes the Profile's
    /// Passkey Box and proxy passwords there. Refuses while its browser runs or when a path is not
    /// the plain directory Chromium or AnyBrowser created. `beforeDeleting` runs once every check
    /// has passed (the caller removes the record there); when it throws, nothing is deleted.
    public func removeData(for id: UUID, keepingBrowserData: Bool = false,
                           beforeDeleting: () throws -> Void = {}) async throws {
        switch status(for: id) {
        case .running, .starting, .stopping:
            throw ProfileError.invalid("请先停止此 Profile 的浏览器，再移除。")
        case .stopped, .failed:
            break
        }
        let data = dataDirectory(for: id)
        let extensions = ProfileExtensions.root(in: storage, for: id)
        var candidates: [(url: URL, root: URL)] = [(extensions, storage)]
        if !keepingBrowserData {
            candidates.insert((data, storage), at: 0)
            // The cache stays with kept browser data, so an orphaned data directory can be adopted whole.
            if let cache = separateCacheDirectory(for: id), let caches { candidates.append((cache, caches)) }
        }
        // Only what will be deleted is checked. Removing just the record must keep working even when
        // the browser data directory, or the generated extension directory, is not as expected.
        var targets: [URL] = []
        var skipped: [String] = []
        for candidate in candidates {
            do {
                if try verifiedForRemoval(candidate.url, within: candidate.root) { targets.append(candidate.url) }
            } catch where keepingBrowserData {
                skipped.append("\(candidate.url.path)（路径异常，未删除）")
            }
        }
        var lock: Int32?
        defer { lock.map { _ = close($0) } }
        if targets.contains(data) {
            guard !profileInUse(data) else {
                throw ProfileError.invalid("此 Profile 的浏览器资料正在使用，请先在浏览器中退出。")
            }
            // Holding the runtime lock keeps a concurrent start or stop out until the deletion is done.
            lock = try lockDirectory(data)
        }
        try beforeDeleting()
        let unremoved = await Self.remove(targets)
        let failures = skipped + unremoved
        if !failures.isEmpty {
            throw ProfileError.invalid("以下目录未能删除，可以手动删除：\(failures.joined(separator: "；"))")
        }
    }

    /// Cache directories Chromium left under ~/Library/Caches for Profiles that are gone: not in
    /// `known` (pass every Profile the store still has, trashed ones included) and without a data
    /// directory. An orphaned data directory keeps its cache until the two are removed together.
    public func orphanCacheDirectories(knownProfiles known: Set<UUID>) -> [URL] {
        guard let parent = separateCacheLocation(of: storage.appendingPathComponent("Profiles", isDirectory: true)),
              let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return [] }
        return names.sorted().compactMap { name in
            guard let id = UUID(uuidString: name), id.uuidString.lowercased() == name, !known.contains(id) else { return nil }
            var details = stat()
            guard lstat(dataDirectory(for: id).path, &details) != 0, errno == ENOENT else { return nil }
            return parent.appendingPathComponent(name, isDirectory: true)
        }
    }

    /// Deletes `orphanCacheDirectories(knownProfiles:)` after the same path checks as `removeData`
    /// and returns what it deleted. A directory that fails a check or cannot be deleted is kept
    /// and reported once the others are gone.
    @discardableResult
    public func removeOrphanCacheDirectories(knownProfiles known: Set<UUID>) async throws -> [URL] {
        guard let caches else { return [] }
        var targets: [URL] = []
        var failures: [String] = []
        for directory in orphanCacheDirectories(knownProfiles: known) {
            do {
                if try verifiedForRemoval(directory, within: caches) { targets.append(directory) }
            } catch {
                failures.append("\(directory.path)（路径异常，未删除）")
            }
        }
        let unremoved = await Self.remove(targets)
        failures += unremoved
        if !failures.isEmpty {
            throw ProfileError.invalid("以下缓存目录未能删除，可以手动删除：\(failures.joined(separator: "；"))")
        }
        return targets
    }

    /// Chromium data can be large; deletes off the main thread. One failure does not stop the rest.
    private nonisolated static func remove(_ targets: [URL]) async -> [String] {
        await Task.detached {
            targets.compactMap { target in
                do {
                    try FileManager.default.removeItem(at: target)
                    return nil
                } catch {
                    return "\(target.path)（\(error.localizedDescription)）"
                }
            }
        }.value
    }

    /// False when `url` does not exist; true when it is a private directory of this user at its
    /// canonical path inside `root`; throws otherwise.
    private func verifiedForRemoval(_ url: URL, within root: URL) throws -> Bool {
        var details = stat()
        guard lstat(url.path, &details) == 0 else {
            guard errno == ENOENT else { throw unsafePath(url) }
            return false
        }
        guard (try? PrivateDirectory.check(url)) != nil, url.path.hasPrefix(root.path + "/"),
              ProcessInspection.canonicalURL(root, isDirectory: true)?.path == root.path else {
            throw unsafePath(url)
        }
        return true
    }

    private func unsafePath(_ url: URL) -> ProfileError {
        .invalid("浏览器资料路径异常（\(url.path)），已停止删除。")
    }
}

/// Sites that carry a Stripe/Link/hCaptcha device identity. Clearing an origin with no data is a no-op.
private let siteOrigins = [
    "https://app.link.com", "https://link.com", "https://www.link.com",
    "https://link.co", "https://app.onelink.com", "https://onelink.com",
    "https://m.stripe.com", "https://m.stripe.network",
    "https://js.stripe.com", "https://api.stripe.com", "https://edge-api.stripe.com",
    "https://edge-js.stripe.com", "https://crypto-js.stripe.com", "https://verify.stripe.com",
    "https://hooks.stripe.com", "https://r.stripe.com", "https://q.stripe.com",
    "https://checkout.stripe.com",
    "https://hcaptcha.com", "https://js.hcaptcha.com", "https://newassets.hcaptcha.com",
    "https://accounts.hcaptcha.com",
]

/// Stripe.js keeps a copy of the device id on every merchant's own domain
/// (docs/stripe-refresh-on-launch.md §1.3), so these names are matched on any domain.
private let stripeDeviceCookies: Set<String> = ["__stripe_mid", "__stripe_sid"]

/// Chromium's site-data files, relative to the data directory. Extension storage
/// (`Local Extension Settings`), preferences, history and bookmarks are deliberately left alone.
/// The caches are here for a data directory outside Application Support, which keeps them.
/// Shared Storage, Private State Tokens and the per-site salts of media device ids identify a
/// device as well as cookies do.
private let siteDataPaths = [
    "Default/Cookies", "Default/Cookies-journal",
    "Default/Network/Cookies", "Default/Network/Cookies-journal",
    "Default/Local Storage", "Default/Session Storage", "Default/WebStorage",
    "Default/IndexedDB", "Default/Service Worker",
    "Default/SharedStorage", "Default/SharedStorage-wal", "Default/Shared Dictionary",
    "Default/Trust Tokens", "Default/Trust Tokens-journal",
    "Default/MediaDeviceSalts", "Default/MediaDeviceSalts-journal",
    "Default/Cache", "Default/Code Cache", "Default/GPUCache",
    "Default/blob_storage", "Default/File System", "Default/databases",
]

/// Removes one site-data path, refusing to traverse a symlinked parent. A symlink at the
/// leaf itself is removed as a link, never followed.
private func removeSiteDataIfPresent(_ url: URL, under root: URL) throws {
    guard url.path.hasPrefix(root.path + "/") else {
        throw ProfileError.invalid("路径异常。")
    }
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    var parent = url.deletingLastPathComponent()
    while parent.path != root.path {
        let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw ProfileError.invalid("路径包含符号链接。")
        }
        parent.deleteLastPathComponent()
    }
    try FileManager.default.removeItem(at: url)
}
