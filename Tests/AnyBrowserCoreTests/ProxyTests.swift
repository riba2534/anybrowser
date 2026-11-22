@testable import AnyBrowserCore
import Darwin
import Foundation
import JavaScriptCore
import Network
import Testing

@Suite("Proxy credentials and exit lookup", .serialized)
struct ProxyTests {
    @Test("HTTP and HTTPS proxies take percent-encoded credentials that never reach --proxy-server")
    func parsesCredentials() throws {
        let plain = try #require(try ProxyEndpoint.parse(" http://alice:secret@127.0.0.1:8080 "))
        #expect(plain == ProxyEndpoint(scheme: "http", host: "127.0.0.1", port: 8080, username: "alice", password: "secret"))
        #expect(plain.hasCredentials)
        #expect(plain.server == "http://127.0.0.1:8080")

        let encoded = try #require(try ProxyEndpoint.parse("HTTPS://us%40er:p%3Ass%2Fw%25rd%20x@Proxy.Example:443/"))
        #expect(encoded == ProxyEndpoint(scheme: "https", host: "proxy.example", port: 443,
                                         username: "us@er", password: "p:ss/w%rd x"))
        #expect(encoded.server == "https://proxy.example:443")

        // Without a scheme the proxy is HTTP; the password may hold a raw colon and sub-delimiters.
        let bare = try #require(try ProxyEndpoint.parse("bob:a:b!$&'()*+,;=~@[::1]:3128"))
        #expect(bare == ProxyEndpoint(scheme: "http", host: "[::1]", port: 3128, username: "bob", password: "a:b!$&'()*+,;=~"))
        #expect(bare.server == "http://[::1]:3128")

        let none = try #require(try ProxyEndpoint.parse("socks5://127.0.0.1:1080"))
        #expect(!none.hasCredentials && none.username == nil && none.password == nil)

        var profile = BrowserProfile(name: "Proxy", port: 9222, fingerprint: FingerprintSettings(seed: 1),
                                     proxy: "http://alice:p%40ss@proxy.example:3128")
        let arguments = try profile.validated().launchArguments(userDataDirectory: URL(fileURLWithPath: "/tmp/proxy/p"))
        #expect(arguments.contains("--proxy-server=http://proxy.example:3128"))
        #expect(!arguments.contains { $0.contains("alice") || $0.contains("p@ss") || $0.contains("p%40ss") })
        profile.proxy = "socks5://alice:secret@127.0.0.1:1080"
        #expect(throws: ProfileError.self) { try profile.validated() }
    }

    @Test("Provider formats, socks5h and empty passwords parse to one normalized address")
    func parsesProviderFormats() throws {
        // host:port:user:password, as residential providers hand them out.
        let listed = try #require(try ProxyEndpoint.parse(" gate.example.com:7777:user-zone-us:p@ss "))
        #expect(listed == ProxyEndpoint(scheme: "http", host: "gate.example.com", port: 7777,
                                        username: "user-zone-us", password: "p@ss"))
        #expect(listed.url == "http://user-zone-us:p%40ss@gate.example.com:7777")
        #expect(try ProxyEndpoint.parse(listed.url) == listed)
        #expect(try ProxyEndpoint.parse("http://user-zone-us:p%40ss@Gate.Example.com:7777/") == listed)
        #expect(try ProxyEndpoint.parse("user-zone-us:p%40ss@gate.example.com:7777") == listed)
        let socksListed = try ProxyEndpoint.parse("socks5://10.0.0.2:1080:alice:secret", allowingSOCKSCredentials: true)
        #expect(socksListed == ProxyEndpoint(scheme: "socks5", host: "10.0.0.2", port: 1080, username: "alice", password: "secret"))

        // socks5h means remote DNS, which is what Chromium's socks5 already does.
        let remote = try #require(try ProxyEndpoint.parse("SOCKS5H://127.0.0.1:1080"))
        #expect(remote == ProxyEndpoint(scheme: "socks5", host: "127.0.0.1", port: 1080))
        #expect(remote.url == "socks5://127.0.0.1:1080" && remote.server == remote.url)

        // A key alone signs in to some providers; the password stays empty, not missing.
        let key = try #require(try ProxyEndpoint.parse("http://APIKEY:@proxy.example:8011"))
        #expect(key.username == "APIKEY" && key.password == "" && key.hasCredentials)
        #expect(key.url == "http://APIKEY:@proxy.example:8011")
        #expect(try ProxyEndpoint.parse("proxy.example:8011:APIKEY:") == key)
        let tricky = ProxyEndpoint(scheme: "https", host: "[::1]", port: 443, username: "a b/c", password: "é:%@")
        #expect(try ProxyEndpoint.parse(tricky.url) == tricky)

        // SOCKS5 credentials are refused for the engine, accepted where a relay signs in.
        let socks = "socks5://alice:secret@127.0.0.1:1080"
        #expect(throws: ProfileError.self) { try ProxyEndpoint.parse(socks) }
        #expect(try ProxyEndpoint.parse(socks, allowingSOCKSCredentials: true)?.password == "secret")
        #expect(throws: ProfileError.self) {
            try ProxyEndpoint.parse("socks5://\(String(repeating: "u", count: 256)):p@127.0.0.1:1080", allowingSOCKSCredentials: true)
        }

        for (address, message) in [("socks4://127.0.0.1:1080", "SOCKS4"), ("socks4a://127.0.0.1:1080", "SOCKS4"),
                                   ("gate.example.com:7777:user:pa:ss", "%3A"),
                                   ("gate.example.com:7777:user", "主机:端口:用户名:密码")] {
            do {
                _ = try ProxyEndpoint.parse(address)
                Issue.record("\(address) was accepted")
            } catch {
                #expect(error.localizedDescription.contains(message), "\(address): \(error.localizedDescription)")
            }
        }
    }

    @Test("SOCKS5 credentials and malformed credentials are refused")
    func refusesBadCredentials() throws {
        do {
            _ = try ProxyEndpoint.parse("SOCKS5://alice:secret@127.0.0.1:1080")
            Issue.record("SOCKS5 credentials were accepted")
        } catch {
            #expect(error.localizedDescription.contains("SOCKS5"))
            #expect(error.localizedDescription.contains("HTTP 代理"))
        }
        let malformed = [
            "http://alice@127.0.0.1:8080", "http://:secret@127.0.0.1:8080", "127.0.0.1:8080::secret",
            "http://@127.0.0.1:8080", "http://al ice:secret@127.0.0.1:8080", "http://alice:sec/ret@127.0.0.1:8080",
            "http://alice:sec#ret@127.0.0.1:8080", "http://alice:sec%zzret@127.0.0.1:8080",
            "http://alice:sec%0Aret@127.0.0.1:8080", "http://al%3Aice:secret@127.0.0.1:8080",
            "http://alice:secret@127.0.0.1:8080/path", "http://alice:secret@-proxy:8080",
            "http://alice:secret@127.0.0.1:0", "http://alice:secret@127.0.0.1:8080 --flag",
            "ftp://alice:secret@127.0.0.1:8080", "http://alice:" + String(repeating: "x", count: 500) + "@h:1",
        ]
        for address in malformed {
            #expect(throws: ProfileError.self, "\(address)") { try ProxyEndpoint.parse(address) }
        }
    }

    @Test("The sign-in extension is written privately, kept when unchanged and removed without credentials")
    func writesTheSignInExtension() throws {
        let storage = try scratchDirectory("proxy")
        defer { try? FileManager.default.removeItem(at: storage) }
        var profile = BrowserProfile(name: "Proxy", port: 9222, fingerprint: FingerprintSettings(seed: 1),
                                     proxy: #"http://alice:p%22w%5C@[::1]:3128"#)
        let target = ProxyAuthExtension.directory(in: storage, for: profile.id)
        #expect(target.path == storage.path + "/Extensions/\(profile.id.uuidString.lowercased())/ProxyAuth")
        #expect(ProfileExtensions.paths(for: profile, in: storage).contains(target))

        try ProxyAuthExtension.prepare(for: profile, in: storage)
        #expect(try permissions(target) == 0o700)
        #expect(try permissions(target.deletingLastPathComponent()) == 0o700)
        let names = ["background.js", "credentials.json", "manifest.json"]
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() == names)
        for name in names {
            #expect(try permissions(target.appendingPathComponent(name)) == 0o600, "\(name)")
        }
        let manifest = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: target.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["manifest_version"] as? Int == 3)
        #expect(manifest["name"] as? String == "AnyBrowser Proxy Sign-in")
        #expect(manifest["permissions"] as? [String] == ["webRequest", "webRequestAuthProvider"])
        #expect(manifest["host_permissions"] as? [String] == ["<all_urls>"])
        #expect((manifest["background"] as? [String: String])?["service_worker"] == "background.js")
        let credentials = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: target.appendingPathComponent("credentials.json"))) as? [String: Any])
        #expect(credentials["host"] as? String == "[::1]")
        #expect(credentials["port"] as? Int == 3128)
        #expect(credentials["username"] as? String == "alice")
        #expect(credentials["password"] as? String == #"p"w\"#)
        let script = try String(contentsOf: target.appendingPathComponent("background.js"), encoding: .utf8)
        #expect(!script.contains("alice"))

        // Unchanged files stay in place; a changed password or loosened permissions are rewritten.
        let inodes = try names.map { try inode(target.appendingPathComponent($0)) }
        try Data("old".utf8).write(to: target.appendingPathComponent(".credentials.json-stale"))
        try ProxyAuthExtension.prepare(for: profile, in: storage)
        #expect(try names.map { try inode(target.appendingPathComponent($0)) } == inodes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() == names)
        profile.proxy = "http://alice:changed@[::1]:3128"
        chmod(target.appendingPathComponent("manifest.json").path, 0o644)
        try ProxyAuthExtension.prepare(for: profile, in: storage)
        let rewritten = try names.map { try inode(target.appendingPathComponent($0)) }
        #expect(rewritten[0] == inodes[0])
        #expect(rewritten[1] != inodes[1] && rewritten[2] != inodes[2])
        #expect(try permissions(target.appendingPathComponent("manifest.json")) == 0o600)
        #expect(try String(contentsOf: target.appendingPathComponent("credentials.json"), encoding: .utf8)
            .contains(#""password":"changed""#))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() == names)

        // A link in place of the directory is replaced, leaving its destination alone.
        let elsewhere = storage.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.moveItem(at: target, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: elsewhere)
        try ProxyAuthExtension.prepare(for: profile, in: storage)
        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType == .typeDirectory)
        #expect(try String(contentsOf: elsewhere.appendingPathComponent("credentials.json"), encoding: .utf8)
            .contains("changed"))

        profile.proxy = "http://[::1]:3128"
        try ProxyAuthExtension.prepare(for: profile, in: storage)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(!ProfileExtensions.paths(for: profile, in: storage).contains(target))
        profile.proxy = ""
        try ProxyAuthExtension.prepare(for: profile, in: storage)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("The extension answers only its proxy's challenge, once per request")
    func extensionAnswersOnce() throws {
        let page = try SignInScript(config: #"{"host":"[::1]","port":3128,"username":"alice","password":"p\"w"}"#)
        #expect(page.registration == #"{"urls":["<all_urls>"],"extra":["asyncBlocking"]}"#)
        let credentials = #"{"authCredentials":{"username":"alice","password":"p\"w"}}"#
        #expect(page.challenge(request: "1", isProxy: true, host: "::1", port: 3128) == credentials)
        #expect(page.challenge(request: "1", isProxy: true, host: "::1", port: 3128) == #"{"cancel":true}"#)
        #expect(page.challenge(request: "2", isProxy: true, host: "[::1]", port: 3128) == credentials)
        #expect(page.challenge(request: "3", isProxy: false, host: "::1", port: 3128) == "{}")
        #expect(page.challenge(request: "4", isProxy: true, host: "::2", port: 3128) == "{}")
        #expect(page.challenge(request: "5", isProxy: true, host: "::1", port: 3129) == "{}")

        let named = try SignInScript(config: #"{"host":"proxy.example","port":80,"username":"a","password":"b"}"#)
        #expect(named.challenge(request: "1", isProxy: true, host: "PROXY.example", port: 80)
            == #"{"authCredentials":{"username":"a","password":"b"}}"#)
        let unreadable = try SignInScript(config: nil)
        #expect(unreadable.challenge(request: "1", isProxy: true, host: "proxy.example", port: 80) == "{}")
    }

    @Test("ipinfo.io and ipapi.co answers become a ProxyExit")
    func readsExitAnswers() throws {
        let ipinfo = try ProxyProbe.exit(from: Data("""
            {"ip":"203.0.113.7","city":"Tokyo","region":"Tokyo","country":"JP","loc":"35.6,139.7",
             "org":"AS64500 Example","timezone":"Asia/Tokyo"}
            """.utf8))
        #expect(ipinfo == ProxyExit(ip: "203.0.113.7", countryCode: "JP", region: "Tokyo", city: "Tokyo",
                                    timeZone: "Asia/Tokyo", languages: ["ja-JP"]))
        let ipapi = try ProxyProbe.exit(from: Data("""
            {"ip":"2001:db8::1","city":"Berlin","region":"Land Berlin","country":"DE","country_code":"DE",
             "country_name":"Germany","timezone":"Europe/Berlin","languages":"de, en-US,,not a tag"}
            """.utf8))
        #expect(ipapi == ProxyExit(ip: "2001:db8::1", countryCode: "DE", region: "Land Berlin", city: "Berlin",
                                   timeZone: "Europe/Berlin", languages: ["de", "en-US"]))
        let bogon = try ProxyProbe.exit(from: Data(#"{"ip":"10.0.0.1","bogon":true}"#.utf8))
        #expect(bogon == ProxyExit(ip: "10.0.0.1"))
        let odd = try ProxyProbe.exit(from: Data(#"{"ip":"198.51.100.1","country":"xyz","timezone":"Mars/Base"}"#.utf8))
        #expect(odd == ProxyExit(ip: "198.51.100.1"))

        for body in [#"{"error":true,"reason":"RateLimited"}"#, #"{"ip":"1.2.3.4","error":{"title":"Wrong ip"}}"#,
                     #"{"city":"Tokyo"}"#, #"{"ip":"not an ip"}"#, "[]", "<html>", ""] {
            #expect(throws: (any Error).self, "\(body)") { try ProxyProbe.exit(from: Data(body.utf8)) }
        }
    }

    @Test("Every listed country fills a language the fingerprint accepts")
    func fillsLanguagesByCountry() throws {
        for country in ["CN", "TW", "HK", "SG", "JP", "KR", "US", "GB", "CA", "AU", "DE", "FR", "ES", "IT", "NL", "RU", "BR", "IN"] {
            let exit = try ProxyProbe.exit(from: Data(#"{"ip":"192.0.2.1","country":"\#(country)","timezone":"UTC"}"#.utf8))
            #expect(!exit.languages.isEmpty, "\(country)")
            var profile = BrowserProfile(name: "Exit", port: 9222, fingerprint: FingerprintSettings(seed: 1))
            exit.apply(to: &profile.fingerprint)
            #expect(profile.fingerprint.language == exit.languages.first)
            #expect(profile.fingerprint.timeZone == "UTC")
            _ = try profile.validated()
        }
        #expect(ProxyProbe.commonLanguages["CN"]?.first == "zh-CN")
        #expect(ProxyProbe.commonLanguages["US"]?.first == "en-US")

        var fingerprint = FingerprintSettings(seed: 1)
        fingerprint.language = "fr-FR"
        fingerprint.timeZone = "Europe/Paris"
        ProxyExit(ip: "192.0.2.1").apply(to: &fingerprint)
        #expect(fingerprint.language == "fr-FR" && fingerprint.timeZone == "Europe/Paris")
    }

    @Test("Lookups sign in to the HTTP proxy, fall back to the second service and never follow redirects")
    func looksUpThroughTheProxy() async throws {
        let ipapi = #"{"ip":"198.51.100.20","country_code":"SG","timezone":"Asia/Singapore","languages":"en-SG,zh-SG"}"#
        let stub = try await ProxyStub.start(credentials: "alice:s3cr@t") { request in
            switch request.target {
            case "http://ipinfo.test/json": return .init(status: 500, body: "{}")
            case "http://ipapi.test/json/": return .init(status: 200, body: ipapi)
            case "http://redirect.test/": return .init(status: 302, headers: ["Location": "http://ipapi.test/json/"])
            default: return nil
            }
        }
        defer { stub.stop() }
        let endpoint = try #require(try ProxyEndpoint.parse("http://alice:s3cr%40t@127.0.0.1:\(stub.port)"))
        let services = [URL(string: "http://ipinfo.test/json")!, URL(string: "http://ipapi.test/json/")!]

        let exit = try await ProxyProbe.lookupExit(through: endpoint, services: services, timeout: 5)
        #expect(exit == ProxyExit(ip: "198.51.100.20", countryCode: "SG", timeZone: "Asia/Singapore",
                                  languages: ["en-SG", "zh-SG"]))
        let signedIn = "Basic " + Data("alice:s3cr@t".utf8).base64EncodedString()
        #expect(stub.requests.filter { $0.method == "GET" && $0.authorization == signedIn }.map(\.target)
            == services.map(\.absoluteString))
        #expect(stub.requests.contains { $0.method == "CONNECT" && $0.authorization == nil })
        // The services see a generic client, not the app, the Mac's languages or its macOS build.
        for request in stub.requests where request.method == "GET" {
            #expect(request.headers["user-agent"] == "curl/8.7.1")
            #expect(request.headers["accept-language"] == "en-US,en;q=0.9")
            #expect(request.headers["accept"] == "application/json")
        }

        await expectFailure("代理拒绝了用户名或密码") {
            try await ProxyProbe.lookupExit(through: try ProxyEndpoint.parse("http://alice:wrong@127.0.0.1:\(stub.port)"),
                                            services: services, timeout: 5)
        }
        await expectFailure("代理要求登录") {
            try await ProxyProbe.lookupExit(through: try ProxyEndpoint.parse("127.0.0.1:\(stub.port)"),
                                            services: services, timeout: 5)
        }
        let before = stub.requests.count
        await expectFailure("redirect.test 返回 302 状态") {
            try await ProxyProbe.lookupExit(through: endpoint, services: [URL(string: "http://redirect.test/")!], timeout: 5)
        }
        #expect(!stub.requests.dropFirst(before).contains { $0.target == "http://ipapi.test/json/" })

        let started = Date()
        await expectFailure("hang.test 请求超时") {
            try await ProxyProbe.lookupExit(through: endpoint, services: [URL(string: "http://hang.test/")!], timeout: 1)
        }
        #expect(Date().timeIntervalSince(started) < 4)

        // A proxy without sign-in is reached through the session's proxy dictionary.
        stub.expect(nil)
        let open = try await ProxyProbe.lookupExit(through: try ProxyEndpoint.parse("127.0.0.1:\(stub.port)"),
                                                   services: services, timeout: 5)
        #expect(open.ip == "198.51.100.20")
        let last = try #require(stub.requests.last)
        #expect(last.method == "GET" && last.target == "http://ipapi.test/json/" && last.authorization == nil)
    }

    @Test("A direct lookup reads the first service; the proxy kind picks the session's proxy settings")
    func configuresSessions() async throws {
        let base = URLSessionConfiguration.ephemeral
        base.protocolClasses = [ExitService.self]
        ExitService.answers = ["https://ipinfo.io/json": (200, #"{"ip":"192.0.2.9","country":"FR","timezone":"Europe/Paris"}"#)]
        let exit = try await ProxyProbe.lookupExit(through: nil, configuration: base)
        #expect(exit == ProxyExit(ip: "192.0.2.9", countryCode: "FR", timeZone: "Europe/Paris", languages: ["fr-FR"]))
        ExitService.answers = ["https://ipinfo.io/json": (429, "{}"),
                               "https://ipapi.co/json/": (200, #"{"error":true,"reason":"RateLimited"}"#),
                               "https://ipwho.is/": (200, #"{"ip":"192.0.2.10","success":false,"message":"limit"}"#),
                               "https://get.geojs.io/v1/ip/geo.json": (503, "")]
        await expectFailure("ipinfo.io 返回 429 状态；ipapi.co 返回的数据无法识别；ipwho.is 返回的数据无法识别；get.geojs.io 返回 503 状态") {
            try await ProxyProbe.lookupExit(through: nil, configuration: base)
        }
        // Each service is tried in turn until one answers.
        ExitService.answers["https://get.geojs.io/v1/ip/geo.json"] = (200, #"{"ip":"192.0.2.11","country_code":"JP","country":"Japan","timezone":"Asia\/Tokyo"}"#)
        #expect(try await ProxyProbe.lookupExit(through: nil, configuration: base).ip == "192.0.2.11")
        #expect(ProxyProbe.lookupServices.map(\.absoluteString) == ["https://ipinfo.io/json", "https://ipapi.co/json/",
                                                                     "https://ipwho.is/", "https://get.geojs.io/v1/ip/geo.json"])

        let direct = try ProxyProbe.sessionConfiguration(.ephemeral, through: nil, timeout: 8)
        #expect(direct.connectionProxyDictionary == nil)
        #expect(direct.timeoutIntervalForRequest == 8 && direct.urlCredentialStorage == nil)
        let socks = try ProxyProbe.sessionConfiguration(.ephemeral, through: ProxyEndpoint.parse("socks5://[::1]:1080"), timeout: 8)
        #expect(socks.connectionProxyDictionary?["SOCKSEnable"] as? Int == 1)
        #expect(socks.connectionProxyDictionary?["SOCKSProxy"] as? String == "::1")
        #expect(socks.connectionProxyDictionary?["SOCKSPort"] as? Int == 1080)
        #expect(socks.connectionProxyDictionary?["HTTPEnable"] == nil)
        let http = try ProxyProbe.sessionConfiguration(.ephemeral, through: ProxyEndpoint.parse("proxy.example:3128"), timeout: 8)
        #expect(http.connectionProxyDictionary?["HTTPSProxy"] as? String == "proxy.example")
        #expect(http.connectionProxyDictionary?["HTTPSPort"] as? Int == 3128)
        if #available(macOS 14, *) {
            #expect(http.proxyConfigurations.isEmpty)
            for address in ["https://proxy.example:443", "https://alice:secret@proxy.example:443",
                            "http://alice:secret@proxy.example:3128", "socks5://alice:secret@proxy.example:1080"] {
                let endpoint = try ProxyEndpoint.parse(address, allowingSOCKSCredentials: true)
                let tunnel = try ProxyProbe.sessionConfiguration(.ephemeral, through: endpoint, timeout: 8)
                #expect(tunnel.proxyConfigurations.count == 1, "\(address)")
                #expect(tunnel.connectionProxyDictionary == nil, "\(address)")
            }
        }
    }

    @Test("ipwho.is and geojs.io answers become a ProxyExit")
    func readsTheFallbackServices() throws {
        let ipwho = try ProxyProbe.exit(from: Data("""
            {"ip":"203.0.113.8","success":true,"country":"Japan","country_code":"JP","region":"Tokyo","city":"Tokyo",
             "timezone":{"id":"Asia/Tokyo","abbr":"JST","utc":"+09:00"}}
            """.utf8))
        #expect(ipwho == ProxyExit(ip: "203.0.113.8", countryCode: "JP", region: "Tokyo", city: "Tokyo",
                                   timeZone: "Asia/Tokyo", languages: ["ja-JP"]))
        let geojs = try ProxyProbe.exit(from: Data("""
            {"ip":"198.51.100.3","country":"Germany","country_code":"DE","region":"Hesse","city":"Frankfurt am Main",
             "timezone":"Europe\\/Berlin","country_code3":"DEU"}
            """.utf8))
        #expect(geojs == ProxyExit(ip: "198.51.100.3", countryCode: "DE", region: "Hesse", city: "Frankfurt am Main",
                                   timeZone: "Europe/Berlin", languages: ["de-DE"]))
        for body in [#"{"ip":"203.0.113.8","success":false}"#, #"{"ip":"203.0.113.8","success":"yes"}"#,
                     #"{"ip":"203.0.113.8","timezone":{"id":"Mars/Base"}}"#] {
            let exit = try? ProxyProbe.exit(from: Data(body.utf8))
            #expect(exit == nil || exit?.timeZone == "", "\(body)")
        }
    }

    @Test("Exits are cached per proxy address and only reused within the age asked for")
    func cachesExits() async throws {
        ProxyProbe.forgetCachedExits()
        defer { ProxyProbe.forgetCachedExits() }
        let base = URLSessionConfiguration.ephemeral
        base.protocolClasses = [ExitService.self]
        ExitService.answers = ["https://ipinfo.io/json": (200, #"{"ip":"192.0.2.20","country":"US","timezone":"America/New_York"}"#)]
        ExitService.served = 0
        let first = try await ProxyProbe.lookupExit(through: nil, maxAge: 60, configuration: base)
        #expect(first.ip == "192.0.2.20" && ExitService.served == 1)
        ExitService.answers["https://ipinfo.io/json"] = (200, #"{"ip":"192.0.2.21"}"#)
        #expect(try await ProxyProbe.lookupExit(through: nil, maxAge: 60, configuration: base) == first)
        #expect(ExitService.served == 1)
        // Without an age every lookup asks again, and refreshes the cache.
        #expect(try await ProxyProbe.lookupExit(through: nil, configuration: base).ip == "192.0.2.21")
        #expect(ExitService.served == 2)
        #expect(ProxyProbe.cachedExit(for: nil, maxAge: 60)?.ip == "192.0.2.21")
        #expect(ProxyProbe.cachedExit(for: nil, maxAge: 60, now: Date().addingTimeInterval(61)) == nil)

        // Another address, or another user name at the same gateway, is another exit.
        let gateway = try ProxyEndpoint.parse("gate.example:7777:user-session-1:pw")
        #expect(ProxyProbe.cachedExit(for: gateway, maxAge: 60) == nil)
        let other = try ProxyEndpoint.parse("gate.example:7777:user-session-2:pw")
        #expect(other?.url != gateway?.url)
        ProxyProbe.forgetCachedExits()
        #expect(ProxyProbe.cachedExit(for: nil, maxAge: 60) == nil)
    }

    @Test("Lookups sign in to a SOCKS5 proxy with a user name and password")
    func looksUpThroughSOCKS() async throws {
        guard #available(macOS 14, *) else { return }
        let service = try JSONOrigin(body: #"{"ip":"198.51.100.30","country":"NL","timezone":"Europe/Amsterdam"}"#)
        defer { service.stop() }
        let socks = try UpstreamSOCKSStub(username: "carol", password: "pw", route: { $0 == "ipinfo.test" ? service.port : nil })
        defer { socks.stop() }
        let services = [URL(string: "http://ipinfo.test/json")!]
        let endpoint = try ProxyEndpoint.parse("socks5://carol:pw@127.0.0.1:\(socks.port)", allowingSOCKSCredentials: true)
        let exit = try await ProxyProbe.lookupExit(through: endpoint, services: services, timeout: 5)
        #expect(exit.ip == "198.51.100.30" && exit.countryCode == "NL")
        #expect(socks.requests.last?.username == "carol" && socks.requests.last?.host == "ipinfo.test")

        let wrong = try ProxyEndpoint.parse("socks5://carol:nope@127.0.0.1:\(socks.port)", allowingSOCKSCredentials: true)
        await #expect(throws: ProfileError.self) {
            try await ProxyProbe.lookupExit(through: wrong, services: services, timeout: 5)
        }
    }

    @Test("Reachability opens a TCP connection to the proxy only")
    func checksReachability() async throws {
        let open = try await ProxyStub.start(credentials: nil) { _ in nil }
        defer { open.stop() }
        #expect(await ProxyProbe.reachable(ProxyEndpoint(scheme: "http", host: "127.0.0.1", port: open.port)))
        #expect(await ProxyProbe.preflight("http://alice:secret@127.0.0.1:\(open.port)") == nil)
        #expect(open.requests.isEmpty)

        let six = try await ProxyStub.start(credentials: nil, host: "::1") { _ in nil }
        defer { six.stop() }
        #expect(await ProxyProbe.reachable(try #require(try ProxyEndpoint.parse("socks5://[::1]:\(six.port)"))))

        let closed = try await ProxyStub.start(credentials: nil) { _ in nil }
        let port = closed.port
        closed.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        #expect(await !ProxyProbe.reachable(ProxyEndpoint(scheme: "http", host: "127.0.0.1", port: port)))
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(await ProxyProbe.preflight(" 127.0.0.1:\(port) ")
            == "代理 http://127.0.0.1:\(port) 无法连接，浏览器将无法联网。请确认代理已启动。")
        #expect(await ProxyProbe.preflight("") == nil)
        #expect(await ProxyProbe.preflight("not a proxy") == nil)
    }

    private func expectFailure(_ message: String, _ body: () async throws -> ProxyExit,
                               sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            let exit = try await body()
            Issue.record("Expected \(message), got \(exit)", sourceLocation: sourceLocation)
        } catch {
            #expect(error.localizedDescription.contains(message), "\(error.localizedDescription)",
                    sourceLocation: sourceLocation)
        }
    }

}

