@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

@Suite("Passkey Box account", .serialized)
struct PasskeyBoxTests {
    @Test("Accounts are normalized like the extension's login form")
    func normalizesAccounts() throws {
        let account = try PasskeyBoxAccount(serverURL: " pk.example.com/ ", username: " alice ", password: "pw").validated()
        #expect(account == PasskeyBoxAccount(serverURL: "https://pk.example.com", username: "alice", password: "pw"))
        let local = try PasskeyBoxAccount(serverURL: "http://127.0.0.1:8080//", username: "a", password: "b").validated()
        #expect(local.serverURL == "http://127.0.0.1:8080")
        for invalid in [
            PasskeyBoxAccount(serverURL: "ftp://pk.example.com", username: "a", password: "b"),
            PasskeyBoxAccount(serverURL: "https://", username: "a", password: "b"),
            PasskeyBoxAccount(serverURL: "https://u:p@pk.example.com", username: "a", password: "b"),
            PasskeyBoxAccount(serverURL: "https://pk.example.com/?x=1", username: "a", password: "b"),
            PasskeyBoxAccount(serverURL: "https://pk.example.com", username: " ", password: "b"),
            PasskeyBoxAccount(serverURL: "https://pk.example.com", username: "a:b", password: "b"),
            PasskeyBoxAccount(serverURL: "https://pk.example.com", username: "a", password: ""),
        ] {
            #expect(throws: ProfileError.self) { try invalid.validated() }
        }
    }

    @Test("The store keeps one account across launches")
    @MainActor
    func storeKeepsTheAccount() throws {
        let directory = try scratchDirectory("passkey")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        #expect(store.passkeyBoxAccount == nil)

        try store.savePasskeyBoxAccount(PasskeyBoxAccount(serverURL: "pk.example.com", username: "alice", password: "pw"))
        let saved = PasskeyBoxAccount(serverURL: "https://pk.example.com", username: "alice", password: "pw")
        #expect(store.passkeyBoxAccount == saved)
        #expect(try ProfileStore(directory: directory).passkeyBoxAccount == saved)

        #expect(throws: ProfileError.self) { try store.savePasskeyBoxAccount(PasskeyBoxAccount(username: "", password: "x")) }
        #expect(store.passkeyBoxAccount == saved)

        try store.savePasskeyBoxAccount(nil)
        #expect(store.passkeyBoxAccount == nil)
        #expect(try ProfileStore(directory: directory).passkeyBoxAccount == nil)
    }

    @Test("managed-config.json holds the account and the owned-only sign-in policy")
    func managedConfiguration() throws {
        let account = PasskeyBoxAccount(serverURL: "pk.example.com/", username: " alice ", password: #"p"w/"#)
        #expect(String(decoding: try account.managedConfiguration(), as: UTF8.self)
            == #"{"autoLogin":"owned-only","password":"p\"w/","serverUrl":"https://pk.example.com","username":"alice"}"#)
        #expect(throws: ProfileError.self) { try PasskeyBoxAccount(username: "", password: "x").managedConfiguration() }
    }

    @Test("Profiles load a private copy of Passkey Box with managed-config.json")
    func installsACopyWithManagedConfig() throws {
        let root = try scratchDirectory("passkey")
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, storage) = try bundle(in: root)
        let id = UUID()
        let target = PasskeyBoxInstall.directory(in: storage, for: id)
        let config = target.appendingPathComponent("managed-config.json")
        #expect(target.path == storage.path + "/Extensions/\(id.uuidString.lowercased())/PasskeyBox")

        // Without an account the file still holds the policy, for the account the extension keeps.
        try PasskeyBoxInstall.prepare(bundled: source, in: storage, for: id, account: nil)
        #expect(try String(contentsOf: target.appendingPathComponent("icons/icon-16.png"), encoding: .utf8) == "png")
        #expect(try String(contentsOf: config, encoding: .utf8) == #"{"autoLogin":"owned-only"}"#)
        #expect(try permissions(config) == 0o600)
        #expect(try permissions(target.deletingLastPathComponent()) == 0o700)

        let account = PasskeyBoxAccount(serverURL: "https://pk.example.com/", username: "alice", password: #"p"w"#)
        try PasskeyBoxInstall.prepare(bundled: source, in: storage, for: id, account: account)
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: String])
        #expect(written == ["autoLogin": "owned-only", "serverUrl": "https://pk.example.com", "username": "alice",
                            "password": #"p"w"#])
        #expect(try String(contentsOf: config, encoding: .utf8).contains(#""serverUrl":"https://pk.example.com""#))
        #expect(try permissions(config) == 0o600)

        // An unchanged bundle keeps the installed copy in place.
        let installed = try inode(target)
        try PasskeyBoxInstall.prepare(bundled: source, in: storage, for: id, account: account)
        #expect(try inode(target) == installed)

        // A new bundle, or a tampered copy, is replaced; the account file is rewritten.
        try Data("two".utf8).write(to: source.appendingPathComponent("background.js"))
        try PasskeyBoxInstall.prepare(bundled: source, in: storage, for: id, account: account)
        #expect(try String(contentsOf: target.appendingPathComponent("background.js"), encoding: .utf8) == "two")
        #expect(FileManager.default.fileExists(atPath: config.path))
        let script = target.appendingPathComponent("background.js")
        try FileManager.default.removeItem(at: script)
        try FileManager.default.createSymbolicLink(at: script, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        try PasskeyBoxInstall.prepare(bundled: source, in: storage, for: id, account: account)
        #expect(try String(contentsOf: script, encoding: .utf8) == "two")
        #expect(try FileManager.default.attributesOfItem(atPath: script.path)[.type] as? FileAttributeType == .typeRegular)

        // A link in place of the installed directory is replaced by a real copy.
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.moveItem(at: target, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: elsewhere)
        try PasskeyBoxInstall.prepare(bundled: source, in: storage, for: id, account: account)
        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType == .typeDirectory)

