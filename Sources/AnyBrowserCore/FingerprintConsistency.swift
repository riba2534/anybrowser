import Foundation

public struct ConsistencyIssue: Identifiable, Equatable, Sendable {
    public let id: String
    public let message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }

    /// The warning for Profiles that leave through the same exit IP as `names`, without a full stop.
    public static func sharedExit(_ names: [String]) -> String {
        let listed = names.prefix(3).map { "「\($0)」" }.joined(separator: "、")
        let more = names.count > 3 ? "等 \(names.count) 个 Profile " : ""
        return "与\(listed)\(more)使用同一个出口 IP，网站可以据此把它们关联起来"
    }
}

/// Facts about other Profiles and the engine that a single Profile cannot know by itself.
public struct ConsistencyContext: Equatable, Sendable {
    /// Names of other Profiles whose last seen exit IP equals this Profile's.
    public var profilesSharingExit: [String]
    /// How many major versions the engine is behind Chrome stable, when known.
    public var engineMajorsBehindStable: Int?

    public init(profilesSharingExit: [String] = [], engineMajorsBehindStable: Int? = nil) {
        self.profilesSharingExit = profilesSharingExit
        self.engineMajorsBehindStable = engineMajorsBehindStable
    }
}

extension FingerprintSettings {
    /// The real CPU count closest to this one for the machine the seed selects, when the seed's
    /// GPU and memory exist together and only the CPU count is off; fewer cores win a tie.
    public func suggestedCPUCount(engineVersion: String?) -> Int? {
        guard let platform, adjustments.contains(.gpu), platform != .linux,
              let table = engineVersion.flatMap(EngineHardwareTable.forEngine),
              let gpu = table.gpu(for: platform, seed: seed),
              gpu.deviceMemory.contains(table.deviceMemory(seed: seed)) else { return nil }
        let current = cpuCount ?? table.defaultCPUCount(seed: seed)
        guard !gpu.cpuCounts.contains(current) else { return nil }
        return gpu.cpuCounts.min { (abs($0 - current), $0) < (abs($1 - current), $1) }
    }
}

