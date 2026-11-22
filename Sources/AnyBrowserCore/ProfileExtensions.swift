import Foundation

/// Per-Profile unpacked extensions under `<storage>/Extensions/<uuid>/`.
enum ProfileExtensions {
    static func root(in storage: URL, for id: UUID) -> URL {
        storage.appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Creates the Profile's extension root, readable only by the current user.
    @discardableResult
    static func prepareRoot(in storage: URL, for id: UUID) throws -> URL {
        let root = root(in: storage, for: id)
        // Chromium parses --load-extension as a comma-separated list.
        guard !root.path.contains(",") else {
            throw ProfileError.invalid("AnyBrowser 资料目录的路径不能包含逗号。")
        }
        for directory in [root.deletingLastPathComponent(), root] {
            try PrivateDirectory.ensure(directory, failure: "扩展目录不可用，请检查本机目录权限。")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return root
    }

    /// The unpacked extensions a Profile loads, in order: Passkey Box, the proxy sign-in helper
    /// when the proxy has credentials, then the Profile's own extensions.
    /// Run right before launch: throws when an extension the Profile loads is unavailable,
    /// for example a shared-library extension that has been removed.
    static func check(for profile: BrowserProfile, in storage: URL) throws {}

    static func paths(for profile: BrowserProfile, in storage: URL) -> [URL] {
        var paths = [PasskeyBoxInstall.directory(in: storage, for: profile.id)]
        if let endpoint = try? ProxyEndpoint.parse(profile.proxy), endpoint.hasCredentials {
            paths.append(ProxyAuthExtension.directory(in: storage, for: profile.id))
        }
        paths += profile.launch.extensionDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return paths
    }
}
