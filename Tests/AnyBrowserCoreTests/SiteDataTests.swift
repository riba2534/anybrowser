@testable import AnyBrowserCore
import Foundation
import Testing

struct SiteDataTests {
    @Test("Clearing a stopped Profile removes site data but keeps extension storage and preferences")
    @MainActor
    func clearsStoppedSiteData() async throws {
        let storage = try scratchDirectory("site-data")
        defer { try? FileManager.default.removeItem(at: storage) }

        let id = UUID()
        let root = storage.appendingPathComponent("Profiles/\(id.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let defaults = root.appendingPathComponent("Default", isDirectory: true)
        let cookies = defaults.appendingPathComponent("Network/Cookies")
        let localStorage = defaults.appendingPathComponent("Local Storage/leveldb/CURRENT")
        let extensionStorage = defaults.appendingPathComponent("Local Extension Settings/extension/config")
        let preferences = defaults.appendingPathComponent("Preferences")
        for file in [cookies, localStorage, extensionStorage, preferences] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: file)
        }

        let engine = BrowserEngine(version: "test",
                                   executable: URL(fileURLWithPath: "/bin/true"),
                                   passkeyBoxDirectory: URL(fileURLWithPath: "/tmp/anybrowser-test-extension"))
        let runtime = BrowserRuntime(engine: engine, storage: storage)
        try await runtime.clearSiteData(for: id)

        #expect(!FileManager.default.fileExists(atPath: cookies.path))
        #expect(!FileManager.default.fileExists(atPath: localStorage.path))
        #expect(FileManager.default.fileExists(atPath: extensionStorage.path))
        #expect(FileManager.default.fileExists(atPath: preferences.path))
    }
}
