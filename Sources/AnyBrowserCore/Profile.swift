import Darwin
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
    public static let defaultProxy = "127.0.0.1:7890"

    public var id: UUID
    public var name: String
    public var port: Int
    public var fingerprint: FingerprintSettings
    public var proxy: String
    /// Free-form group shown in the sidebar; empty means ungrouped.
    public var group: String
    public var notes: String
    /// This Profile's own Passkey Box account; nil uses the account set in AnyBrowser.
    public var passkeyBox: PasskeyBoxAccount?
    public var launch: LaunchOptions

    public init(id: UUID = UUID(), name: String, port: Int, fingerprint: FingerprintSettings,
                proxy: String = BrowserProfile.defaultProxy, group: String = "", notes: String = "",
                passkeyBox: PasskeyBoxAccount? = nil, launch: LaunchOptions = LaunchOptions()) {
        self.id = id
        self.name = name
        self.port = port
        self.fingerprint = fingerprint
        self.proxy = proxy
        self.group = group
        self.notes = notes
        self.passkeyBox = passkeyBox
        self.launch = launch
    }

    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        id = try data.decode(UUID.self, forKey: .id)
        name = try data.decode(String.self, forKey: .name)
        port = try data.decode(Int.self, forKey: .port)
        fingerprint = try data.decode(FingerprintSettings.self, forKey: .fingerprint)
        proxy = try data.decodeIfPresent(String.self, forKey: .proxy) ?? Self.defaultProxy
        group = try data.decodeIfPresent(String.self, forKey: .group) ?? ""
        notes = try data.decodeIfPresent(String.self, forKey: .notes) ?? ""
        passkeyBox = try data.decodeIfPresent(PasskeyBoxAccount.self, forKey: .passkeyBox)
        launch = try data.decodeIfPresent(LaunchOptions.self, forKey: .launch) ?? LaunchOptions()
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
        result.proxy = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try ProxyEndpoint.parse(result.proxy)
        result.group = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.group.count <= 40,
              !result.group.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProfileError.invalid("分组名称最多 40 个字符。")
        }
        guard notes.count <= 2000 else {
            throw ProfileError.invalid("备注最多 2000 个字符。")
        }
        result.passkeyBox = try passkeyBox?.validated()
        result.launch = try launch.validated()
        return result
    }

    /// Chromium arguments for this Profile. `extensions` are the unpacked extension directories
    /// it loads; start URLs always come last.
    public func launchArguments(userDataDirectory: URL, extensions: [URL] = []) -> [String] {
        var arguments = [
            "--user-data-dir=\(userDataDirectory.path)",
            "--remote-debugging-port=\(port)",
            "--no-first-run",
            "--no-default-browser-check",
            "--fingerprint=\(fingerprint.seed)",
        ]
        if let endpoint = try? ProxyEndpoint.parse(proxy) {
            arguments.append("--proxy-server=\(endpoint.server)")
        }
        arguments += fingerprint.arguments()
        if !extensions.isEmpty {
            // Chromium parses --load-extension as a comma-separated list.
            arguments.append("--load-extension=\(extensions.map(\.path).joined(separator: ","))")
        }
        arguments += launch.arguments()
        return arguments
    }
}

