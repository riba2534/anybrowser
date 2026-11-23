import Foundation

/// Makes a Profile keep third-party cookies instead of blocking them.
///
/// The bundled engine ships with third-party cookies blocked, which is not what a stock Chrome or
/// Chromium 148 does. The visible effect on Stripe is that `.m.stripe.com`'s HttpOnly `m` is
/// dropped, so every report lands without it and the server issues a fresh guid each time. Profile
/// level `cookie_controls_mode = 0` in `Default/Preferences` restores the stock behaviour; the
/// top-level key and `block_third_party_cookies` do not. The value survives a browser launch, which
/// rewrites its own preferences around it.
public enum ThirdPartyCookiePosture {
    /// The largest Preferences file worth rewriting; anything bigger is left as it is.
    private static let maximumBytes = 8 * 1024 * 1024

    /// Sets the Profile's posture. Best effort: a Profile whose preferences cannot be read or
    /// written still launches, only with the engine default.
    public static func apply(in directory: URL) throws {
        try PrivateDirectory.ensure(directory)
        let defaultDirectory = directory.appendingPathComponent("Default", isDirectory: true)
        try PrivateDirectory.ensure(defaultDirectory)
        let url = defaultDirectory.appendingPathComponent("Preferences")
        var root: [String: Any] = [:]
        var details = stat()
        if lstat(url.path, &details) == 0, details.st_mode & S_IFMT == S_IFREG {
            let data = try PrivateFile.read(url, limit: maximumBytes, failure: "无法读取 Profile 的偏好设置。")
            if !data.isEmpty {
                guard data.count <= maximumBytes,
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ProfileError.invalid("Profile 的偏好设置不是可识别的 JSON，已保留原样。")
                }
                root = parsed
            }
        }
        var profile = root["profile"] as? [String: Any] ?? [:]
        // Chromium reformats this file on every quit, so comparing bytes would always miss.
        if profile["cookie_controls_mode"] as? Int == 0 { return }
        profile["cookie_controls_mode"] = 0
        root["profile"] = profile
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else {
            throw ProfileError.invalid("无法写入 Profile 的偏好设置。")
        }
        try PrivateFile.update(data, at: url, failure: "无法写入 Profile 的偏好设置。")
    }
}