@testable import AnyBrowserCore
import Foundation
import Testing

/// The incognito mark: it reaches the identity script as private mode, and the self-check judges
/// the compressed storage quota only when the Profile opens incognito.
struct IncognitoTests {
    private func profile(incognito: Bool) -> BrowserProfile {
        var profile = BrowserProfile(name: "Private", port: 9330,
                                     fingerprint: FingerprintSettings(seed: 22223), proxy: "")
        profile.launch.incognito = incognito
        return profile
    }

    private func observation(quota: Double = 1500, heapLimit: Double = 1000) -> SelfCheckObservation {
        let realm = SelfCheckObservation.Realm(
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/148.0.0.0",
            platform: "MacIntel", hardwareConcurrency: 8, deviceMemory: 16, language: "en-US",
            languages: ["en-US"], timeZone: "UTC", locale: "en-US",
            dateString: "Thu Jan 15 2026 12:00:00 GMT+0000 (Coordinated Universal Time)",
            measureText: 337, webGLVendor: nil, webGLRenderer: nil)
        return SelfCheckObservation(
            main: realm, worker: nil, frame: nil, clientHints: nil,
            screen: .init(width: 1440, height: 900, availWidth: 1440, availHeight: 875,
                          colorDepth: 24, devicePixelRatio: 2),
            storage: .init(usage: 100, quota: quota, heapLimit: heapLimit),
            canvasMeasureText: 337, canvasStable: true, markers: [],
            expectedZoneName: "Coordinated Universal Time")
    }

    @Test("Incognito reaches the identity script as private mode")
    func privateScript() throws {
        let storage = try scratchDirectory("incognito")
        defer { try? FileManager.default.removeItem(at: storage) }
        let privateProfile = profile(incognito: true)
        try IdentityShim.prepare(for: privateProfile, in: storage)
        let dir = IdentityShim.directory(in: storage, for: privateProfile.id)
        let script = try String(contentsOf: dir.appendingPathComponent("content.js"), encoding: .utf8)
        #expect(script.contains("const priv = true;"))

        let normal = profile(incognito: false)
        try IdentityShim.prepare(for: normal, in: storage)
        let plain = try String(contentsOf: IdentityShim.directory(in: storage, for: normal.id)
            .appendingPathComponent("content.js"), encoding: .utf8)
        #expect(plain.contains("const priv = false;"))
    }

    @Test("SelfCheck requires a compressed quota only in private mode")
    func quotaExpectation() throws {
        let privateProfile = profile(incognito: true)
        let pass = try #require(SelfCheck.report(for: privateProfile, exit: nil,
                                                 observation: observation()).item("storage-quota"))
        #expect(pass.status == .pass)
        #expect(pass.expected == "≤ 1500")

        let over = SelfCheck.report(for: privateProfile, exit: nil, observation: observation(quota: 9000))
            .item("storage-quota")
        #expect(over?.status == .fail)
        #expect(over?.note?.contains("1.5 × JS 堆上限") == true)

        // A zero quota means the page could not read it at all.
        #expect(SelfCheck.report(for: privateProfile, exit: nil, observation: observation(quota: 0))
            .item("storage-quota")?.status == .fail)

        let normal = try #require(SelfCheck.report(for: profile(incognito: false), exit: nil,
                                                   observation: observation()).item("storage-quota"))
        #expect(normal.status == .info)
        #expect(normal.expected == nil)

        // Without a readable heap the script falls back to the claimed memory.
        var memory = privateProfile
        memory.fingerprint.deviceMemory = 16
        #expect(SelfCheck.report(for: memory, exit: nil, observation: observation(heapLimit: 0))
            .item("storage-quota")?.status == .pass)
    }
}