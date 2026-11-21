import Darwin
import Foundation

extension BrowserRuntime {
    /// Deletes a Profile's browser data and extension directories, and nothing else.
    /// Refuses while its browser runs or when either path is not the plain directory AnyBrowser created.
    /// `beforeDeleting` runs once every check has passed (the caller removes the record there);
    /// when it throws, nothing is deleted.
    public func removeData(for id: UUID, beforeDeleting: () throws -> Void = {}) async throws {
        switch status(for: id) {
        case .running, .starting, .stopping:
            throw ProfileError.invalid("请先停止此 Profile 的浏览器，再删除浏览器资料。")
        case .stopped, .failed:
            break
        }
        let data = dataDirectory(for: id)
        let targets = try [data, ProfileExtensions.root(in: storage, for: id)].filter(verifiedForRemoval)
        var lock: Int32?
        defer { lock.map { _ = close($0) } }
        if targets.contains(data) {
            guard !profileInUse(data) else {
                throw ProfileError.invalid("此 Profile 的浏览器资料正在使用，请先在浏览器中退出。")
            }
            // Holding the runtime lock keeps a concurrent start or stop out until the data is gone.
            lock = try lockDirectory(data)
        }
        try beforeDeleting()
        // Chromium data can be large; delete off the main thread.
        let failure: String? = await Task.detached {
            for target in targets {
                do {
                    try FileManager.default.removeItem(at: target)
                } catch {
                    return "\(target.lastPathComponent)：\(error.localizedDescription)"
                }
            }
            return nil
        }.value
        if let failure {
            throw ProfileError.invalid("浏览器资料未能完全删除（\(failure)）。")
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
