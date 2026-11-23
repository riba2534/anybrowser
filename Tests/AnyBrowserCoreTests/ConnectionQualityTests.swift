@testable import AnyBrowserCore
import Foundation
import Testing

/// `navigator.connection` is derived from the proxy, and the `connection-proxy` rule reports a
/// profile where that derivation and the configured proxy disagree.
struct ConnectionQualityTests {
    private func profile(_ proxy: String) -> BrowserProfile {
        BrowserProfile(name: "Connection", port: 9301, fingerprint: FingerprintSettings(seed: 1),
                       proxy: proxy)
    }

    private func quality(_ proxy: String) -> IdentityShim.ConnectionQuality? {
        IdentityShim.ConnectionQuality.from(profile(proxy))
    }

    private func connectionIssues(_ proxy: String) -> [ConsistencyIssue] {
        profile(proxy).consistencyIssues(engineVersion: nil, exit: nil)
            .filter { $0.id == "connection-proxy" }
    }

    @Test("Without a proxy the host network stays")
    func noProxy() {
        #expect(quality("") == nil)
        #expect(quality("   ") == nil)
        #expect(connectionIssues("").isEmpty)
        #expect(connectionIssues("   ").isEmpty)
    }

    @Test("A direct HTTP or HTTPS hop to an address reports 4g")
    func directProxy() {
        #expect(quality("127.0.0.1:7890") == .fourG)
        #expect(quality("http://127.0.0.1:7890") == .fourG)
        #expect(quality("https://10.0.0.2:8443") == .fourG)
        #expect(quality("http://[::1]:8080") == .fourG)
        #expect(quality("http://[fe80::1]:8080") == .fourG)
        #expect(connectionIssues("http://127.0.0.1:7890").isEmpty)
    }

    @Test("SOCKS5, credentials or a host name report the conservative 3g")
    func indirectProxy() {
        for proxy in [
            "socks5://127.0.0.1:1080", "socks5h://10.0.0.2:1080", "socks5://user:pw@127.0.0.1:1080",
            "http://user:pw@127.0.0.1:8080", "https://user:pw@10.0.0.2:8443",
            "http://proxy.example.com:8080", "proxy.example.com:8080", "socks5://proxy.example.com:1080",
        ] {
            #expect(quality(proxy) == .threeG, "\(proxy)")
            #expect(connectionIssues(proxy).isEmpty, "\(proxy)")
        }
    }

    @Test("An address that does not parse leaves the host network alone and is reported")
    func unparsableProxy() throws {
        for proxy in ["proxy", "http://", "socks4://127.0.0.1:1080", "http://example.com:70000"] {
            #expect(quality(proxy) == nil, "\(proxy)")
            let issue = try #require(connectionIssues(proxy).first, "\(proxy)")
            #expect(issue.severity == .medium)
            #expect(issue.message.contains("无法识别"))
        }
    }

    @Test("The rule reports a fabricated class without a proxy")
    func fabricatedWithoutProxy() throws {
        #expect(BrowserProfile.connectionProxyIssue(proxy: "", reported: nil) == nil)
        #expect(BrowserProfile.connectionProxyIssue(proxy: "127.0.0.1:7890", reported: .fourG) == nil)
        let missing = try #require(BrowserProfile.connectionProxyIssue(proxy: "127.0.0.1:7890", reported: nil))
        #expect(missing.message.contains("本机的网络类型"))
        let fabricated = try #require(BrowserProfile.connectionProxyIssue(proxy: "", reported: .threeG))
        #expect(fabricated.message.contains("伪造的网络类型"))
    }
}