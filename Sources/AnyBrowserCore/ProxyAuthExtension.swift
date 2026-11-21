import Foundation

/// A generated MV3 extension that answers the proxy's authentication challenge for one Profile.
enum ProxyAuthExtension {
    static func directory(in storage: URL, for id: UUID) -> URL {
        ProfileExtensions.root(in: storage, for: id).appendingPathComponent("ProxyAuth", isDirectory: true)
    }

    /// Writes the extension when the Profile's proxy has credentials, and removes it otherwise.
    static func prepare(for profile: BrowserProfile, in storage: URL) throws {}
}
