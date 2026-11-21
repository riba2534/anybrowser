import Darwin
import Foundation

extension BrowserRuntime {
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
