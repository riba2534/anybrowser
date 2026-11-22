@testable import AnyBrowserCore
import Foundation
import Testing

/// Copies and imports get a new seed but keep their CPU count, so the new seed must select the
/// same GPU and memory or the copy becomes a machine that was never sold.
struct SeedHardwareTests {
    private let hardware = EngineHardwareTable.bundled

    private func sameMachine(_ a: Int, _ b: Int) -> Bool {
        hardware.gpu(for: .macOS, seed: a) == hardware.gpu(for: .macOS, seed: b)
            && hardware.gpu(for: .windows, seed: a) == hardware.gpu(for: .windows, seed: b)
            && hardware.deviceMemory(seed: a) == hardware.deviceMemory(seed: b)
            && hardware.defaultCPUCount(seed: a) == hardware.defaultCPUCount(seed: b)
    }

    @Test("A replacement seed selects the same hardware and is free")
    func replacementKeepsHardware() {
        for original in [1, 2, 77, 78, 105, 4243, 4244, 22223, 44445, Int(Int32.max) - 3] {
            let taken: Set<Int> = [original]
            for _ in 0..<20 {
                let seed = FingerprintSettings.newSeed(excluding: taken, sameHardwareAs: original)
                #expect(seed != original && (1...Int(Int32.max)).contains(seed))
                #expect(sameMachine(seed, original), "\(original) -> \(seed)")
            }
        }
    }

    @Test("Clones and conflicting imports keep a real machine", arguments: [BrowserPlatform.macOS, .windows])
    func cloneAndImportKeepMachine(platform: BrowserPlatform) throws {
        for seed in [4244, 4243, 105, 1000, 44445, 33334] {
            var fingerprint = IdentitySampler.sample(seed: seed, constraints: .init(platforms: [platform]))
            fingerprint.seed = seed
            let profile = try BrowserProfile(name: "Source", port: 9222, fingerprint: fingerprint, proxy: "").validated()
            guard hardware.exists(platform: platform, seed: seed, cpuCount: profile.fingerprint.cpuCount) else { continue }
            for _ in 0..<10 {
                let copy = try ProfileLibrary.clone(profile, existingNames: [profile.name],
                                                    takenPorts: [profile.port], takenSeeds: [seed])
                #expect(copy.fingerprint.seed != seed)
                #expect(hardware.exists(platform: platform, seed: copy.fingerprint.seed, cpuCount: copy.fingerprint.cpuCount))
                #expect(sameMachine(copy.fingerprint.seed, seed))
            }
        }
    }
}