/// Runs the generated background.js against a stand-in `chrome` API.
private struct SignInScript {
    let context: JSContext

    init(config: String?) throws {
        context = try #require(JSContext())
        context.exceptionHandler = { _, exception in
            Issue.record("background.js threw \(exception?.toString() ?? "")")
        }
        context.setObject(config, forKeyedSubscript: "credentials" as NSString)
        context.evaluateScript("""
            var registration = null, listener = null;
            var chrome = {
              runtime: { getURL: (path) => 'chrome-extension://test/' + path },
              webRequest: { onAuthRequired: { addListener: (fn, filter, extra) => {
                listener = fn; registration = JSON.stringify({urls: filter.urls, extra});
              } } },
            };
            var fetch = (url) => url === 'chrome-extension://test/credentials.json' && credentials
              ? Promise.resolve({ json: () => Promise.resolve(JSON.parse(credentials)) })
              : Promise.reject(new Error('missing'));
            """)
        context.evaluateScript(ProxyAuthExtension.script)
    }

    var registration: String? { context.objectForKeyedSubscript("registration")?.toString() }

    /// The callback's argument, as JSON, once the listener's promises settle.
    func challenge(request: String, isProxy: Bool, host: String, port: Int) -> String? {
        context.evaluateScript("""
            var answer = null;
            listener({requestId: '\(request)', isProxy: \(isProxy), challenger: {host: '\(host)', port: \(port)}},
                     (value) => { answer = JSON.stringify(value); });
            """)
        return context.objectForKeyedSubscript("answer")?.toString()
    }
}

