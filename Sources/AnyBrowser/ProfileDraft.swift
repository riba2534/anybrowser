import AnyBrowserCore
import Foundation

struct ProfileDraft: Equatable {
    var profile: BrowserProfile
    var portText: String
    var seedText: String
    var cpuText: String

    init(_ profile: BrowserProfile) {
        self.profile = profile
        portText = String(profile.port)
        seedText = String(profile.fingerprint.seed)
        cpuText = profile.fingerprint.cpuCount.map(String.init) ?? ""
    }

    func validated() throws -> BrowserProfile {
        var value = profile
        value.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fingerprint.platformVersion = value.fingerprint.platformVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fingerprint.brandVersion = value.fingerprint.brandVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fingerprint.language = value.fingerprint.language.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fingerprint.timeZone = value.fingerprint.timeZone.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.name.isEmpty else { throw DraftError("请输入 Profile 名称。") }
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(port) else {
            throw DraftError("调试端口必须为 1024–65535 之间的整数。")
        }
        guard let seed = Int(seedText.trimmingCharacters(in: .whitespaces)), (1...Int(Int32.max)).contains(seed) else {
            throw DraftError("指纹种子必须为 1–2147483647 之间的整数。")
        }
        value.port = port
        value.fingerprint.seed = seed
        let cpu = cpuText.trimmingCharacters(in: .whitespaces)
        if cpu.isEmpty {
            value.fingerprint.cpuCount = nil
        } else {
            guard let count = Int(cpu), (1...256).contains(count) else {
                throw DraftError("逻辑 CPU 数必须为 1–256 之间的整数。")
            }
            value.fingerprint.cpuCount = count
        }
        return value
    }
}

private struct DraftError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
