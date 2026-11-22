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
        try prepare(root(in: storage, for: id))
    }

    /// Creates a directory under `Extensions/`, and `Extensions/` itself, readable only by the current user.
    @discardableResult
    static func prepare(_ root: URL) throws -> URL {
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

    /// Run right before launch: throws when an extension the Profile loads is unavailable,
    /// for example a shared-library extension that has been removed.
    static func check(for profile: BrowserProfile, in storage: URL) throws {
        guard !paths(for: profile, in: storage).contains(where: { $0.path.contains(",") }) else {
            throw ProfileError.invalid("AnyBrowser 资料目录的路径不能包含逗号。")
        }
        for name in profile.launch.sharedExtensions {
            if let problem = SharedExtensions.problem(with: name, in: storage) { throw ProfileError.invalid(problem) }
        }
    }

    /// The unpacked extensions a Profile loads, in order: Passkey Box unless the Profile leaves it
    /// out, the shared-library extensions the Profile picked, then the Profile's own extension directories.
    static func paths(for profile: BrowserProfile, in storage: URL) -> [URL] {
        var paths: [URL] = []
        if profile.launch.loadPasskeyBox {
            paths.append(PasskeyBoxInstall.directory(in: storage, for: profile.id))
        }
        // When two directories hold the same extension ID, Chromium keeps the one listed later, so
        // the Profile's own directories come last and win over a shared copy of the same extension.
        paths += profile.launch.sharedExtensions.map { SharedExtensions.directory(named: $0, in: storage) }
        paths += profile.launch.extensionDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return paths
    }

    /// Where AnyBrowser 0.4 wrote the extension that answered proxy sign-in, credentials included.
    static func legacyProxySignIn(in storage: URL, for id: UUID) -> URL {
        root(in: storage, for: id).appendingPathComponent("ProxyAuth", isDirectory: true)
    }

    /// Deletes that extension, now that the relay signs in. Only a real directory of this user
    /// whose manifest is the one AnyBrowser generated goes; anything else there is left alone.
    static func removeLegacyProxySignIn(in storage: URL, for id: UUID) {
        let directory = legacyProxySignIn(in: storage, for: id)
        var details = stat()
        guard lstat(directory.path, &details) == 0, details.st_mode & S_IFMT == S_IFDIR, details.st_uid == getuid(),
              let manifest = try? PrivateFile.read(directory.appendingPathComponent("manifest.json"), limit: 4096,
                                                   failure: ""),
              let fields = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              fields["name"] as? String == "AnyBrowser Proxy Sign-in" else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
