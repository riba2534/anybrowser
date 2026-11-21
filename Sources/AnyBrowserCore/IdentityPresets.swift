import Foundation

/// A consistent browser identity (platform, versions, brand, CPU, adjustments) to start from.
public struct IdentityPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    let platform: BrowserPlatform
    let platformVersion: String
    let brand: BrowserBrand
    let brandVersion: String
    /// Logical CPU counts common on this kind of machine; one is picked at random.
    let cpuCounts: [Int]

    /// Fills platform, versions, brand, CPU and adjustments; keeps seed, language and time zone.
    public func apply(to fingerprint: inout FingerprintSettings) {
        fingerprint.platform = platform
        fingerprint.platformVersion = platformVersion
        fingerprint.brand = brand
        fingerprint.brandVersion = brandVersion
        fingerprint.cpuCount = cpuCounts.randomElement()
        fingerprint.adaptToPlatform()
    }

    // Brand versions match the bundled 148 engine. Windows versions are what UA-CH reports:
    // 19.0.0 for Windows 11 24H2, 10.0.0 for Windows 10.
    private static let chromeVersion = "148.0.7778.215"
    private static let edgeVersion = "148.0.3967.54"
    private static let windowsCPUs = [4, 8, 12, 16]
    private static let macCPUs = [8, 10, 12]

    public static let all: [IdentityPreset] = [
        IdentityPreset(id: "win11-chrome", title: "Windows 11 · Chrome", platform: .windows, platformVersion: "19.0.0",
                       brand: .chrome, brandVersion: chromeVersion, cpuCounts: windowsCPUs),
        IdentityPreset(id: "win11-edge", title: "Windows 11 · Edge", platform: .windows, platformVersion: "19.0.0",
                       brand: .edge, brandVersion: edgeVersion, cpuCounts: windowsCPUs),
        IdentityPreset(id: "win10-chrome", title: "Windows 10 · Chrome", platform: .windows, platformVersion: "10.0.0",
                       brand: .chrome, brandVersion: chromeVersion, cpuCounts: windowsCPUs),
        IdentityPreset(id: "macos26-chrome", title: "macOS 26 · Chrome", platform: .macOS, platformVersion: "26.2.0",
                       brand: .chrome, brandVersion: chromeVersion, cpuCounts: macCPUs),
        IdentityPreset(id: "macos15-chrome", title: "macOS 15 · Chrome", platform: .macOS, platformVersion: "15.7.1",
                       brand: .chrome, brandVersion: chromeVersion, cpuCounts: macCPUs),
        IdentityPreset(id: "linux-chrome", title: "Linux · Chrome", platform: .linux, platformVersion: "6.8.0",
                       brand: .chrome, brandVersion: chromeVersion, cpuCounts: [4, 8]),
    ]
}
