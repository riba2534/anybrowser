import Foundation

public enum BrowserPlatform: String, CaseIterable, Codable, Sendable {
    case macOS = "macos", windows, linux

    public var title: String {
        switch self {
        case .macOS: return "macOS"
        case .windows: return "Windows"
        case .linux: return "Linux"
        }
    }
}

public enum BrowserBrand: String, CaseIterable, Codable, Sendable {
    case chrome = "Chrome", edge = "Edge", opera = "Opera", vivaldi = "Vivaldi"
}

public enum FingerprintAdjustment: String, CaseIterable, Codable, Sendable {
    case font, audio, canvas, clientRects = "clientrects", gpu

    public var title: String {
        switch self {
        case .font: return "字体"
        case .audio: return "音频"
        case .canvas: return "Canvas"
        case .clientRects: return "元素坐标"
        case .gpu: return "WebGL 参数"
        }
    }
}

public enum FingerprintField: String, CaseIterable, Hashable, Sendable {
    case seed, platform, platformVersion, brand, brandVersion, cpuCount, language, timeZone, adjustments

    public var title: String {
        switch self {
        case .seed: return "指纹种子"
        case .platform: return "平台"
        case .platformVersion: return "平台版本"
        case .brand: return "浏览器品牌"
        case .brandVersion: return "品牌版本"
        case .cpuCount: return "逻辑 CPU"
        case .language: return "语言"
        case .timeZone: return "时区"
        case .adjustments: return "指纹改写项"
        }
    }
}

public struct FingerprintSettings: Codable, Equatable, Sendable {
    public var seed: Int
    public var platform: BrowserPlatform? = nil
    public var platformVersion = ""
    public var brand: BrowserBrand? = nil
    public var brandVersion = ""
    public var cpuCount: Int? = nil
    public var language = ""
    public var timeZone = ""
    public var adjustments: Set<FingerprintAdjustment> = [.canvas, .clientRects]

    public init(seed: Int) {
        self.seed = seed
    }
}

public struct BrowserProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var port: Int
    public var fingerprint: FingerprintSettings

    public init(id: UUID = UUID(), name: String, port: Int, fingerprint: FingerprintSettings) {
        self.id = id
        self.name = name
        self.port = port
        self.fingerprint = fingerprint
    }
}

public enum BrowserRunState: Equatable, Sendable {
    case stopped, starting, stopping
    case running(pid: Int32, port: Int, debugReady: Bool)
    case failed(String)
}
