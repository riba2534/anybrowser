import Foundation

/// What the runtime and the AnyBrowserRelay helper process agree on. The helper runs a Profile's
/// `ProxyRelay` beside its browser, so the browser keeps its network when AnyBrowser quits.
public enum RelayHelper {
    public static let executableName = "AnyBrowserRelay"
    /// In the Profile's data directory; the helper writes its port there once it listens.
    public static let portFileName = ".anybrowser-relay.port"
    /// How long the helper waits, once the browser it watches exits, for a browser that relaunched
    /// itself (chrome://restart) to hold the data directory again.
    public static let defaultRelaunchGrace: TimeInterval = 10

    /// The live process holding `directory`'s SingletonLock, when it is a browser on exactly that
    /// directory whose proxy is the relay on `port`.
    public static func browser(holding directory: URL, through port: Int) -> Int32? {
        guard let pid = ProcessInspection.lockHolder(directory), let arguments = ProcessInspection.arguments(pid),
              ProcessInspection.hasFlag("--user-data-dir", value: directory.path, arguments: arguments),
              ProcessInspection.hasFlag("--proxy-server", value: "http://127.0.0.1:\(port)", arguments: arguments)
        else { return nil }
        return pid
    }
}
