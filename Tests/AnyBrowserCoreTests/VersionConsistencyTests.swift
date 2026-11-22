import AnyBrowserCore
import Foundation
import Testing

struct VersionConsistencyTests {
    /// scripts/versions.env, which build-app.sh embeds from: one `key=value` per line.
    static func pinnedVersions() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("scripts/versions.env"), encoding: .utf8)
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
        }
        return values
    }

    @Test("BundledVersions names the engine and Passkey Box that build-app.sh embeds")
    func bundledVersionsMatchThePackagingScript() throws {
        let pinned = try Self.pinnedVersions()
        #expect(pinned["engine_version"] == BundledVersions.engine)
        #expect(pinned["passkey_version"] == BundledVersions.passkeyBox)
    }
}
