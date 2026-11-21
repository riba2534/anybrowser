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

    public func validated() throws -> LaunchOptions {
        self
    }

    /// Window switches, then the start URLs (positional, always last).
    func arguments() -> [String] {
        []
    }
}
