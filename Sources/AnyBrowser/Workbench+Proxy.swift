import AnyBrowserCore
import Combine
import Foundation

/// Proxy reachability and exit information per Profile.
@MainActor
final class ProxyCenter: ObservableObject {
    /// The latest successful exit lookup for a Profile, if any.
    func exit(for id: UUID) -> ProxyExit? { nil }
}

extension Workbench {
    /// Checked before a Profile starts; returns a warning to show (the launch still goes ahead).
    func proxyPreflight(_ profile: BrowserProfile) async -> String? {
        nil
    }
}
