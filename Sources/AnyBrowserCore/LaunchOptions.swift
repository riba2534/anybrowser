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

/// What a Profile opens with: start pages, window placement and extra unpacked extensions.
public struct LaunchOptions: Codable, Equatable, Sendable {
    public static let maximumStartURLs = 20
    public static let maximumExtensionDirectories = 10

    public var startURLs: [String]
    public var window: WindowLayout?
    /// Absolute paths of unpacked extension directories loaded next to Passkey Box.
    public var extensionDirectories: [String]

    public init(startURLs: [String] = [], window: WindowLayout? = nil, extensionDirectories: [String] = []) {
        self.startURLs = startURLs
        self.window = window
        self.extensionDirectories = extensionDirectories
    }

    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        startURLs = try data.decodeIfPresent([String].self, forKey: .startURLs) ?? []
        window = try data.decodeIfPresent(WindowLayout.self, forKey: .window)
        extensionDirectories = try data.decodeIfPresent([String].self, forKey: .extensionDirectories) ?? []
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
        return result
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

    /// Window switches, then the start URLs (positional, always last).
    func arguments() -> [String] {
        var arguments: [String] = []
        if let window {
            arguments.append("--window-size=\(window.width),\(window.height)")
            if let x = window.x, let y = window.y {
                arguments.append("--window-position=\(x),\(y)")
            }
        }
        return arguments + startURLs
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
        parts.scheme = scheme
        parts.percentEncodedHost = host.lowercased()
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        guard let url = parts.string, url.utf8.count <= 2048 else {
            throw ProfileError.invalid("启动网址不能超过 2048 个字符：\(shown)")
        }
        return url
    }
}
