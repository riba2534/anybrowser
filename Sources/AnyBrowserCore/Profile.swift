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

public enum ProfileError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

extension BrowserProfile {
    public func validated() throws -> BrowserProfile {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 80,
              !result.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProfileError.invalid("输入 1–80 字的 Profile 名称。")
        }
        guard (1024...65535).contains(port) else {
            throw ProfileError.invalid("调试端口须为 1024–65535。")
        }
        try fingerprint.validate()
        return result
    }

    public func launchArguments(userDataDirectory: URL) -> [String] {
        let settings = fingerprint
        var arguments = [
            "--user-data-dir=\(userDataDirectory.path)",
            "--remote-debugging-port=\(port)",
            "--no-first-run",
            "--no-default-browser-check",
            "--fingerprint=\(settings.seed)",
        ]
        if let platform = settings.platform {
            arguments.append("--fingerprint-platform=\(platform.rawValue)")
        }
        if !settings.platformVersion.isEmpty {
            arguments.append("--fingerprint-platform-version=\(settings.platformVersion)")
        }
        if let brand = settings.brand {
            arguments.append("--fingerprint-brand=\(brand.rawValue)")
        }
        if !settings.brandVersion.isEmpty {
            arguments.append("--fingerprint-brand-version=\(settings.brandVersion)")
        }
        if let cpuCount = settings.cpuCount {
            arguments.append("--fingerprint-hardware-concurrency=\(cpuCount)")
        }
        if !settings.language.isEmpty {
            arguments.append("--lang=\(settings.language)")
            let base = settings.language.split(separator: "-").first.map(String.init)
            let accepted = base == settings.language ? settings.language : [settings.language, base].compactMap { $0 }.joined(separator: ",")
            arguments.append("--accept-lang=\(accepted)")
        }
        if !settings.timeZone.isEmpty {
            arguments.append("--timezone=\(settings.timeZone)")
        }
        let disabled = FingerprintAdjustment.allCases.filter { !settings.adjustments.contains($0) }
        if !disabled.isEmpty {
            arguments.append("--disable-spoofing=\(disabled.map(\.rawValue).joined(separator: ","))")
        }
        return arguments
    }
}

extension FingerprintSettings {
    fileprivate func validate() throws {
        guard (1...Int(Int32.max)).contains(seed) else {
            throw ProfileError.invalid("指纹种子须为 1–2147483647 的整数。")
        }
        if let cpuCount, !(1...256).contains(cpuCount) {
            throw ProfileError.invalid("逻辑 CPU 数须为 1–256。")
        }
        for version in [platformVersion, brandVersion] where !version.isEmpty {
            guard version.range(of: #"^[0-9]{1,9}(\.[0-9]{1,9}){0,3}$"#, options: .regularExpression) == version.startIndex..<version.endIndex else {
                throw ProfileError.invalid("版本须由 1–4 段数字组成，例如 26.0.0。")
            }
        }
        if platform == nil, !platformVersion.isEmpty {
            throw ProfileError.invalid("先选择平台，再指定平台版本。")
        }
        if brand == .opera || brand == .vivaldi, brandVersion.isEmpty {
            throw ProfileError.invalid("Opera 和 Vivaldi 需要显式填写品牌版本。")
        }
        if !language.isEmpty,
           language.range(of: #"^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$"#, options: .regularExpression) != language.startIndex..<language.endIndex {
            throw ProfileError.invalid("输入有效的语言标签，例如 zh-CN 或 en-US。")
        }
        if !timeZone.isEmpty, !TimeZone.knownTimeZoneIdentifiers.contains(timeZone) && timeZone != "UTC" {
            throw ProfileError.invalid("输入 IANA 时区，例如 Asia/Shanghai 或 UTC。")
        }
    }

    mutating func randomize(_ fields: Set<FingerprintField>, excluding seeds: Set<Int>) {
        if fields.contains(.seed) {
            seed = Self.newSeed(excluding: seeds.union([seed]))
        }
        if fields.contains(.platform) {
            platform = BrowserPlatform.allCases.randomElement()
        }
        if fields.contains(.platformVersion) {
            platformVersion = switch platform {
            case .macOS: ["15.7.1", "26.2.0", "26.4.1"].randomElement()!
            case .windows: "19.0.0"
            case .linux: ["6.8.0", "6.14.0"].randomElement()!
            case nil: ""
            }
        }
        if fields.contains(.brand) {
            brand = [BrowserBrand.chrome, .edge].randomElement()
        }
        if fields.contains(.brandVersion) {
            brandVersion = switch brand {
            case .edge: ["148.0.3967.54", "148.0.3967.96", "148.0.3967.73"].randomElement()!
            case .opera, .vivaldi: "\(Int.random(in: 1...99)).0"
            default: ["148.0.7778.215", "148.0.7778.217", "148.0.7778.168"].randomElement()!
            }
        }
        if fields.contains(.cpuCount) {
            cpuCount = [4, 6, 8, 10, 12, 16, 24, 32].randomElement()
        }
        if fields.contains(.language) {
            language = ["zh-CN", "zh-TW", "en-US", "en-GB", "fr-FR", "de-DE", "ja-JP", "ko-KR"].randomElement()!
        }
        if fields.contains(.timeZone) {
            timeZone = ["UTC", "Asia/Shanghai", "Asia/Tokyo", "America/New_York", "Europe/London", "Europe/Paris"].randomElement()!
        }
        if fields.contains(.adjustments) {
            adjustments = Set(FingerprintAdjustment.allCases.filter { _ in Bool.random() })
            if platform == .linux {
                adjustments.remove(.gpu)
            }
        }
    }

    static func newSeed(excluding seeds: Set<Int>) -> Int {
        var value: Int
        repeat { value = Int.random(in: 1...Int(Int32.max)) } while seeds.contains(value)
        return value
    }
}