extension BrowserProfile {
    /// Combinations a website could notice: versions ahead of the engine, platform and version
    /// mismatches, or a time zone and language that disagree with the proxy's exit.
    public func consistencyIssues(engineVersion: String?, exit: ProxyExit?,
                                  context: ConsistencyContext = ConsistencyContext()) -> [ConsistencyIssue] {
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
        let engineMajor = engineVersion.flatMap(Self.majorVersion) ?? BundledVersions.engineMajor
        if fingerprint.brand == .edge, !brandVersion.isEmpty {
            issues.append(ConsistencyIssue(
                id: "edge-ua-version",
                message: "填写 Edge 品牌版本后内核会在 UA 中发送完整版本 Edg/\(brandVersion)，真实 Edge 只发送 Edg/\(Self.majorVersion(brandVersion) ?? engineMajor).0.0.0；留空则由内核按种子选用已发布的版本"))
        }
        // The engine only appends a UA suffix for these two brands and gives UA-CH no brand for them.
        if fingerprint.brand == .opera {
            issues.append(ConsistencyIssue(
                id: "brand-experimental",
                message: "Opera 身份为实验性：内核只在 UA 末尾加上 OPR/版本，UA-CH 中没有 Opera 品牌；基于 Chromium \(engineMajor) 的 Opera 版本为 \(engineMajor - 16)"))
        } else if fingerprint.brand == .vivaldi {
            issues.append(ConsistencyIssue(
                id: "brand-experimental",
                message: "Vivaldi 身份为实验性：真实 Vivaldi 的 UA 与 Chrome 相同，内核却会加上 Vivaldi/版本，UA-CH 中也没有 Google Chrome 品牌"))
        }
        if let behind = context.engineMajorsBehindStable, behind >= 2 {
            issues.append(ConsistencyIssue(
                id: "engine-behind",
                message: "内核 \(engineMajor) 落后 Chrome 稳定版 \(behind) 个主版本，所有 Profile 报出的都是这个较旧的版本"))
        }

        if let platform = fingerprint.platform, let major = Self.majorVersion(platformVersion) {
            let expected: ClosedRange<Int>
            switch platform {
            // Allow the next macOS too: real Macs run releases newer than this table.
            case .macOS: expected = 10...max(27, ProcessInfo.processInfo.operatingSystemVersion.majorVersion + 1)
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
        // The seed picks the spoofed GPU and the memory; the CPU count has to fit the same machine.
        if spoofsWebGL, let platform = fingerprint.platform,
           let table = engineVersion.flatMap(EngineHardwareTable.forEngine),
           let gpu = table.gpu(for: platform, seed: fingerprint.seed) {
            let seed = fingerprint.seed
            let cpus = fingerprint.cpuCount ?? table.defaultCPUCount(seed: seed)
            let memory = table.deviceMemory(seed: seed)
            var problems: [String] = []
            if !gpu.cpuCounts.contains(cpus) {
                let source = fingerprint.cpuCount == nil ? "（未指定时由种子决定）" : ""
                problems.append("\(gpu.model) 的机型有 \(Self.list(gpu.cpuCounts)) 个逻辑 CPU，不是 \(cpus) 个\(source)")
            }
            if !gpu.deviceMemory.contains(memory) {
                problems.append("\(gpu.model) 的机型内存为 \(Self.list(gpu.deviceMemory)) GB，种子却报出 \(memory) GB")
            }
            if !problems.isEmpty {
                issues.append(ConsistencyIssue(
                    id: "hardware-impossible",
                    message: "种子 \(seed) 让 WebGL 报出 \(gpu.model)，这套硬件不存在：\(problems.joined(separator: "；"))。请换种子或修改逻辑 CPU 数"))
            }
        }
        // Neither has an engine switch yet: every Profile shows this Mac's WebGPU adapter and voices.
        if let platform = fingerprint.platform, platform != .macOS {
            issues.append(ConsistencyIssue(id: "webgpu-host-gpu",
                                           message: "WebGPU 仍报告本机的 Apple 显卡，与 \(platform.title) 身份不符，需要内核补丁"))
            issues.append(ConsistencyIssue(id: "voices-host-os",
                                           message: "语音列表仍是本机 macOS 的语音，没有 \(platform.title) 自带的语音，需要内核补丁"))
        }

        if let width = fingerprint.screenWidth, let height = fingerprint.screenHeight {
            let availWidth = fingerprint.availWidth ?? width
            let availHeight = fingerprint.availHeight ?? height
            if availWidth > width || availHeight > height {
                issues.append(ConsistencyIssue(id: "screen-avail",
                                               message: "可用屏幕 \(availWidth)×\(availHeight) 大于屏幕 \(width)×\(height)。"))
            }
        }
        if let colorDepth = fingerprint.colorDepth, let platform = fingerprint.platform {
            let allowed: Set<Int> = platform == .macOS ? [24, 30] : [24]
            if !allowed.contains(colorDepth) {
                issues.append(ConsistencyIssue(id: "screen-color-depth",
                                               message: "\(platform.title) 身份常见色深为 \(allowed.sorted().map(String.init).joined(separator: "/"))，当前为 \(colorDepth)。"))
            }
        }
        if let fontProfile = fingerprint.fontProfile, let platform = fingerprint.platform,
           fontProfile.platform != platform {
            issues.append(ConsistencyIssue(id: "font-profile-platform",
                                           message: "字体表「\(fontProfile.title)」与 \(platform.title) 平台不匹配。"))
        }
        // A table the engine never applies is worse than none: the page reads this Mac's fonts
        // whatever the Profile claims.
        if let fontProfile = fingerprint.fontProfile, !fingerprint.adjustments.contains(.font) {
            issues.append(ConsistencyIssue(
                id: "font-spoof-disabled",
                message: "已选择字体表「\(fontProfile.title)」，但「字体」改写是关的，网页仍会读到本机 macOS 字体。"))
        }
        // The engine ignores its screen switches, so every Profile reports the host display.
        if fingerprint.platform != nil, fingerprint.screenWidth == nil {
            issues.append(ConsistencyIssue(
                id: "screen-host-shared",
                message: "没有屏幕配置：所有 Profile 都会报同一块本机屏幕，网站可以据此把它们关联起来。"))
        }
        // The engine has no font tables: its font switch only adds and drops this Mac's fonts by seed.
        if let fontProfile = fingerprint.fontProfile, fontProfile.platform != .macOS {
            let platform = fontProfile.platform.title
            issues.append(ConsistencyIssue(
                id: "font-spoof-missing",
                message: fingerprint.adjustments.contains(.font)
                    ? "当前内核没有 \(fontProfile.title)表，「字体」改写只是按种子增删本机 macOS 字体，网页读到的组合在真实 \(platform) 上不存在。"
                    : "当前内核没有 \(fontProfile.title)表，网页会读到本机 macOS 字体；打开「字体」改写也只会按种子增删这些字体，同样不像 \(platform)。"))
        }
        if !context.profilesSharingExit.isEmpty {
            issues.append(ConsistencyIssue(id: "exit-shared", message: ConsistencyIssue.sharedExit(context.profilesSharingExit)))
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

    private static func list(_ values: [Int]) -> String {
        values.map(String.init).joined(separator: "、")
    }

    private static func majorVersion(_ version: String) -> Int? {
        version.split(separator: ".", omittingEmptySubsequences: false).first.flatMap { Int($0) }
    }

    /// The primary subtag of a BCP 47 tag ("zh" for "zh-Hans-CN"), lowercased.
    private static func primaryLanguage(_ tag: String) -> String? {
        tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() }
    }
}