/// Answers lookups made without a proxy.
private final class ExitService: URLProtocol {
    static var answers: [String: (Int, String)] = [:]
    static var served = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.served += 1
        let url = request.url ?? URL(fileURLWithPath: "/")
        let (status, body) = Self.answers[url.absoluteString] ?? (404, "")
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Answers every request with the same JSON body.
private final class JSONOrigin: SocketServer, @unchecked Sendable {
    private let body: String

    init(body: String) throws {
        self.body = body
        try super.init()
    }

    override func handle(_ fd: Int32) {
        guard Sockets.readHead(fd) != nil else { return hangUp(fd) }
        Sockets.write(fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        close(fd)
    }
}

/// A loopback HTTP proxy that asks for Basic sign-in and records every request it receives.
/// `respond` returning nil leaves the request unanswered.
final class ProxyStub: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var target: String
        var authorization: String?
        var headers: [String: String] = [:]
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = ""
    }

    let port: Int
    private let listener: NWListener
    private let respond: @Sendable (Request) -> Response?
    private let lock = NSLock()
    private var log: [Request] = []
    private var connections: [NWConnection] = []
    private var credentials: String?
    private var challengeOnce: Set<String> = []

    private init(listener: NWListener, port: Int, credentials: String?,
                 respond: @escaping @Sendable (Request) -> Response?) {
        self.listener = listener
        self.port = port
        self.credentials = credentials
        self.respond = respond
    }