        try PasskeyBoxInstall.prepare(bundled: source, in: storage, for: id, account: nil)
        #expect(try String(contentsOf: config, encoding: .utf8) == #"{"autoLogin":"owned-only"}"#)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        #expect(leftovers == ["PasskeyBox"])
    }

    @Test("A Profile that leaves Passkey Box out has its copy removed and does not load it")
    func leavesPasskeyBoxOut() throws {
        let root = try scratchDirectory("passkey")
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, storage) = try bundle(in: root)
        var profile = BrowserProfile(name: "No passkeys", port: 9301, fingerprint: FingerprintSettings(seed: 3))
        let target = PasskeyBoxInstall.directory(in: storage, for: profile.id)
        #expect(ProfileExtensions.paths(for: profile, in: storage).first == target)
        profile.launch.loadPasskeyBox = false
        #expect(!ProfileExtensions.paths(for: profile, in: storage).contains(target))

        let account = PasskeyBoxAccount(serverURL: "https://pk.example.com", username: "alice", password: "pw")
        try PasskeyBoxInstall.prepare(bundled: source, in: storage, for: profile.id, account: account)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("managed-config.json").path))
        // Taking it out does not need the bundled copy.
        let missing = root.appendingPathComponent("Missing", isDirectory: true)
        try PasskeyBoxInstall.prepare(bundled: missing, in: storage, for: profile.id, account: account, enabled: false)
        var details = stat()
        #expect(lstat(target.path, &details) != 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).isEmpty)
        try PasskeyBoxInstall.prepare(bundled: missing, in: storage, for: profile.id, account: nil, enabled: false)

        // A link in its place goes; what it points to stays.
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: elsewhere.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: elsewhere)
        try PasskeyBoxInstall.prepare(bundled: source, in: storage, for: profile.id, account: nil, enabled: false)
        #expect(lstat(target.path, &details) != 0)
        #expect(try String(contentsOf: elsewhere.appendingPathComponent("manifest.json"), encoding: .utf8) == "keep")

        // Turning it back on installs a fresh copy.
        try PasskeyBoxInstall.prepare(bundled: source, in: storage, for: profile.id, account: nil)
        #expect(try String(contentsOf: target.appendingPathComponent("background.js"), encoding: .utf8) == "one")
    }

    @Test("Copies and account files left by an interrupted install are deleted on the next start")
    func cleansUpInterruptedInstalls() throws {
        let root = try scratchDirectory("passkey")
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, storage) = try bundle(in: root)
        let id = UUID()
        let parent = try ProfileExtensions.prepareRoot(in: storage, for: id)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("ProxyAuth"), withIntermediateDirectories: true)
        let account = PasskeyBoxAccount(serverURL: "https://pk.example.com", username: "alice", password: "pw")

        for enabled in [true, false] {
            for name in [".PasskeyBox-\(UUID().uuidString)", ".PasskeyBox-old-\(UUID().uuidString)"] {
                let copy = parent.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
                try Data(#"{"password":"old"}"#.utf8).write(to: copy.appendingPathComponent("managed-config.json"))
            }
            try Data(#"{"password":"old"}"#.utf8).write(to: parent.appendingPathComponent(".managed-config.json-\(UUID().uuidString)"))
            try PasskeyBoxInstall.prepare(bundled: source, in: storage, for: id, account: account, enabled: enabled)
            let left = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
            #expect(left == (enabled ? ["PasskeyBox", "ProxyAuth"] : ["ProxyAuth"]))
        }
    }

    /// A bundled Passkey Box under `root/Bundle`, and an empty storage directory.
    private func bundle(in root: URL) throws -> (source: URL, storage: URL) {
        let source = root.appendingPathComponent("Bundle/PasskeyBox", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try Data(#"{"version":"0.3.0"}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("one".utf8).write(to: source.appendingPathComponent("background.js"))
        try Data("png".utf8).write(to: source.appendingPathComponent("icons/icon-16.png"))
        let storage = root.appendingPathComponent("Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        return (source, storage)
    }

    @Test("Saving verifies the account with GET /api/v1/me")
    func verifiesWithTheServer() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        let account = PasskeyBoxAccount(serverURL: "pk.example.com/", username: "alice", password: "pw")

        StubServer.respond = { _ in (200, Data(#"{"user":{"id":1,"username":"alice"}}"#.utf8)) }
        try await account.verify(configuration: configuration)
        let request = try #require(StubServer.lastRequest)
        #expect(request.url?.absoluteString == "https://pk.example.com/api/v1/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("alice:pw".utf8).base64EncodedString())

        StubServer.respond = { _ in (401, Data(#"{"error":{"code":"unauthorized"}}"#.utf8)) }
        await #expect(throws: ProfileError.self) { try await account.verify(configuration: configuration) }
        StubServer.respond = { _ in (200, Data("{}".utf8)) }
        await #expect(throws: ProfileError.self) { try await account.verify(configuration: configuration) }
        StubServer.respond = { _ in (302, Data()) }
        await #expect(throws: ProfileError.self) { try await account.verify(configuration: configuration) }
    }

}

private final class StubServer: URLProtocol {
    static var respond: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let (status, body) = Self.respond(request)
        let url = request.url ?? URL(fileURLWithPath: "/")
        let headers = status == 302 ? ["Location": "https://elsewhere.example.com/"] : [:]
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
