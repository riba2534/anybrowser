import Darwin
import Foundation

public struct WindowLayout: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var x: Int?
    public var y: Int?

    public init(width: Int, height: Int, x: Int? = nil, y: Int? = nil) {
        self.width = width
        self.height = height
        self.x = x
        self.y = y
    }
}

/// The display a Profile claims, in Chromium's screen coordinates: the origin is the top left of
/// the main display and y grows downwards. A window has to stay inside it, so that the
/// `window.outer*` a page reads never outgrows `screen.*` — one comparison a server can make.
public struct ProfileScreen: Equatable, Sendable {
    public var platform: BrowserPlatform
    public var width: Int
    public var height: Int
    public var availWidth: Int
    public var availHeight: Int

    public init(platform: BrowserPlatform, width: Int, height: Int, availWidth: Int, availHeight: Int) {
        self.platform = platform
        self.width = width
        self.height = height
        self.availWidth = availWidth
        self.availHeight = availHeight
    }

    /// The strip the menu bar takes at the top, which the usable area leaves out. Windows and
    /// Linux keep their taskbar at the bottom, so their usable area starts at the top edge.
    public var topInset: Int { platform == .macOS ? max(height - availHeight, 0) : 0 }

    /// The part of the screen a window may fill, below the menu bar and beside the Dock.
    public var usableArea: WindowArrangement.Frame {
        WindowArrangement.Frame(left: 0, top: topInset, width: availWidth, height: availHeight)
    }
}

/// A fixed sequence drawn from the Profile's seed, so the same Profile derives the same window on
/// every launch and a self-check can judge the window it opened.
private struct ProfileWindowRandom {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed)) &* 0x9E37_79B9_7F4A_7C15 &+ 0x2545_F491_4F6C_DD1D
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int((state >> 33) % span)
    }
}

extension FingerprintSettings {
    /// The display this Profile claims in its fingerprint; nil when it claims none.
    public var profileScreen: ProfileScreen? {
        guard let width = screenWidth, let height = screenHeight else { return nil }
        return ProfileScreen(platform: platform ?? .macOS, width: width, height: height,
                             availWidth: min(availWidth ?? width, width),
                             availHeight: min(availHeight ?? height, height))
    }
}

extension LaunchOptions {
    /// The window the Profile opens with. A configured layout is clamped into the Profile's own
    /// screen, and one is derived from that screen when none is configured: 72–88% wide, 68–82%
    /// high, 20–80 px clear of the usable edges, so `outer` never outgrows `screen`. Without a
    /// screen the configured layout passes as it is, and without either there is no window.
    func effectiveWindow(for fingerprint: FingerprintSettings) -> WindowLayout? {
        guard let screen = fingerprint.profileScreen else { return window }
        var random = ProfileWindowRandom(seed: fingerprint.seed)
        guard let window else { return Self.derivedWindow(in: screen, using: &random) }
        return Self.clamped(window, into: screen, using: &random)
    }

    private static func derivedWindow(in screen: ProfileScreen, using random: inout ProfileWindowRandom) -> WindowLayout {
        let margin = random.next(in: 20...80)
        let width = size(percent: random.next(in: 72...88), of: screen.width,
                         limit: screen.availWidth - margin, least: 400)
        let height = size(percent: random.next(in: 68...82), of: screen.height,
                          limit: screen.availHeight - margin, least: 300)
        return WindowLayout(width: width, height: height,
                            x: random.next(in: 0...max(screen.width - width, 0)),
                            y: screen.topInset + random.next(in: 0...max(screen.height - screen.topInset - height, 0)))
    }

    /// Keeps a configured window inside the screen, below the menu bar and within the usable area;
    /// a position left unset is placed deterministically like a derived one.
    private static func clamped(_ layout: WindowLayout, into screen: ProfileScreen,
                                using random: inout ProfileWindowRandom) -> WindowLayout {
        let width = max(min(layout.width, screen.availWidth), 1)
        let height = max(min(layout.height, screen.availHeight), 1)
        let maxX = max(screen.width - width, 0)
        let maxY = max(screen.height - height, screen.topInset)
        return WindowLayout(width: width, height: height,
                            x: layout.x.map { min(max($0, 0), maxX) } ?? random.next(in: 0...maxX),
                            y: layout.y.map { min(max($0, screen.topInset), maxY) } ?? random.next(in: screen.topInset...maxY))
    }

