import CryptoKit
import Foundation

/// The Stripe device id (`__stripe_mid` prefix) this Profile presents.
///
/// The id is a lowercase UUIDv4. Stripe accepts the bare 36 characters and completes them to 42
/// with a deterministic checksum, echoing the same value back; the client-side cookie writer only
/// checks the length, so a value of any other shape would be stored but replaced on every report.
/// The id is minted when a Profile is created and kept for the identity's lifetime, so a
/// restart is the same device. `seed`/`platform` derive a fallback for rows written before this
/// field existed and for copies that must not inherit it.
public enum DeviceIdentity {
    /// A new random lowercase UUIDv4.
    public static func mint() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return format(bytes)
    }

    /// The value for a Profile without one: stable for the same seed and platform, distinct across
    /// them. Both inputs go into the digest, so changing either yields a different device.
    public static func derived(seed: Int, platform: BrowserPlatform?) -> String {
        let material = "anybrowser.stripe.mid.v1|\(seed)|\(platform?.rawValue ?? "host")"
        let digest = SHA256.hash(data: Data(material.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return format(bytes)
    }

    /// The id this Profile uses: its own, or the derived fallback while it has none.
    public static func effective(_ profile: BrowserProfile) -> String {
        profile.deviceIdentity ?? derived(seed: profile.fingerprint.seed, platform: profile.fingerprint.platform)
    }

    /// A lowercase UUIDv4 in canonical 8-4-4-4-12 form.
    public static func isValid(_ text: String) -> Bool {
        text.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}([0-9a-f]{6})?$"#,
                    options: .regularExpression) == text.startIndex..<text.endIndex
    }

    private static func format(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [hex.prefix(8),
                hex.dropFirst(8).prefix(4),
                hex.dropFirst(12).prefix(4),
                hex.dropFirst(16).prefix(4),
                hex.dropFirst(20)].map(String.init).joined(separator: "-")
    }
}