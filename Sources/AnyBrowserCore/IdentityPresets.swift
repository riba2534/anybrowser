import Foundation

/// A consistent browser identity (platform, versions, brand, CPU, adjustments) to start from.
public struct IdentityPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// The engine cannot make this identity whole: Windows identities still show this Mac's fonts,
    /// voices and WebGPU adapter. The title says so as well.
    public let isExperimental: Bool
    let platform: BrowserPlatform
    /// Released versions as UA-CH reports them; one is picked at random.
    let platformVersions: [String]
    let brand: BrowserBrand

    /// Fills platform, versions, brand, CPU and adjustments; keeps seed, language and time zone.
    ///
    /// Chrome and Edge versions are left empty: the engine then picks a released build by seed,
    /// and only then sends Edge's reduced `Edg/<major>.0.0.0`. The CPU count follows the GPU the
    /// seed gives WebGL, so the two describe a machine that exists.
    public func apply(to fingerprint: inout FingerprintSettings) {
        fingerprint.platform = platform
        fingerprint.platformVersion = platformVersions.randomElement() ?? ""
        fingerprint.brand = brand
        fingerprint.brandVersion = ""
        // Without WebGL spoofing pages read this Mac's GPU, e.g. after switching from a Linux identity.
        if platform != .linux {
            fingerprint.adjustments.insert(.gpu)
        }
        fingerprint.cpuCount = IdentitySampler.randomCPUCount(for: platform, seed: fingerprint.seed,
                                                              spoofsGPU: fingerprint.adjustments.contains(.gpu))
        fingerprint.deviceMemory = EngineHardwareTable.bundled.deviceMemory(seed: fingerprint.seed)
        fingerprint.adaptToPlatform()
    }

    private init(id: String, title: String, experimental: Bool = false, platform: BrowserPlatform,
                 versions: [String], brand: BrowserBrand) {
        self.id = id
        self.title = experimental ? "\(title)（实验性）" : title
        self.isExperimental = experimental
        self.platform = platform
        self.platformVersions = versions
        self.brand = brand
    }

    // Windows versions are what UA-CH reports: 19.0.0 for Windows 11 24H2, 10.0.0 for Windows 10.
    // macOS minors are the releases current when the bundled engine's Chrome version shipped, plus
    // macOS 27, which a Mac can run with an older Chrome.
    public static let all: [IdentityPreset] = [
        IdentityPreset(id: "win11-chrome", title: "Windows 11 · Chrome", experimental: true, platform: .windows,
                       versions: ["19.0.0"], brand: .chrome),
        IdentityPreset(id: "win11-edge", title: "Windows 11 · Edge", experimental: true, platform: .windows,
                       versions: ["19.0.0"], brand: .edge),
        IdentityPreset(id: "win10-chrome", title: "Windows 10 · Chrome", experimental: true, platform: .windows,
                       versions: ["10.0.0"], brand: .chrome),
        IdentityPreset(id: "macos27-chrome", title: "macOS 27 · Chrome", platform: .macOS,
                       versions: ["27.0.0", "27.1.0", "27.2.0", "27.2.1"], brand: .chrome),
        IdentityPreset(id: "macos26-chrome", title: "macOS 26 · Chrome", platform: .macOS,
                       versions: ["26.3.0", "26.3.1", "26.4.0", "26.4.1"], brand: .chrome),
        IdentityPreset(id: "macos15-chrome", title: "macOS 15 · Chrome", platform: .macOS,
                       versions: ["15.6.1", "15.7.0", "15.7.1", "15.7.2"], brand: .chrome),
        IdentityPreset(id: "linux-chrome", title: "Linux · Chrome", platform: .linux,
                       versions: ["6.8.0", "6.14.0"], brand: .chrome),
    ]
}