    private static func size(percent: Int, of total: Int, limit: Int, least: Int) -> Int {
        max(min(max(total * percent / 100, least), limit), 1)
    }
}

/// What a Profile opens with: start pages, window placement and extra unpacked extensions.
public struct LaunchOptions: Codable, Equatable, Sendable {
    public static let maximumStartURLs = 20
    public static let maximumExtensionDirectories = 10

    public var startURLs: [String]
    public var window: WindowLayout?
    /// Absolute paths of unpacked extension directories loaded next to Passkey Box.
    public var extensionDirectories: [String]
    /// Loads the bundled Passkey Box; a Profile that never uses passkeys can leave it out.
    public var loadPasskeyBox: Bool
    /// Reopens the tabs of the last session in addition to the start pages.
    public var restoreSession: Bool
    /// Names of extensions in the shared library (`Extensions/Shared/<name>`) this Profile loads.
    public var sharedExtensions: [String]
    /// Opens an incognito window: no cookies or site data on disk, and a storage quota tied to the
    /// JS heap, which the identity script compresses further.
    public var incognito: Bool

    public init(startURLs: [String] = [], window: WindowLayout? = nil, extensionDirectories: [String] = [],
                loadPasskeyBox: Bool = true, restoreSession: Bool = false, sharedExtensions: [String] = [],
                incognito: Bool = false) {
        self.startURLs = startURLs
        self.window = window
        self.extensionDirectories = extensionDirectories
        self.loadPasskeyBox = loadPasskeyBox
        self.restoreSession = restoreSession
        self.sharedExtensions = sharedExtensions
        self.incognito = incognito
    }

    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        startURLs = try data.decodeIfPresent([String].self, forKey: .startURLs) ?? []
        window = try data.decodeIfPresent(WindowLayout.self, forKey: .window)
        extensionDirectories = try data.decodeIfPresent([String].self, forKey: .extensionDirectories) ?? []
        loadPasskeyBox = try data.decodeIfPresent(Bool.self, forKey: .loadPasskeyBox) ?? true
        restoreSession = try data.decodeIfPresent(Bool.self, forKey: .restoreSession) ?? false
        sharedExtensions = try data.decodeIfPresent([String].self, forKey: .sharedExtensions) ?? []
        // Options written before the field existed are a normal window.
        incognito = try data.decodeIfPresent(Bool.self, forKey: .incognito) ?? false
    }

    /// Checks the options without touching the disk, so a Profile whose extension folder has
    /// since gone away still loads and imports; see `checkExtensionDirectories()`.
    public func validated() throws -> LaunchOptions {
        var result = LaunchOptions()
        for line in startURLs {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let url = try Self.normalizedStartURL(text)
            if !result.startURLs.contains(url) { result.startURLs.append(url) }
        }
        guard result.startURLs.count <= Self.maximumStartURLs else {
            throw ProfileError.invalid("启动网址最多 \(Self.maximumStartURLs) 个。")
        }

        if let window {
            guard (400...7680).contains(window.width) else {
                throw ProfileError.invalid("窗口宽度须为 400–7680。")
            }
            guard (300...4320).contains(window.height) else {
                throw ProfileError.invalid("窗口高度须为 300–4320。")
            }
            guard (window.x == nil) == (window.y == nil) else {
                throw ProfileError.invalid("窗口位置须同时填写 X 和 Y，或都留空。")
            }
            for value in [window.x, window.y].compactMap({ $0 }) where !(-10000...10000).contains(value) {
                throw ProfileError.invalid("窗口位置须为 -10000–10000。")
            }
            result.window = window
        }

        for path in extensionDirectories {
            guard path.hasPrefix("/"), !path.contains("\0") else {
                throw ProfileError.invalid("扩展目录须为绝对路径：\(path)")
            }
            // Chromium parses --load-extension as a comma-separated list.
            guard !path.contains(",") else {
                throw ProfileError.invalid("扩展目录的路径不能包含逗号：\(path)")
            }
            let cleaned = "/" + path.split(separator: "/").joined(separator: "/")
            if !result.extensionDirectories.contains(cleaned) { result.extensionDirectories.append(cleaned) }
        }
        guard result.extensionDirectories.count <= Self.maximumExtensionDirectories else {
            throw ProfileError.invalid("扩展目录最多 \(Self.maximumExtensionDirectories) 个。")
        }
        result.loadPasskeyBox = loadPasskeyBox
        result.restoreSession = restoreSession
        result.incognito = incognito
        for name in sharedExtensions where !result.sharedExtensions.contains(name) {
            guard Self.isSharedExtensionName(name) else {
                throw ProfileError.invalid("共享扩展名称无效：\(name.prefix(64))")
            }
            result.sharedExtensions.append(name)
        }
        guard result.sharedExtensions.count <= Self.maximumExtensionDirectories else {
            throw ProfileError.invalid("共享扩展最多 \(Self.maximumExtensionDirectories) 个。")
        }
        return result
    }

    /// A shared-library folder name: 1–64 letters, digits, spaces, dots, underscores or hyphens,
    /// starting with a letter or digit, so it is always a single safe path component.
    public static func isSharedExtensionName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-")
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Run right before launch: every extension directory must still hold an unpacked extension.
    public func checkExtensionDirectories() throws {
        if let path = unavailableExtensionDirectories().first {
            throw ProfileError.invalid("扩展目录不可用：\(path)")
        }
    }

    /// Directories that are missing, not directories, or have no manifest.json. Links are
    /// followed, as Chromium does when it loads an unpacked extension.
    public func unavailableExtensionDirectories() -> [String] {
        extensionDirectories.filter { path in
            // Resolving <path>/manifest.json already fails unless the path is a directory.
            var details = stat()
            return stat(path + "/manifest.json", &details) != 0 || details.st_mode & S_IFMT != S_IFREG
        }
    }

    /// Window and session switches. `fingerprint` supplies the screen the window is derived from
    /// and clamped into; without it only a configured window is passed. The start URLs are not
    /// among the switches: `BrowserRuntime` opens them over DevTools once the browser is ready, so
    /// editing them never needs a restart.
    func arguments(for fingerprint: FingerprintSettings? = nil) -> [String] {
        var arguments: [String] = []
        let window = fingerprint.map { effectiveWindow(for: $0) } ?? window
        if let window {
            arguments.append("--window-size=\(window.width),\(window.height)")
            if let x = window.x, let y = window.y {
                arguments.append("--window-position=\(x),\(y)")
            }
        }
        if incognito {
            arguments.append("--incognito")
        }
        if restoreSession {
            arguments.append("--restore-last-session")
        }
        return arguments
    }

    /// Lower-cases the scheme and host and gives an empty path "/", so equal pages compare equal.
    /// Requiring http(s) also keeps a start URL from ever reading as a Chromium switch.
    private static func normalizedStartURL(_ text: String) throws -> String {
        let shown = text.count > 80 ? String(text.prefix(80)) + "…" : text
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.percentEncodedHost, !host.isEmpty,
              (parts.port.map { (1...65535).contains($0) } ?? true) else {
            throw ProfileError.invalid("启动网址须为 http:// 或 https:// 开头、带主机名的完整网址：\(shown)")
        }
        // Credentials in a start URL would show in the process list and in password-free exports.
        guard parts.percentEncodedUser == nil, parts.percentEncodedPassword == nil else {
            throw ProfileError.invalid("启动网址不能包含账号密码：\(shown)")
        }
        parts.scheme = scheme
        parts.percentEncodedHost = host.lowercased()
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        guard let url = parts.string, url.utf8.count <= 2048 else {
            throw ProfileError.invalid("启动网址不能超过 2048 个字符：\(shown)")
        }
        return url
    }
}
