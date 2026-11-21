import AnyBrowserCore
import Combine
import Foundation

/// Proxy reachability and exit information per Profile.
@MainActor
final class ProxyCenter: ObservableObject {}

extension Workbench {
    /// Checked before a Profile starts; returns a warning to show (the launch still goes ahead).
    func proxyPreflight(_ profile: BrowserProfile) async -> String? {
        nil
    }
}
