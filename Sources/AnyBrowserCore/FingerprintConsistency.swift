import Foundation

public struct ConsistencyIssue: Identifiable, Equatable, Sendable {
    public let id: String
    public let message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}

extension BrowserProfile {
    /// Combinations a website could notice: versions ahead of the engine, platform and version
    /// mismatches, or a time zone and language that disagree with the proxy's exit.
    public func consistencyIssues(engineVersion: String?, exit: ProxyExit?) -> [ConsistencyIssue] {
        var issues: [ConsistencyIssue] = []
        // The editor checks its unsaved draft, so values may still carry stray spaces.
        let brandVersion = fingerprint.brandVersion.trimmingCharacters(in: .whitespaces)
        let platformVersion = fingerprint.platformVersion.trimmingCharacters(in: .whitespaces)
        let language = fingerprint.language.trimmingCharacters(in: .whitespaces)
        let timeZone = fingerprint.timeZone.trimmingCharacters(in: .whitespaces)

        // Chrome and Edge ship on the same Chromium they claim, so their major version should
        // track the engine's; Opera and Vivaldi number their releases separately.
        if let brand = fingerprint.brand, brand == .chrome || brand == .edge,
           let claimed = Self.majorVersion(brandVersion), let engine = engineVersion.flatMap(Self.majorVersion) {
            if claimed > engine {
                issues.append(ConsistencyIssue(id: "brand-version-ahead",
                                               message: "\(brand.rawValue) 版本 \(brandVersion) 高于内核版本 \(engine)"))
            } else if engine - claimed >= 4 {
                issues.append(ConsistencyIssue(id: "brand-version-behind",
                                               message: "\(brand.rawValue) 版本 \(brandVersion) 比内核版本 \(engine) 低 \(engine - claimed) 个主版本"))
            }
        }

        if let platform = fingerprint.platform, let major = Self.majorVersion(platformVersion) {
            let expected: ClosedRange<Int>
            switch platform {
            case .macOS: expected = 10...26
            case .windows: expected = 0...20
            case .linux: expected = 2...7
            }
            if !expected.contains(major) {
                issues.append(ConsistencyIssue(
                    id: "platform-version",
                    message: "平台版本 \(platformVersion) 与 \(platform.title) 不匹配（\(platform.title) 主版本应为 \(expected.lowerBound)–\(expected.upperBound)）"))
            }
        }

        // The macOS engine never rewrites WebGL for Linux: pages read this Mac's own GPU.
        if fingerprint.platform == .linux {
            issues.append(ConsistencyIssue(id: "linux-webgl",
                                           message: "Linux 平台下内核不改写 WebGL，网页会读到本机真实显卡，与 Linux 身份不符"))
        }
        // Spoofed WebGL follows the platform, and without a platform it claims a Windows GPU while
        // everything else still reports this Mac. Unspoofed WebGL shows this Mac's GPU.
        let spoofsWebGL = fingerprint.adjustments.contains(.gpu)
        if fingerprint.platform == .windows, !spoofsWebGL {
            issues.append(ConsistencyIssue(id: "webgl-real-gpu",
                                           message: "WebGL 改写已关闭，网页会读到本机真实显卡，与 Windows 身份不符"))
        } else if fingerprint.platform == nil, spoofsWebGL {
            issues.append(ConsistencyIssue(id: "webgl-windows-gpu",
                                           message: "未选平台时 WebGL 按 Windows 显卡改写，与本机 macOS 身份不符"))
        }

        guard let exit else { return issues }
        let location = [exit.city, exit.countryCode].filter { !$0.isEmpty }.joined(separator: ", ")
        let place = location.isEmpty ? "出口 IP " : "出口 IP 所在地（\(location)）"

        // An empty time zone or language follows this Mac, which the website sees just the same.
        let zone: (label: String, value: String) = timeZone.isEmpty
            ? ("本机时区", TimeZone.current.identifier) : ("时区", timeZone)
        if !exit.timeZone.isEmpty, zone.value != exit.timeZone {
            issues.append(ConsistencyIssue(id: "time-zone",
                                           message: "\(zone.label) \(zone.value) 与\(place)的 \(exit.timeZone) 不一致"))
        }

        let spoken: (label: String, value: String) = language.isEmpty
            ? ("本机语言", Locale.preferredLanguages.first ?? "") : ("语言", language)
        let exitLanguages = Set(exit.languages.compactMap(Self.primaryLanguage))
        if !exitLanguages.isEmpty, let primary = Self.primaryLanguage(spoken.value), !exitLanguages.contains(primary) {
            let listed = exit.languages.prefix(3).joined(separator: "、")
            issues.append(ConsistencyIssue(id: "language",
                                           message: "\(spoken.label) \(spoken.value) 与\(place)的常用语言 \(listed) 不一致"))
        }
        return issues
    }

    private static func majorVersion(_ version: String) -> Int? {
        version.split(separator: ".", omittingEmptySubsequences: false).first.flatMap { Int($0) }
    }

    /// The primary subtag of a BCP 47 tag ("zh" for "zh-Hans-CN"), lowercased.
    private static func primaryLanguage(_ tag: String) -> String? {
        tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() }
    }
}
