import Darwin
import Foundation

/// Per-Profile unpacked extensions under `<storage>/Extensions/<uuid>/`.
enum ProfileExtensions {
    static func root(in storage: URL, for id: UUID) -> URL {
        storage.appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Creates the Profile's extension root, readable only by the current user.
    static func prepareRoot(in storage: URL, for id: UUID) throws -> URL {
        let root = root(in: storage, for: id)
        for directory in [root.deletingLastPathComponent(), root] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var details = stat()
            guard lstat(directory.path, &details) == 0, details.st_uid == getuid(),
                  details.st_mode & S_IFMT == S_IFDIR else {
                throw ProfileError.invalid("扩展目录不可用，请检查本机目录权限。")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return root
    }

    /// The unpacked extensions a Profile loads, in order: Passkey Box, the proxy sign-in helper
    /// when the proxy has credentials, then the Profile's own extensions.
    static func paths(for profile: BrowserProfile, in storage: URL) -> [URL] {
        var paths = [PasskeyBoxInstall.directory(in: storage, for: profile.id)]
        if let endpoint = try? ProxyEndpoint.parse(profile.proxy), endpoint.hasCredentials {
            paths.append(ProxyAuthExtension.directory(in: storage, for: profile.id))
        }
        paths += profile.launch.extensionDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return paths
    }
}