    static func start(credentials: String?, host: NWEndpoint.Host = "127.0.0.1",
                      respond: @escaping @Sendable (Request) -> Response?) async throws -> ProxyStub {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "anybrowser.proxy.stub")
        let port = try await listener.startAndWait(on: queue)
        let stub = ProxyStub(listener: listener, port: Int(port), credentials: credentials, respond: respond)
        listener.newConnectionHandler = { [weak stub] connection in
            guard let stub else { return connection.cancel() }
            stub.locked { stub.connections.append(connection) }
            connection.start(queue: queue)
            stub.receive(connection, buffer: Data())
        }
        return stub
    }

    var requests: [Request] { locked { log } }

    /// Changes the credentials the proxy accepts from now on.
    func expect(_ credentials: String?) { locked { self.credentials = credentials } }

    /// Challenges the next request for `target` even when it carries the right credentials.
    func challengeNext(_ target: String) { locked { _ = challengeOnce.insert(target) } }

    func stop() {
        listener.cancel()
        for connection in locked({ connections }) { connection.cancel() }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }


    private typealias Tunnel = (host: String, authorization: String?)

    private func receive(_ connection: NWConnection, buffer: Data, tunnel: Tunnel? = nil) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self), tunnel: tunnel)
            } else if complete || error != nil || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer, tunnel: tunnel)
            }
        }
    }

    private func answer(_ connection: NWConnection, head: String, tunnel: Tunnel?) {
        let lines = head.components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ").map(String.init) ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let name = line.prefix { $0 != ":" }
            headers[name.lowercased()] = String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        var request = Request(method: start.first ?? "", target: start.count > 1 ? start[1] : "",
                              authorization: headers["proxy-authorization"], headers: headers)
        if let tunnel {
            // Inside a CONNECT tunnel the stub plays the origin server; log it like a proxied request.
            request.target = "http://\(tunnel.host)\(request.target)"
            request.authorization = tunnel.authorization
        }
        let signedIn = locked { () -> Bool in
            log.append(request)
            if tunnel != nil { return true }
            if challengeOnce.remove(request.target) != nil { return false }
            guard let credentials else { return true }
            return request.authorization == "Basic " + Data(credentials.utf8).base64EncodedString()
        }
        if request.method == "CONNECT", signedIn {
            let host = request.target.hasSuffix(":80") ? String(request.target.dropLast(3)) : request.target
            let established = Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8)
            connection.send(content: established, completion: .contentProcessed { [weak self] _ in
                self?.receive(connection, buffer: Data(), tunnel: (host, request.authorization))
            })
            return
        }
        let response = signedIn
            ? respond(request)
            : Response(status: 407, headers: ["Proxy-Authenticate": #"Basic realm="x""#])
        guard let response else { return }
        let reason = [200: "OK", 302: "Found", 407: "Proxy Authentication Required"][response.status] ?? "Status"
        var text = "HTTP/1.1 \(response.status) \(reason)\r\n"
        let replyHeaders = response.headers.merging(["Content-Type": "text/html; charset=utf-8"]) { mine, _ in mine }
        for (name, value) in replyHeaders { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(response.body.utf8.count)\r\nConnection: close\r\n\r\n\(response.body)"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
