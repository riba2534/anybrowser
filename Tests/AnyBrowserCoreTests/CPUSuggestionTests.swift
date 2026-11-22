@testable import AnyBrowserCore
import Testing

/// Profiles from 0.4.0 often pair a seed's GPU with a CPU count no such machine has; the editor
/// offers the nearest real count without touching the seed.
struct CPUSuggestionTests {
    private func mac(seed: Int, cpus: Int?) -> FingerprintSettings {
        var fingerprint = FingerprintSettings(seed: seed)
        fingerprint.platform = .macOS
        fingerprint.adjustments = [.canvas, .clientRects, .gpu]
        fingerprint.cpuCount = cpus
        return fingerprint
    }

    private let engine = BundledVersions.engine

    @Test("The nearest real CPU count for the seed's machine, fewer cores on a tie")
    func suggestsNearest() {
        // Even seeds report an M4 (8 or 10 cores), odd seeds an M2 (8 cores); seed % 3 picks memory.
        #expect(mac(seed: 4, cpus: 12).suggestedCPUCount(engineVersion: engine) == 10)  // M4, 16 GB
        #expect(mac(seed: 4, cpus: 9).suggestedCPUCount(engineVersion: engine) == 8)
        #expect(mac(seed: 1, cpus: 12).suggestedCPUCount(engineVersion: engine) == 8)   // M2, 16 GB
    }

    @Test("Nothing to suggest when the CPU count fits or the memory cannot")
    func noSuggestion() {
        #expect(mac(seed: 4, cpus: 10).suggestedCPUCount(engineVersion: engine) == nil)
        #expect(mac(seed: 5, cpus: 12).suggestedCPUCount(engineVersion: engine) == nil)  // M2 with 32 GB
        var plain = mac(seed: 4, cpus: 12)
        plain.adjustments = [.canvas]
        #expect(plain.suggestedCPUCount(engineVersion: engine) == nil)
        #expect(mac(seed: 4, cpus: 12).suggestedCPUCount(engineVersion: "99.0") == nil)
    }

    @Test("Applying the suggestion clears the hardware hint")
    func suggestionClearsHint() throws {
        var fingerprint = mac(seed: 4, cpus: 12)
        let profile = BrowserProfile(name: "P", port: 9222, fingerprint: fingerprint, proxy: "")
        #expect(profile.consistencyIssues(engineVersion: engine, exit: nil).contains { $0.id == "hardware-impossible" })
        let suggested = try #require(fingerprint.suggestedCPUCount(engineVersion: engine))
        fingerprint.cpuCount = suggested
        let fixed = BrowserProfile(name: "P", port: 9222, fingerprint: fingerprint, proxy: "")
        #expect(!fixed.consistencyIssues(engineVersion: engine, exit: nil).contains { $0.id == "hardware-impossible" })
    }
}
