import Darwin
import Foundation

extension BrowserRuntime {
    /// Clears the sites that identify a device, without deleting the Profile's browser data,
    /// Passkey Box extension storage or preferences. A running browser is cleared through DevTools;
    /// a stopped one has its cookie, storage and cache files removed from disk.
    public func clearSiteData(for id: UUID) async throws {
        try await clearSiteData(for: id, origins: siteOrigins)
    }

    /// Same as above with an explicit origin list, used by tests and future site lists.
    public func clearSiteData(for id: UUID, origins: [String]) async throws {
        switch status(for: id) {
        case .running:
            try await clearSiteDataThroughDevTools(for: id, origins: origins)
        case .starting, .stopping:
            throw ProfileError.invalid("请等此 Profile 的浏览器启动/停止完成，再重新生成身份。")
        case .stopped, .failed:
            try await clearSiteDataOnDisk(for: id)
        }
    }

    private func clearSiteDataThroughDevTools(for id: UUID, origins: [String]) async throws {
        guard let endpoint = await devToolsEndpoint(for: id) else {
            throw ProfileError.invalid("浏览器调试接口未就绪，请稍后重试。")
        }
        let client = try DevToolsClient(endpoint: endpoint)
        defer { client.close() }
        let targets = try await client.send("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
        let pages = targets.filter { $0["type"] as? String == "page" }
        guard let page = pages.first(where: { ($0["url"] as? String)?.hasPrefix("http") == true }) ?? pages.first,
              let targetId = page["targetId"] as? String else {
            throw ProfileError.invalid("请先打开一个网页标签页，再重新生成身份。")
        }
        let attached = try await client.send("Target.attachToTarget", ["targetId": targetId, "flatten": true])
        guard let sessionId = attached["sessionId"] as? String else {
            throw ProfileError.invalid("无法连接页面以清理站点数据。")
        }
        var failures: [String] = []
        for origin in origins {
            do {
                _ = try await client.send("Storage.clearDataForOrigin",
                                          ["origin": origin, "storageTypes": "all"],
                                          sessionId: sessionId)
            } catch {
                failures.append("\(origin)（\(error.localizedDescription)）")
            }
        }
        if !failures.isEmpty {
            throw ProfileError.invalid("以下站点的数据未能清理：\(failures.joined(separator: "；"))")
        }
    }

    private func clearSiteDataOnDisk(for id: UUID) async throws {
        let root = dataDirectory(for: id)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard (try? PrivateDirectory.check(root)) != nil,
              root.path.hasPrefix(storage.path + "/"),
              ProcessInspection.canonicalURL(storage, isDirectory: true)?.path == storage.path else {
            throw ProfileError.invalid("浏览器资料路径异常，已停止清理站点数据。")
        }
        guard !profileInUse(root) else {
            throw ProfileError.invalid("此 Profile 的浏览器资料正在使用，请先停止浏览器。")
        }
        let lock = try lockDirectory(root)
        defer { close(lock) }
        let failures: [String] = await Task.detached {
            siteDataPaths.compactMap { relative in
                do {
                    try removeSiteDataIfPresent(root.appendingPathComponent(relative), under: root)
                    return nil
                } catch {
                    return "\(relative)（\(error.localizedDescription)）"
                }
            }
        }.value
        if !failures.isEmpty {
            throw ProfileError.invalid("以下站点数据未能清理：\(failures.joined(separator: "；"))")
        }
    }

    /// Deletes a Profile's browser data and extension directories, and nothing else. With
    /// `keepingBrowserData`, only the extension directory goes: AnyBrowser writes the Profile's
    /// Passkey Box and proxy passwords there. Refuses while its browser runs or when a path is not
    /// the plain directory AnyBrowser created. `beforeDeleting` runs once every check has passed
    /// (the caller removes the record there); when it throws, nothing is deleted.
    public func removeData(for id: UUID, keepingBrowserData: Bool = false,
                           beforeDeleting: () throws -> Void = {}) async throws {
        switch status(for: id) {
        case .running, .starting, .stopping:
            throw ProfileError.invalid("请先停止此 Profile 的浏览器，再移除。")
        case .stopped, .failed:
            break
        }
        let data = dataDirectory(for: id)
        // Only what will be deleted is checked. Removing just the record must keep working even when
        // the browser data directory, or the generated extension directory, is not as expected.
        var targets: [URL] = []
        var skipped: [String] = []
        for url in keepingBrowserData ? [ProfileExtensions.root(in: storage, for: id)] : [data, ProfileExtensions.root(in: storage, for: id)] {
            do {
                if try verifiedForRemoval(url) { targets.append(url) }
            } catch where keepingBrowserData {
                skipped.append("\(url.path)（路径异常，未删除）")
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
        // Chromium data can be large; delete off the main thread. One failure does not stop the rest.
        let unremoved: [String] = await Task.detached {
            targets.compactMap { target in
                do {
                    try FileManager.default.removeItem(at: target)
                    return nil
                } catch {
                    return "\(target.path)（\(error.localizedDescription)）"
                }
            }
        }.value
        let failures = skipped + unremoved
        if !failures.isEmpty {
            throw ProfileError.invalid("以下目录未能删除，可以手动删除：\(failures.joined(separator: "；"))")
        }
    }

    /// False when `url` does not exist; true when it is a private directory of this user at its
    /// canonical path inside the storage directory; throws otherwise.
    private func verifiedForRemoval(_ url: URL) throws -> Bool {
        var details = stat()
        guard lstat(url.path, &details) == 0 else {
            guard errno == ENOENT else { throw unsafePath(url) }
            return false
        }
        guard (try? PrivateDirectory.check(url)) != nil, url.path.hasPrefix(storage.path + "/"),
              ProcessInspection.canonicalURL(storage, isDirectory: true)?.path == storage.path else {
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

/// Chromium's site-data files, relative to the Profile's `Default` directory. Extension storage
/// (`Local Extension Settings`) and preferences are deliberately left alone.
private let siteDataPaths = [
    "Default/Cookies", "Default/Cookies-journal",
    "Default/Network/Cookies", "Default/Network/Cookies-journal",
    "Default/Local Storage", "Default/Session Storage", "Default/WebStorage",
    "Default/IndexedDB", "Default/Service Worker",
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
