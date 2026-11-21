@testable import AnyBrowserCore
import Foundation
import Testing

struct IdentityShimTests {
    @Test("The shim is limited to engines with the Canvas text factor bug")
    func versionGate() {
        #expect(IdentityShim.isNeeded(for: "148.0.7778.215"))
        #expect(IdentityShim.isNeeded(for: "149.0.0.0"))
        #expect(!IdentityShim.isNeeded(for: "150.0.7871.186"))
        #expect(!IdentityShim.isNeeded(for: "not-a-version"))
    }

    @Test("Preparing the shim writes a main-world extension with the Profile language")
    func preparesExtension() throws {
        let storage = try scratchDirectory("identity-shim")
        defer { try? FileManager.default.removeItem(at: storage) }
        var profile = BrowserProfile(name: "Shim", port: 9301, fingerprint: FingerprintSettings(seed: 1))
        profile.fingerprint.language = "en-US"
        profile.fingerprint.languages = ["en-US", "en"]
        profile = try profile.validated()

        try IdentityShim.prepare(for: profile, in: storage)
        let directory = IdentityShim.directory(in: storage, for: profile.id)
        for name in ["manifest.json", "config.js", "content.js"] {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
        let manifest = try String(contentsOf: directory.appendingPathComponent("manifest.json"), encoding: .utf8)
        let config = try String(contentsOf: directory.appendingPathComponent("config.js"), encoding: .utf8)
        let script = try String(contentsOf: directory.appendingPathComponent("content.js"), encoding: .utf8)
        #expect(manifest.contains("\"world\": \"MAIN\""))
        #expect(manifest.contains("\"all_frames\": true"))
        #expect(config.contains("\"en-US\""))
        #expect(script.contains("anybrowser.identityGuard"))
        #expect(script.contains("measureText"))
        #expect(script.contains("DateTimeFormat"))
    }
}
