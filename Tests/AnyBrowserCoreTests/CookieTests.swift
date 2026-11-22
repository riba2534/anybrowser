@testable import AnyBrowserCore
import Darwin
import Foundation
import Network
import Testing

@Suite("Cookie import and export")
struct CookieTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("CDP and AnyBrowser exports keep domains, expiry and SameSite")
    func readsDevToolsCookies() throws {
        let file = #"""
        [
          {"name": "sid", "value": "abc", "domain": ".example.com", "path": "/", "expires": 1800000000.5,
           "size": 6, "httpOnly": true, "secure": true, "session": false, "sameSite": "Lax", "priority": "Medium"},
          {"name": "pref", "value": "x", "domain": "www.example.com", "path": "/app", "expires": -1,
           "httpOnly": false, "secure": false, "session": true},
          {"name": "strict", "value": "", "domain": "example.com", "path": "/", "expires": 1800000000,
           "httpOnly": false, "secure": true, "sameSite": "Strict"},
          {"name": "cross", "value": "1", "domain": ".example.com", "path": "/", "expires": -1,
           "httpOnly": false, "secure": true, "sameSite": "None"}
        ]
        """#
        let result = try CookieTransfer.decode(Data(file.utf8), now: now)
        #expect(result.skipped == 0)
        #expect(result.cookies == [
            BrowserCookie(name: "sid", value: "abc", domain: ".example.com", path: "/", expires: 1_800_000_000.5,
                          httpOnly: true, secure: true, sameSite: .lax),
            BrowserCookie(name: "pref", value: "x", domain: "www.example.com", path: "/app", expires: nil,
                          httpOnly: false, secure: false, sameSite: nil),
            BrowserCookie(name: "strict", value: "", domain: "example.com", path: "/", expires: 1_800_000_000,
                          httpOnly: false, secure: true, sameSite: .strict),
            BrowserCookie(name: "cross", value: "1", domain: ".example.com", path: "/", expires: nil,
                          httpOnly: false, secure: true, sameSite: BrowserCookie.SameSite.none),
        ])
    }

    @Test("Cookie-Editor and EditThisCookie exports map hostOnly, session and SameSite")
    func readsExtensionCookies() throws {
        let file = #"""
        [
          {"domain": ".example.com", "expirationDate": 1800000000.25, "hostOnly": false, "httpOnly": true,
           "name": "a", "path": "/", "sameSite": "no_restriction", "secure": true, "session": false,
           "storeId": "0", "value": "1", "id": 1},
          {"domain": "example.com", "hostOnly": false, "name": "b", "path": "/", "sameSite": "lax",
           "secure": false, "session": true, "expirationDate": 1800000000, "value": "2"},
          {"domain": ".login.example.com", "hostOnly": true, "name": "c", "path": "", "sameSite": "strict",
           "session": false, "expirationDate": 1800000000, "value": "3"},
          {"domain": "example.com", "hostOnly": true, "name": "d", "sameSite": "unspecified", "session": true, "value": "4"},
          {"domain": "example.com", "name": "e", "sameSite": null, "value": "5", "firstPartyDomain": ""}
        ]
        """#
        let result = try CookieTransfer.decode(Data(file.utf8), now: now)
        #expect(result.skipped == 0)
        #expect(result.cookies == [
            BrowserCookie(name: "a", value: "1", domain: ".example.com", path: "/", expires: 1_800_000_000.25,
                          httpOnly: true, secure: true, sameSite: BrowserCookie.SameSite.none),
            BrowserCookie(name: "b", value: "2", domain: ".example.com", path: "/", expires: nil,
                          httpOnly: false, secure: false, sameSite: .lax),
            BrowserCookie(name: "c", value: "3", domain: "login.example.com", path: "/", expires: 1_800_000_000,
                          httpOnly: false, secure: false, sameSite: .strict),
            BrowserCookie(name: "d", value: "4", domain: "example.com", path: "/", expires: nil,
                          httpOnly: false, secure: false, sameSite: nil),
            BrowserCookie(name: "e", value: "5", domain: "example.com", path: "/", expires: nil,
                          httpOnly: false, secure: false, sameSite: nil),
        ])
    }

    @Test("Entries that can't be read are skipped and counted")
    func skipsInvalidEntries() throws {
        let file = #"""
        [
          "sid=abc", 42, null,
          {"value": "x", "domain": "example.com"},
          {"name": "", "domain": "example.com"},
          {"name": "x"},
          {"name": "x", "domain": ""},
          {"name": "x", "domain": "..", "hostOnly": true},
          {"name": "x", "domain": "example.com", "value": 1},
          {"name": "x", "domain": "example.com", "secure": "yes"},
          {"name": "x", "domain": "example.com", "hostOnly": "yes"},
          {"name": "x", "domain": "example.com", "expirationDate": 1600000000},
          {"name": "x", "domain": "example.com", "expires": "soon"},
          {"name": "x", "domain": "example.com", "sameSite": "sometimes"},
          {"name": "x", "domain": "example.com", "sameSite": "no_restriction", "secure": false},
          {"name": "x", "domain": "example.com", "partitionKey": {"topLevelSite": "https://example.org"}},
          {"name": "x", "domain": "example.com", "partitionKeyOpaque": true},
          {"name": "ok", "domain": "example.com", "partitionKey": null}
        ]
        """#
        let result = try CookieTransfer.decode(Data(file.utf8), now: now)
        #expect(result.skipped == 17)
        #expect(result.cookies == [
            BrowserCookie(name: "ok", value: "", domain: "example.com", path: "/", expires: nil,
                          httpOnly: false, secure: false, sameSite: nil),
        ])
        for file in [#"{"items": []}"#, #"{"cookies": {}}"#, "sid=abc", #""text""#, "", "a\tb\tc\n"] {
            #expect(throws: ProfileError.self, "\(file)") { try CookieTransfer.decode(Data(file.utf8), now: now) }
        }
    }

    @Test("Playwright storage state, J2Team wrappers and Netscape cookies.txt are read")
    func readsOtherFileFormats() throws {
        let storageState = #"""
        {"cookies": [{"name": "sid", "value": "1", "domain": ".example.com", "path": "/", "expires": -1,
                      "httpOnly": true, "secure": true, "sameSite": "Lax"}],
         "origins": [{"origin": "https://example.com", "localStorage": []}]}
        """#
        #expect(try CookieTransfer.decode(Data(storageState.utf8), now: now).cookies == [
            BrowserCookie(name: "sid", value: "1", domain: ".example.com", path: "/", expires: nil,
                          httpOnly: true, secure: true, sameSite: .lax),
        ])
        let j2team = #"{"url": "https://example.com", "cookies": [{"name": "a", "value": "2", "domain": "example.com", "hostOnly": true}, 7]}"#
        let wrapped = try CookieTransfer.decode(Data(j2team.utf8), now: now)
        #expect(wrapped.cookies.map(\.name) == ["a"] && wrapped.skipped == 1)

        // Columns: domain, subdomains, path, secure, expiry (0 = session), name, value.
        let netscape = "# Netscape HTTP Cookie File\r\n# https://curl.se/docs/http-cookies.html\r\n\r\n"
            + ".example.com\tTRUE\t/\tTRUE\t1800000000\tsid\tabc\r\n"
            + "#HttpOnly_www.example.com\tFALSE\t/app\tFALSE\t0\tsession\tx\ty\r\n"
            + "example.com\tFALSE\t/\tFALSE\t1600000000\told\t1\r\n"
            + "example.com\tmaybe\t/\tFALSE\t0\tbad\t1\r\n"
            + "short\tline\r\n"
        let read = try CookieTransfer.decode(Data(netscape.utf8), now: now)
        #expect(read.cookies == [
            BrowserCookie(name: "sid", value: "abc", domain: ".example.com", path: "/", expires: 1_800_000_000,
                          httpOnly: false, secure: true, sameSite: nil),
            BrowserCookie(name: "session", value: "x\ty", domain: "www.example.com", path: "/app", expires: nil,
                          httpOnly: true, secure: false, sameSite: nil),
        ])
        // Expired, malformed and short lines are skipped; comments and blank lines are not entries.
        #expect(read.skipped == 3)
        // Without the header, one well-formed line is enough to recognize the format.
        let headless = try CookieTransfer.decode(Data("example.com\tFALSE\t/\tFALSE\t0\tk\tv\n".utf8), now: now)
        #expect(headless.cookies.map(\.domain) == ["example.com"])
    }

    @Test("An expiry of 0 means a session cookie in every format")
    func readsZeroExpiryAsSession() throws {
        let file = #"""
        [{"name": "a", "domain": "example.com", "expirationDate": 0},
         {"name": "b", "domain": "example.com", "expires": 0},
         {"name": "c", "domain": "example.com", "expires": -1},
         {"name": "d", "domain": "example.com", "expirationDate": 0.5}]
        """#
        let result = try CookieTransfer.decode(Data(file.utf8), now: now)
        #expect(result.cookies.map(\.name) == ["a", "b", "c"])
        #expect(result.cookies.allSatisfy { $0.expires == nil })
        #expect(result.skipped == 1)
    }

    @Test("Partitioned cookies keep their top-level site")
    func readsPartitionedCookies() throws {
        let file = #"""
        [
          {"name": "chips", "value": "1", "domain": "widget.example", "secure": true,
           "partitionKey": {"topLevelSite": "https://shop.example", "hasCrossSiteAncestor": true}},
          {"name": "legacy", "value": "2", "domain": "widget.example", "secure": true, "partitionKey": "https://news.example"},
          {"name": "editor", "value": "3", "domain": ".widget.example", "secure": true,
           "partitionKey": {"topLevelSite": "https://shop.example"}},
          {"name": "insecure", "domain": "widget.example", "partitionKey": {"topLevelSite": "https://shop.example"}},
          {"name": "path", "domain": "widget.example", "secure": true, "partitionKey": {"topLevelSite": "https://shop.example/x"}},
          {"name": "number", "domain": "widget.example", "secure": true, "partitionKey": 4},
          {"name": "flag", "domain": "widget.example", "secure": true,
           "partitionKey": {"topLevelSite": "https://shop.example", "hasCrossSiteAncestor": "no"}},
          {"name": "empty", "domain": "widget.example", "secure": true, "partitionKey": {}}
        ]
        """#
        let result = try CookieTransfer.decode(Data(file.utf8), now: now)
        let keys: [BrowserCookie.PartitionKey?] = [
            BrowserCookie.PartitionKey(topLevelSite: "https://shop.example", hasCrossSiteAncestor: true),
            BrowserCookie.PartitionKey(topLevelSite: "https://news.example", hasCrossSiteAncestor: false),
            BrowserCookie.PartitionKey(topLevelSite: "https://shop.example", hasCrossSiteAncestor: false),
        ]
        #expect(result.cookies.map(\.partitionKey) == keys)
        #expect(result.skipped == 5)
        let parameters = CookieTransfer.parameters(result.cookies[0])
        #expect(parameters["partitionKey"] as? NSDictionary == ["topLevelSite": "https://shop.example", "hasCrossSiteAncestor": true])
        // Same name, domain and path in another partition is another cookie.
        #expect(result.cookies[0].key != BrowserCookie(name: "chips", value: "", domain: "widget.example", path: "/",
                                                       httpOnly: false, secure: true).key)
    }

    @Test("Cookie-Editor exports use chrome.cookies field names and SameSite values")
    func writesTheCookieEditorFormat() throws {
        let cookies = [
            BrowserCookie(name: "sid", value: "v", domain: ".example.com", path: "/", expires: 1_800_000_000.9,
                          httpOnly: true, secure: true, sameSite: BrowserCookie.SameSite.none),
            BrowserCookie(name: "host", value: "h", domain: "www.example.com", path: "/a", expires: nil,
                          httpOnly: false, secure: false, sameSite: nil),
            BrowserCookie(name: "chips", value: "c", domain: "widget.example", path: "/", expires: nil,
                          httpOnly: false, secure: true, sameSite: .lax,
                          partitionKey: BrowserCookie.PartitionKey(topLevelSite: "https://shop.example", hasCrossSiteAncestor: false)),
        ]
        let expected = #"""
        [
          {
            "domain": ".example.com",
            "expirationDate": 1800000000,
            "hostOnly": false,
            "httpOnly": true,
            "name": "sid",
            "path": "/",
            "sameSite": "no_restriction",
            "secure": true,
            "session": false,
            "storeId": null,
            "value": "v"
          },
          {
            "domain": "widget.example",
            "hostOnly": true,
            "httpOnly": false,
            "name": "chips",
            "partitionKey": {"hasCrossSiteAncestor": false, "topLevelSite": "https://shop.example"},
            "path": "/",
            "sameSite": "lax",
            "secure": true,
            "session": true,
            "storeId": null,
            "value": "c"
          },
          {
            "domain": "www.example.com",
            "hostOnly": true,
            "httpOnly": false,
            "name": "host",
            "path": "/a",
            "sameSite": "unspecified",
            "secure": false,
            "session": true,
            "storeId": null,
            "value": "h"
          }
        ]

        """#
        let data = CookieTransfer.encode(cookies, as: .cookieEditor)
        #expect(String(decoding: data, as: UTF8.self) == expected)
        var floored = cookies
        floored[0].expires = 1_800_000_000
        #expect(try CookieTransfer.decode(data, now: now).cookies == [floored[0], floored[2], floored[1]])
        // The DevTools format carries the partition too.
        let devTools = CookieTransfer.encode([cookies[2]], as: .devTools)
        #expect(try CookieTransfer.decode(devTools, now: now).cookies == [cookies[2]])
        #expect(String(decoding: devTools, as: UTF8.self).contains(#""partitionKey": {"hasCrossSiteAncestor": false, "topLevelSite": "https://shop.example"}"#))
    }

    @Test("Exports list fields in a fixed order, sorted by site")
    func writesTheExportFormat() throws {
        let cookies = [
            BrowserCookie(name: "z", value: "q\"uote\\\n\u{1}", domain: "www.example.com", path: "/", expires: nil,
                          httpOnly: false, secure: false, sameSite: nil),
            BrowserCookie(name: "sid", value: "值", domain: ".example.com", path: "/", expires: 1_800_000_000.9,
                          httpOnly: true, secure: true, sameSite: BrowserCookie.SameSite.none),
            BrowserCookie(name: "a", value: "1", domain: ".another.org", path: "/x", expires: nil,
                          httpOnly: false, secure: false, sameSite: .strict),
        ]
        let expected = #"""
        [
          {
            "name": "a",
            "value": "1",
            "domain": ".another.org",
            "path": "/x",
            "expires": -1,
            "httpOnly": false,
            "secure": false,
            "sameSite": "Strict"
          },
          {
            "name": "sid",
            "value": "值",
            "domain": ".example.com",
            "path": "/",
            "expires": 1800000000,
            "httpOnly": true,
            "secure": true,
            "sameSite": "None"
          },
          {
            "name": "z",
            "value": "q\"uote\\\n\u0001",
            "domain": "www.example.com",
            "path": "/",
            "expires": -1,
            "httpOnly": false,
            "secure": false
          }
        ]

        """#
        let data = CookieTransfer.encode(cookies, as: .devTools)
        #expect(String(decoding: data, as: UTF8.self) == expected)
        var floored = cookies
        floored[1].expires = 1_800_000_000
        let read = try CookieTransfer.decode(data, now: now)
        #expect(read.skipped == 0)
        #expect(read.cookies == [floored[2], floored[1], floored[0]])
        #expect(String(decoding: CookieTransfer.encode([], as: .devTools), as: UTF8.self) == "[]\n")
        #expect(String(decoding: CookieTransfer.encode([], as: .cookieEditor), as: UTF8.self) == "[]\n")
    }

    @Test("Session cookies are set without an expiry")
    func buildsSetCookiesParameters() throws {
        let session = CookieTransfer.parameters(BrowserCookie(
            name: "a", value: "1", domain: "example.com", path: "/", expires: nil, httpOnly: true, secure: false, sameSite: nil))
        #expect(session as NSDictionary == [
            "name": "a", "value": "1", "domain": "example.com", "path": "/", "httpOnly": true, "secure": false,
        ] as NSDictionary)
        let persistent = CookieTransfer.parameters(BrowserCookie(
            name: "b", value: "2", domain: ".example.com", path: "/p", expires: 1_800_000_000.5, httpOnly: false,
            secure: true, sameSite: .lax))
        #expect(persistent as NSDictionary == [
            "name": "b", "value": "2", "domain": ".example.com", "path": "/p", "httpOnly": false, "secure": true,
            "expires": 1_800_000_000.5, "sameSite": "Lax",
        ] as NSDictionary)
    }

    @Test("Exports are readable only by the owner, even when replacing a file")
    func writesPrivateFiles() throws {
        let directory = try scratchDirectory("cookie-file")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("cookies.json")
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)

        try CookieTransfer.writeFile(Data("[]\n".utf8), to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "[]\n")
        #expect(try permissions(target) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["cookies.json"])
        #expect(try CookieTransfer.readFile(target) == Data("[]\n".utf8))

        #expect(throws: ProfileError.self) {
            try CookieTransfer.writeFile(Data(), to: directory.appendingPathComponent("missing/cookies.json"))
        }
        #expect(throws: ProfileError.self) { try CookieTransfer.readFile(directory) }
        let large = directory.appendingPathComponent("large.json")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(CookieTransfer.maximumFileSize + 1))
        try handle.close()
        #expect(throws: ProfileError.self) { try CookieTransfer.readFile(large) }
    }

    @Test("The DevTools client only connects to a browser endpoint on 127.0.0.1")
    func refusesNonLocalEndpoints() throws {
        #expect(DevToolsClient.accepts(try #require(URL(string: "ws://127.0.0.1:9306/devtools/browser/\(UUID())"))))
        for address in [
            "ws://localhost:9306/devtools/browser/abc",
            "ws://127.0.0.2:9306/devtools/browser/abc",
            "ws://[::1]:9306/devtools/browser/abc",
            "ws://example.com:9306/devtools/browser/abc",
            "ws://127.0.0.1.example.com:9306/devtools/browser/abc",
            "wss://127.0.0.1:9306/devtools/browser/abc",
            "http://127.0.0.1:9306/devtools/browser/abc",
            "ws://127.0.0.1/devtools/browser/abc",
            "ws://127.0.0.1:9306/devtools/page/abc",
            "ws://127.0.0.1:9306/devtools/browser/",
            "ws://127.0.0.1:9306/devtools/browser/../page/abc",
            "ws://127.0.0.1:9306/devtools/browser/abc%2F..",
            "ws://user:pw@127.0.0.1:9306/devtools/browser/abc",
            "ws://127.0.0.1:9306/devtools/browser/abc?x=1",
            "ws://127.0.0.1:9306/devtools/browser/abc#x",
        ] {
            let url = try #require(URL(string: address))
            #expect(!DevToolsClient.accepts(url), "\(address)")
            #expect(throws: ProfileError.self) { try DevToolsClient(endpoint: url) }
        }
    }

    @Test("Replies are matched to their commands; events and stray replies are ignored")
    func matchesRepliesByID() async throws {
        let server = try await FakeDevTools.start { method, params in
            method == "Slow" ? .delayed(0.3, params) : .result(params)
        }
        defer { server.stop() }
        let client = try DevToolsClient(endpoint: server.endpoint)
        defer { client.close() }
        async let slow = client.send("Slow", ["n": 1])
        try await Task.sleep(nanoseconds: 50_000_000)
        let fast = try await client.send("Fast", ["n": 2])
        #expect(fast["n"] as? Int == 2)
        let delayed = try await slow
        #expect(delayed["n"] as? Int == 1)
        #expect(server.methods == ["Slow", "Fast"])
    }

    @Test("CDP errors, timeouts and disconnects are reported")
    func reportsFailures() async throws {
        let server = try await FakeDevTools.start { method, _ in
            switch method {
            case "Fail": return .error(-32602, "Invalid cookie fields")
            case "Hang": return .silent
            case "Bye": return .hangUp
            default: return .result([:])
            }
        }
        defer { server.stop() }
        let client = try DevToolsClient(endpoint: server.endpoint, timeout: 0.3)
        defer { client.close() }
        do {
            _ = try await client.send("Fail")
            Issue.record("A CDP error was not reported")
        } catch let error as DevToolsCommandError {
            #expect(error.method == "Fail")
            #expect(error.code == -32602)
            #expect(error.message == "Invalid cookie fields")
        }
        await #expect(throws: ProfileError.self) { try await client.send("Hang") }
        // A command that timed out leaves the connection usable.
        #expect(try await client.send("Echo").isEmpty)
        await #expect(throws: ProfileError.self) { try await client.send("Bye") }
        await #expect(throws: ProfileError.self) { try await client.send("Echo") }
    }

    @Test("Closing the client fails commands that are still waiting")
    func closeFailsPendingCommands() async throws {
        let server = try await FakeDevTools.start { _, _ in .silent }
        defer { server.stop() }
        let client = try DevToolsClient(endpoint: server.endpoint)
        let started = Date()
        let waiting = Task { try await client.send("Hang") }
        try await Task.sleep(nanoseconds: 200_000_000)
        client.close()
        await #expect(throws: ProfileError.self) { try await waiting.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("Exports read Storage.getCookies, partitioned cookies included")
    func exportsFromTheBrowser() async throws {
        let server = try await FakeDevTools.start { method, _ in
            guard method == "Storage.getCookies" else { return .error(-32601, "not found") }
            return .result(["cookies": [
                ["name": "sid", "value": "abc", "domain": ".example.com", "path": "/", "expires": 1_900_000_000.7,
                 "size": 6, "httpOnly": true, "secure": true, "session": false, "sameSite": "Lax"],
                ["name": "pref", "value": "x", "domain": "example.com", "path": "/", "expires": -1,
                 "httpOnly": false, "secure": false, "session": true],
                ["name": "chips", "value": "y", "domain": "widget.example", "path": "/", "expires": -1,
                 "httpOnly": false, "secure": true, "session": true, "sameSite": "None",
                 "partitionKey": ["topLevelSite": "https://example.com", "hasCrossSiteAncestor": false]],
                // Partitioned by an opaque origin: nothing could set it again.
                ["name": "opaque", "value": "z", "domain": "widget.example", "path": "/", "expires": -1,
                 "httpOnly": false, "secure": true, "session": true, "partitionKeyOpaque": true],
                // Set by document.cookie = "nameless": not partitioned, and not moved either.
                ["name": "", "value": "nameless", "domain": "example.com", "path": "/", "expires": -1,
                 "httpOnly": false, "secure": false, "session": true],
            ]])
        }
        defer { server.stop() }
        let expected = [
            BrowserCookie(name: "sid", value: "abc", domain: ".example.com", path: "/", expires: 1_900_000_000,
                          httpOnly: true, secure: true, sameSite: .lax),
            BrowserCookie(name: "pref", value: "x", domain: "example.com", path: "/", expires: nil,
                          httpOnly: false, secure: false, sameSite: nil),
            BrowserCookie(name: "chips", value: "y", domain: "widget.example", path: "/", expires: nil,
                          httpOnly: false, secure: true, sameSite: BrowserCookie.SameSite.none,
                          partitionKey: BrowserCookie.PartitionKey(topLevelSite: "https://example.com", hasCrossSiteAncestor: false)),
        ]
        let export = try await CookieTransfer.exportCookies(from: server.endpoint)
        #expect(export.count == 3 && export.skipped == 2)
        #expect(export.summary == "已导出 3 条 Cookie。另有 2 条 Cookie 无法迁移，未导出。")
        #expect(String(decoding: export.data, as: UTF8.self).contains(#""sameSite": "no_restriction""#))
        #expect(try CookieTransfer.decode(export.data, now: now).cookies == expected)
        let devTools = try await CookieTransfer.exportCookies(from: server.endpoint, format: .devTools)
        #expect(String(decoding: devTools.data, as: UTF8.self).contains(#""sameSite": "None""#))
        #expect(try CookieTransfer.decode(devTools.data, now: now).cookies == expected)
    }

    @Test("Imports retry a refused batch one cookie at a time")
    func importsInBatches() async throws {
        let jar = CookieJar()
        let server = try await FakeDevTools.start { method, params in
            if method == "Storage.getCookies" { return .result(["cookies": jar.cookies]) }
            guard method == "Storage.setCookies", let cookies = params["cookies"] as? [[String: Any]] else {
                return .error(-32601, "not found")
            }
            if cookies.contains(where: { $0["name"] as? String == "bad" }) { return .error(-32602, "Invalid cookie fields") }
            jar.set(cookies)
            return .result([:])
        }
        defer { server.stop() }
        var entries: [[String: Any]] = (0..<205).map { ["name": "c\($0)", "value": "\($0)", "domain": "example.com"] }
        entries[150]["name"] = "bad"
        entries.append(["name": "", "domain": "example.com"])
        let data = try JSONSerialization.data(withJSONObject: entries)

        let result = try await CookieTransfer.importCookies(data, into: server.endpoint)
        #expect(result == CookieTransfer.ImportResult(imported: 204, skipped: 2))
        #expect(server.methods.first == "Storage.getCookies" && server.methods.last == "Storage.getCookies")
        let batches = server.commands.compactMap { $0["cookies"] as? [[String: Any]] }
        // Typed separately: Swift 6.1 cannot type-check the whole expression inside #expect in time.
        let sizes: [Int] = [100, 100] + Array(repeating: 1, count: 100) + [5]
        #expect(batches.map(\.count) == sizes)
        let first = try #require(batches.first?.first)
        #expect(first as NSDictionary == [
            "name": "c0", "value": "0", "domain": "example.com", "path": "/", "httpOnly": false, "secure": false,
        ] as NSDictionary)
    }

    @Test("Imports read the cookies back and count what the browser dropped to stay within its limits")
    func importsReportEvictions() async throws {
        // Keeps only the 150 most recently set cookies, like Chromium's per-site limit.
        let jar = CookieJar(limit: 150)
        jar.set([["name": "login", "value": "old", "domain": ".example.com", "path": "/"],
                 ["name": "kept", "value": "old", "domain": "other.example", "path": "/"]])
        let server = try await FakeDevTools.start { method, params in
            switch method {
            case "Storage.getCookies": return .result(["cookies": jar.cookies])
            case "Storage.setCookies": jar.set(params["cookies"] as? [[String: Any]] ?? [])
                return .result([:])
            default: return .error(-32601, "not found")
            }
        }
        defer { server.stop() }
        // The same cookie twice in a file: the browser keeps the later value, and the earlier one is skipped.
        var entries: [[String: Any]] = (0..<200).map { ["name": "c\($0)", "value": "\($0)", "domain": "example.com"] }
        entries.append(["name": "c199", "value": "again", "domain": "example.com"])
        entries.append(["name": "kept", "value": "new", "domain": "other.example"])
        let result = try await CookieTransfer.importCookies(try JSONSerialization.data(withJSONObject: entries),
                                                            into: server.endpoint)
        // 201 distinct cookies: the oldest 52 (the existing login, then c0–c50) fell out; `kept` was replaced, not lost.
        #expect(result == CookieTransfer.ImportResult(imported: 150, skipped: 1, evicted: 51, displaced: 1))
        #expect(result.summary == "已导入 150 条 Cookie，跳过 1 条。另有 51 条超出浏览器的 Cookie 数量上限，未能保留。原有的 1 条 Cookie 因数量上限被浏览器清除。")
        #expect(jar.cookies.contains { $0["name"] as? String == "c199" && $0["value"] as? String == "again" })
        #expect(server.commands.compactMap { $0["cookies"] as? [Any] }.map(\.count) == [100, 100, 1])

        // Partitioned cookies are matched with their partition.
        // Partitioned cookies are matched with their partition, which the browser keeps as a site.
        let partitioned = CookieJar(site: { $0.replacingOccurrences(of: "://shop.", with: "://") })
        let chips = try await FakeDevTools.start { method, params in
            if method == "Storage.getCookies" { return .result(["cookies": partitioned.cookies]) }
            partitioned.set(params["cookies"] as? [[String: Any]] ?? [])
            return .result([:])
        }
        defer { chips.stop() }
        let file = #"[{"name": "p", "domain": "w.example", "secure": true, "partitionKey": {"topLevelSite": "https://shop.a.example"}},"#
            + #" {"name": "p", "domain": "w.example", "secure": true, "partitionKey": {"topLevelSite": "https://b.example"}}]"#
        #expect(try await CookieTransfer.importCookies(Data(file.utf8), into: chips.endpoint)
            == CookieTransfer.ImportResult(imported: 2, skipped: 0))
        #expect(partitioned.cookies.compactMap { ($0["partitionKey"] as? [String: Any])?["topLevelSite"] as? String }
            == ["https://a.example", "https://b.example"])
    }

    @Test("Domains are lowercased as the browser keeps them, so imports count what it read back")
    func lowercasesDomains() async throws {
        let file = #"[{"name": "up", "value": "1", "domain": "UPPER.Example.COM"},"#
            + #" {"name": "dot", "value": "2", "domain": ".Dot.Example.COM"},"#
            + #" {"name": "up", "value": "3", "domain": "upper.example.com"},"#
            + #" {"name": "low", "value": "4", "domain": "lower.example.com"}]"#
        #expect(try CookieTransfer.decode(Data(file.utf8), now: now).cookies.map(\.domain)
            == ["upper.example.com", ".dot.example.com", "upper.example.com", "lower.example.com"])

        let jar = CookieJar()
        let server = try await FakeDevTools.start { method, params in
            switch method {
            case "Storage.getCookies": return .result(["cookies": jar.cookies])
            case "Storage.setCookies":
                // As Chromium does.
                jar.set((params["cookies"] as? [[String: Any]] ?? []).map { cookie in
                    var stored = cookie
                    stored["domain"] = (cookie["domain"] as? String)?.lowercased()
                    return stored
                })
                return .result([:])
            default: return .error(-32601, "not found")
            }
        }
        defer { server.stop() }
        // Both spellings of `up` name one cookie: the browser keeps the later, and the earlier is skipped.
        #expect(try await CookieTransfer.importCookies(Data(file.utf8), into: server.endpoint)
            == CookieTransfer.ImportResult(imported: 3, skipped: 1))
        #expect(jar.cookies.contains { $0["name"] as? String == "up" && $0["value"] as? String == "3" })
    }

    @Test("A partition read back as its site still matches the cookie that was set")
    func matchesPartitionSites() {
        let key = { (site: String?, crossSite: Bool) in
            BrowserCookie.Key(name: "p", domain: "w.example", path: "/",
                              partitionKey: site.map { BrowserCookie.PartitionKey(topLevelSite: $0, hasCrossSiteAncestor: crossSite) })
        }
        let matches = CookieTransfer.KeyIndex.matches
        #expect(matches(key("https://shop.example.com", false), key("https://example.com", false)))
        #expect(matches(key("https://example.com", false), key("https://example.com", false)))
        #expect(matches(key(nil, false), key(nil, false)))
        #expect(!matches(key("https://badexample.com", false), key("https://example.com", false)))
        #expect(!matches(key("http://shop.example.com", false), key("https://example.com", false)))
        #expect(!matches(key("https://shop.example.com", true), key("https://example.com", false)))
        #expect(!matches(key("https://example.com", false), key(nil, false)))
        #expect(!matches(key(nil, false), key("https://example.com", false)))
        #expect(CookieTransfer.KeyIndex([key("https://example.com", false)]).contains(sent: key("https://a.example.com", false)))
        #expect(CookieTransfer.KeyIndex([key("https://a.example.com", false)]).contains(stored: key("https://example.com", false)))
    }

    @Test("An import stops when the browser goes away")
    func importStopsOnDisconnect() async throws {
        let server = try await FakeDevTools.start { _, _ in .hangUp }
        defer { server.stop() }
        let data = Data(#"[{"name": "a", "value": "1", "domain": "example.com"}]"#.utf8)
        let started = Date()
        // Nothing was set, so the connection error is reported as it is.
        #expect(try await importError(data, into: server.endpoint) == "与浏览器的调试连接已断开。")
        // Fails as soon as the connection drops rather than after the command timeout.
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(server.methods == ["Storage.getCookies"])

        // When only the read-back fails, the cookies are in, and the error says so.
        let readBack = Counter()
        let late = try await FakeDevTools.start { method, _ in
            guard method == "Storage.getCookies" else { return .result([:]) }
            return readBack.next() == 0 ? .result(["cookies": []]) : .hangUp
        }
        defer { late.stop() }
        #expect(try await importError(data, into: late.endpoint)
            == "已导入 1 条 Cookie，但无法确认浏览器实际保留了多少。与浏览器的调试连接已断开。")
    }

    @Test("An interrupted import says how many cookies were already set")
    func interruptedImportReportsProgress() async throws {
        // The second batch never arrives.
        let batches = try await FakeDevTools.start { method, params in
            if method == "Storage.getCookies" { return .result(["cookies": []]) }
            let names = (params["cookies"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return names.contains("c100") ? .hangUp : .result([:])
        }
        defer { batches.stop() }
        let many = try JSONSerialization.data(withJSONObject: (0..<150).map { ["name": "c\($0)", "domain": "example.com"] })
        #expect(try await importError(many, into: batches.endpoint)
            == "导入中断：已导入 100 条 Cookie，其余未导入。与浏览器的调试连接已断开。")

        // A refused batch is retried one cookie at a time, and the connection drops after the first.
        let single = try await FakeDevTools.start { method, params in
            if method == "Storage.getCookies" { return .result(["cookies": []]) }
            let names = (params["cookies"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            if names.count > 1 { return .error(-32602, "Invalid cookie fields") }
            return names == ["c0"] ? .result([:]) : .hangUp
        }
        defer { single.stop() }
        let few = Data(#"[{"name": "c0", "domain": "example.com"}, {"name": "c1", "domain": "example.com"}]"#.utf8)
        #expect(try await importError(few, into: single.endpoint)
            == "导入中断：已导入 1 条 Cookie，其余未导入。与浏览器的调试连接已断开。")
    }

    private func importError(_ data: Data, into endpoint: URL) async throws -> String {
        do {
            _ = try await CookieTransfer.importCookies(data, into: endpoint)
        } catch let error as ProfileError {
            return error.localizedDescription
        }
        throw VerificationFailure.message("The import did not fail")
    }
}

/// The cookies a fake browser holds, keyed like Chromium's: setting one with the same name, domain,
/// path and partition replaces it. Beyond `limit` the least recently set ones are dropped.
private final class CookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    /// What the browser makes of a partition's top-level site.
    private let site: (String) -> String
    private var stored: [[String: Any]] = []

    init(limit: Int = .max, site: @escaping (String) -> String = { $0 }) {
        self.limit = limit
        self.site = site
    }

    var cookies: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ cookies: [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }
        for cookie in cookies {
            var value = cookie
            if value["path"] == nil { value["path"] = "/" }
            if var partition = value["partitionKey"] as? [String: Any], let top = partition["topLevelSite"] as? String {
                partition["topLevelSite"] = site(top)
                value["partitionKey"] = partition
            }
            let key = Self.key(value)
            stored.removeAll { Self.key($0) == key }
            stored.append(value)
        }
        if stored.count > limit { stored.removeFirst(stored.count - limit) }
    }

    private static func key(_ cookie: [String: Any]) -> String {
        let partition = (cookie["partitionKey"] as? [String: Any])?["topLevelSite"] as? String ?? ""
        return [cookie["name"], cookie["domain"], cookie["path"]].map { "\($0 ?? "")" }.joined(separator: "|") + "|" + partition
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}

/// A WebSocket server on 127.0.0.1 that answers DevTools commands, sending an event and a stray reply first.
final class FakeDevTools: @unchecked Sendable {
    enum Reply {
        case result([String: Any])
        case delayed(TimeInterval, [String: Any])
        case error(Int, String)
        case silent
        case hangUp
    }

    let endpoint: URL
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var received: [(method: String, params: [String: Any])] = []
    private let reply: (String, [String: Any]) -> Reply

    var methods: [String] { locked { received.map(\.method) } }
    var commands: [[String: Any]] { locked { received.map(\.params) } }

    private init(listener: NWListener, queue: DispatchQueue, endpoint: URL, reply: @escaping (String, [String: Any]) -> Reply) {
        self.listener = listener
        self.queue = queue
        self.endpoint = endpoint
        self.reply = reply
    }

    static func start(_ reply: @escaping (String, [String: Any]) -> Reply) async throws -> FakeDevTools {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "anybrowser.tests.devtools")
        let port = try await listener.startAndWait(on: queue)
        let endpoint = try #require(URL(string: "ws://127.0.0.1:\(port)/devtools/browser/\(UUID().uuidString)"))
        let server = FakeDevTools(listener: listener, queue: queue, endpoint: endpoint, reply: reply)
        listener.newConnectionHandler = { [weak server] connection in
            connection.start(queue: queue)
            server?.receive(on: connection)
        }
        return server
    }

    func stop() {
        listener.cancel()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [self] data, _, _, error in
            guard error == nil, let data,
                  let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = command["id"] as? Int, let method = command["method"] as? String else {
                connection.cancel()
                return
            }
            let params = command["params"] as? [String: Any] ?? [:]
            locked { received.append((method, params)) }
            send(["method": "Target.targetInfoChanged", "params": [:]], on: connection)
            send(["id": id + 1000, "result": ["stray": true]], on: connection)
            switch reply(method, params) {
            case .result(let result):
                send(["id": id, "result": result], on: connection)
            case .delayed(let delay, let result):
                queue.asyncAfter(deadline: .now() + delay) { self.send(["id": id, "result": result], on: connection) }
            case .error(let code, let message):
                send(["id": id, "error": ["code": code, "message": message]], on: connection)
            case .silent:
                break
            case .hangUp:
                connection.cancel()
                return
            }
            receive(on: connection)
        }
    }

    private func send(_ message: [String: Any], on connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let context = NWConnection.ContentContext(identifier: "reply", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}