extension FingerprintSettings {
    /// The fingerprint switches after `--fingerprint=<seed>`.
    func arguments() -> [String] {
        var arguments: [String] = []
        if let platform {
            arguments.append("--fingerprint-platform=\(platform.rawValue)")
        }
        if !platformVersion.isEmpty {
            arguments.append("--fingerprint-platform-version=\(platformVersion)")
        }
        if let brand {
            arguments.append("--fingerprint-brand=\(brand.rawValue)")
        }
        if !brandVersion.isEmpty {
            arguments.append("--fingerprint-brand-version=\(brandVersion)")
        }
        if let cpuCount {
            arguments.append("--fingerprint-hardware-concurrency=\(cpuCount)")
        }
        if !language.isEmpty {
            arguments.append("--lang=\(language)")
            let base = language.split(separator: "-").first.map(String.init)
            let accepted = base == language ? language : [language, base].compactMap { $0 }.joined(separator: ",")
            arguments.append("--accept-lang=\(accepted)")
        }
        if !timeZone.isEmpty {
            arguments.append("--timezone=\(timeZone)")
        }
        // The engine has no Linux GPU values to spoof WebGL with; say so rather than rely on it.
        let disabled = FingerprintAdjustment.allCases.filter {
            !adjustments.contains($0) || ($0 == .gpu && platform == .linux)
        }
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
        if brand == nil, !brandVersion.isEmpty {
            throw ProfileError.invalid("先选择浏览器品牌，再指定品牌版本。")
        }
        if brand == .opera || brand == .vivaldi, brandVersion.isEmpty {
            throw ProfileError.invalid("Opera 和 Vivaldi 需要显式填写品牌版本。")
        }
        if !language.isEmpty, !Self.isLanguageTag(language) {
            throw ProfileError.invalid("输入有效的语言标签，例如 zh-CN 或 en-US。")
        }
        if !timeZone.isEmpty, !Self.isTimeZone(timeZone) {
            throw ProfileError.invalid("输入 IANA 时区，例如 Asia/Shanghai 或 UTC。")
        }
    }

    /// A language tag such as zh-CN or en-US, as a whole.
    static func isLanguageTag(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$"#, options: .regularExpression) == text.startIndex..<text.endIndex
    }

    /// An IANA time zone this Mac knows, or UTC.
    static func isTimeZone(_ text: String) -> Bool {
        TimeZone.knownTimeZoneIdentifiers.contains(text) || text == "UTC"
    }

    mutating func randomize(_ fields: Set<FingerprintField>, excluding seeds: Set<Int>) {
        if fields.contains(.seed) {
            seed = Self.newSeed(excluding: seeds.union([seed]))
        }
        if fields.contains(.platform) {
            platform = BrowserPlatform.allCases.randomElement()
        }
        // A version kept from the previous platform or brand would contradict the new one.
        if fields.contains(.platformVersion) || fields.contains(.platform) && !platformVersion.isEmpty {
            platformVersion = Self.randomPlatformVersion(for: platform)
        }
        if fields.contains(.brand) {
            brand = BrowserBrand.allCases.randomElement()
        }
        if fields.contains(.brandVersion) {
            brandVersion = Self.randomBrandVersion(for: brand)
        } else if fields.contains(.brand) {
            // Opera and Vivaldi have no engine default; an empty Chrome or Edge version follows the engine.
            brandVersion = brand == .opera || brand == .vivaldi || !brandVersion.isEmpty
                ? Self.randomBrandVersion(for: brand) : ""
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
        }
        adaptToPlatform()
    }

    /// Drops what the platform cannot use: a version without a platform, and WebGL spoofing on Linux.
    public mutating func adaptToPlatform() {
        if platform == nil {
            platformVersion = ""
        }
        if platform == .linux {
            adjustments.remove(.gpu)
        }
    }

    private static func randomPlatformVersion(for platform: BrowserPlatform?) -> String {
        switch platform {
        case .macOS: return ["15.7.1", "26.2.0", "26.4.1"].randomElement()!
        case .windows: return "19.0.0"
        case .linux: return ["6.8.0", "6.14.0"].randomElement()!
        case nil: return ""
        }
    }

    private static func randomBrandVersion(for brand: BrowserBrand?) -> String {
        switch brand {
        case .chrome: return ["148.0.7778.215", "148.0.7778.217", "148.0.7778.168"].randomElement()!
        case .edge: return ["148.0.3967.54", "148.0.3967.96", "148.0.3967.73"].randomElement()!
        case .opera: return ["120.0", "121.0"].randomElement()!
        case .vivaldi: return ["7.5", "7.6"].randomElement()!
        case nil: return ""
        }
    }

    static func newSeed(excluding seeds: Set<Int>) -> Int {
        var value: Int
        repeat { value = Int.random(in: 1...Int(Int32.max)) } while seeds.contains(value)
        return value
    }
}
