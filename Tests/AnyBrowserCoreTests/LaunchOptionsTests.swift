@testable import AnyBrowserCore
import Foundation
import Testing

struct LaunchOptionsTests {
    @Test("Start URLs are trimmed, normalized and deduplicated in order")
    func startURLsAreNormalized() throws {
        let options = try LaunchOptions(startURLs: [
            "  HTTPS://Example.COM  ", "", "   ", "https://example.com/", "http://127.0.0.1:8080/a?b=C#D\r",
            "https://example.com/Path", "http://[FE80::1]:80",
        ]).validated()
        #expect(options.startURLs == [
            "https://example.com/", "http://127.0.0.1:8080/a?b=C#D", "https://example.com/Path", "http://[fe80::1]:80/",
        ])
    }

    @Test("Only absolute http and https URLs with a host are accepted", arguments: [
        "example.com", "ftp://example.com/", "file:///etc/hosts", "javascript:alert(1)", "https:example.com",
        "https:///path", "--disable-web-security", "chrome://settings", "http://example.com:70000/",
        "https://example.com/" + String(repeating: "a", count: 2029),
    ])
    func rejectsStartURL(_ url: String) {
        #expect(throws: ProfileError.self) { try LaunchOptions(startURLs: [url]).validated() }
    }

    @Test("Start URLs are limited to 20 after duplicates are dropped")
    func startURLLimit() throws {
        let twenty = (1...20).map { "https://example.com/\($0)" }
        #expect(try LaunchOptions(startURLs: twenty + twenty).validated().startURLs == twenty)
        #expect(try LaunchOptions(startURLs: ["https://example.com/" + String(repeating: "a", count: 2028)])
            .validated().startURLs.first?.utf8.count == 2048)
        #expect(throws: ProfileError.self) {
            try LaunchOptions(startURLs: twenty + ["https://example.com/21"]).validated()
        }
    }

    @Test("Window size and position stay within bounds")
    func windowBounds() throws {
        for window in [
            WindowLayout(width: 400, height: 300), WindowLayout(width: 7680, height: 4320),
            WindowLayout(width: 1280, height: 800, x: -10000, y: 10000), WindowLayout(width: 1280, height: 800, x: 0, y: 0),
        ] {
            #expect(try LaunchOptions(window: window).validated().window == window)
        }
        for window in [
            WindowLayout(width: 399, height: 800), WindowLayout(width: 7681, height: 800),
            WindowLayout(width: 1280, height: 299), WindowLayout(width: 1280, height: 4321),
            WindowLayout(width: 1280, height: 800, x: -10001, y: 0), WindowLayout(width: 1280, height: 800, x: 0, y: 10001),
            WindowLayout(width: 1280, height: 800, x: 10), WindowLayout(width: 1280, height: 800, y: 10),
            WindowLayout(width: 0, height: 0, x: 10, y: 10), WindowLayout(width: Int.min, height: 800),
        ] {
            #expect(throws: ProfileError.self) { try LaunchOptions(window: window).validated() }
        }
    }

    @Test("Extension directories must be absolute, comma-free, unique and at most 10")
    func extensionDirectorySyntax() throws {
        // Syntax only: a folder that has since disappeared must not stop a Profile from loading.
        let options = try LaunchOptions(extensionDirectories: [
            "/missing/One", "/missing/One/", "/missing//Two", "/missing/One",
        ]).validated()
        #expect(options.extensionDirectories == ["/missing/One", "/missing/Two"])
        for invalid in ["relative/Ext", "~/Ext", "", "/Users/me/A,B", "/Users/me/A\0B"] {
            #expect(throws: ProfileError.self) { try LaunchOptions(extensionDirectories: [invalid]).validated() }
        }
        let ten = (1...10).map { "/Ext/\($0)" }
        #expect(try LaunchOptions(extensionDirectories: ten + ten).validated().extensionDirectories == ten)
        #expect(throws: ProfileError.self) {
            try LaunchOptions(extensionDirectories: ten + ["/Ext/11"]).validated()
        }
    }

    @Test("Extension directories are checked on disk for a manifest, following links")
    func extensionDirectoriesOnDisk() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let good = root.appendingPathComponent("Good", isDirectory: true)
        try manager.createDirectory(at: good, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: good.appendingPathComponent("manifest.json"))
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try manager.createDirectory(at: nested.appendingPathComponent("manifest.json"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("File")
        try Data("{}".utf8).write(to: file)
        let link = root.appendingPathComponent("Link")
        try manager.createSymbolicLink(at: link, withDestinationURL: good)
        let linkedManifest = root.appendingPathComponent("LinkedManifest", isDirectory: true)
        try manager.createDirectory(at: linkedManifest, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: linkedManifest.appendingPathComponent("manifest.json"),
                                       withDestinationURL: good.appendingPathComponent("manifest.json"))
        let missing = root.appendingPathComponent("Missing").path

        let available = LaunchOptions(extensionDirectories: [good.path, link.path, linkedManifest.path])
        #expect(available.unavailableExtensionDirectories().isEmpty)
        try available.checkExtensionDirectories()

        let options = LaunchOptions(extensionDirectories: [good.path, empty.path, nested.path, file.path, missing])
        #expect(options.unavailableExtensionDirectories() == [empty.path, nested.path, file.path, missing])
        do {
            try options.checkExtensionDirectories()
            Issue.record("An unavailable extension directory passed the check")
        } catch let ProfileError.invalid(message) {
            #expect(message == "扩展目录不可用：\(empty.path)")
        }
    }

    @Test("Window switches come first, then the start URLs")
    func argumentOrder() {
        let urls = ["https://one.example/", "https://two.example/"]
        #expect(LaunchOptions(startURLs: urls, window: WindowLayout(width: 1280, height: 800, x: -20, y: 40)).arguments()
            == ["--window-size=1280,800", "--window-position=-20,40"] + urls)
        #expect(LaunchOptions(window: WindowLayout(width: 1280, height: 800)).arguments() == ["--window-size=1280,800"])
        #expect(LaunchOptions(startURLs: urls).arguments() == urls)
        #expect(LaunchOptions().arguments().isEmpty)
    }

    @Test("Profiles pass start URLs last, after the extensions and window switches")
    func profileArguments() throws {
        var profile = BrowserProfile(name: "Launch", port: 9302, fingerprint: FingerprintSettings(seed: 11))
        profile.fingerprint.timeZone = "UTC"
        profile.launch = LaunchOptions(startURLs: [" https://Example.com ", "https://example.com/"],
                                       window: WindowLayout(width: 1000, height: 700, x: 10, y: 20),
                                       extensionDirectories: ["/Ext/One/"])
        let validated = try profile.validated()
        #expect(validated.launch.startURLs == ["https://example.com/"])
        #expect(validated.launch.extensionDirectories == ["/Ext/One"])

        let storage = URL(fileURLWithPath: "/tmp/anybrowser-storage", isDirectory: true)
        let arguments = validated.launchArguments(userDataDirectory: storage,
                                                  extensions: ProfileExtensions.paths(for: validated, in: storage))
        let load = try #require(arguments.firstIndex { $0.hasPrefix("--load-extension=") })
        #expect(arguments[load].hasSuffix(",/Ext/One"))
        #expect(arguments.firstIndex(of: "--timezone=UTC").map { $0 < load } == true)
        #expect(Array(arguments[(load + 1)...]) == [
            "--window-size=1000,700", "--window-position=10,20", "https://example.com/",
        ])
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/identity-launch", isDirectory: true)
            .appendingPathComponent("options-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
