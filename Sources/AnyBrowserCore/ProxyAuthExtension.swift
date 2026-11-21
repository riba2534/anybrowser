import Darwin
import Foundation

/// A generated MV3 extension that answers the proxy's authentication challenge for one Profile.
enum ProxyAuthExtension {
    static let credentialsFile = "credentials.json"

    static func directory(in storage: URL, for id: UUID) -> URL {
        ProfileExtensions.root(in: storage, for: id).appendingPathComponent("ProxyAuth", isDirectory: true)
    }

    /// Writes the extension when the Profile's proxy has credentials, and removes it otherwise.
    static func prepare(for profile: BrowserProfile, in storage: URL) throws {
        let target = directory(in: storage, for: profile.id)
        var details = stat()
        guard let endpoint = try ProxyEndpoint.parse(profile.proxy),
              let username = endpoint.username, let password = endpoint.password else {
            if lstat(target.path, &details) == 0 { try FileManager.default.removeItem(at: target) }
            return
        }
        // Chromium parses --load-extension as a comma-separated list.
        guard !target.path.contains(",") else {
            throw ProfileError.invalid("AnyBrowser 资料目录的路径不能包含逗号。")
        }
        _ = try ProfileExtensions.prepareRoot(in: storage, for: profile.id)
        // Only a real directory of ours is reused; a link or file in its place is replaced.
        if lstat(target.path, &details) == 0, details.st_mode & S_IFMT != S_IFDIR || details.st_uid != getuid() {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let credentials = try encoder.encode(Credentials(host: endpoint.host, port: endpoint.port,
                                                         username: username, password: password))
        let files = ["manifest.json": Data(manifest.utf8), "background.js": Data(script.utf8), credentialsFile: credentials]
        for (name, data) in files {
            try write(data, to: target.appendingPathComponent(name))
        }
        // Drops anything else, such as a temporary copy of old credentials left by an interrupted write.
        for name in try FileManager.default.contentsOfDirectory(atPath: target.path) where files[name] == nil {
            try FileManager.default.removeItem(at: target.appendingPathComponent(name))
        }
    }

    private struct Credentials: Encodable {
        let host: String
        let port: Int
        let username: String
        let password: String
    }

    /// Leaves an identical private file alone; otherwise replaces it atomically.
    private static func write(_ data: Data, to url: URL) throws {
        var details = stat()
        if lstat(url.path, &details) == 0, details.st_mode & S_IFMT == S_IFREG, details.st_uid == getuid(),
           details.st_mode & 0o777 == 0o600, (try? Data(contentsOf: url)) == data {
            return
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ProfileError.invalid("无法写入代理登录扩展。")
        }
    }

    static let manifest = """
    {
      "manifest_version": 3,
      "name": "AnyBrowser Proxy Sign-in",
      "version": "1.0.0",
      "description": "Signs in to this Profile's proxy.",
      "minimum_chrome_version": "108",
      "permissions": ["webRequest", "webRequestAuthProvider"],
      "host_permissions": ["<all_urls>"],
      "background": {"service_worker": "background.js"}
    }

    """

    // The listener is registered synchronously so a service worker woken by a challenge receives it.
    // A second challenge for the same request means the proxy rejected the credentials: cancel the
    // request instead of answering forever.
    static let script = """
    const config = fetch(chrome.runtime.getURL('\(credentialsFile)'))
      .then((response) => response.json())
      .catch(() => null);
    const answered = new Set();
    const bare = (host) => String(host ?? '').replace(/^\\[|\\]$/g, '').toLowerCase();

    chrome.webRequest.onAuthRequired.addListener((details, callback) => {
      config.then((proxy) => {
        const challenger = details.challenger ?? {};
        if (!proxy || !details.isProxy || bare(challenger.host) !== bare(proxy.host) || challenger.port !== proxy.port) {
          callback({});
          return;
        }
        if (answered.has(details.requestId)) {
          callback({cancel: true});
          return;
        }
        answered.add(details.requestId);
        if (answered.size > 1000) answered.delete(answered.values().next().value);
        callback({authCredentials: {username: proxy.username, password: proxy.password}});
      });
    }, {urls: ['<all_urls>']}, ['asyncBlocking']);

    """
}
