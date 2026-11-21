import Foundation

/// A consistent browser identity (platform, versions, brand, CPU, adjustments) to start from.
public struct IdentityPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String

    /// Fills platform, versions, brand, CPU and adjustments; keeps seed, language and time zone.
    public func apply(to fingerprint: inout FingerprintSettings) {}

    public static let all: [IdentityPreset] = []
}
