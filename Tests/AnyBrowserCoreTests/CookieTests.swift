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
        for file in [#"{"cookies": []}"#, "sid=abc", #""text""#, ""] {
            #expect(throws: ProfileError.self) { try CookieTransfer.decode(Data(file.utf8), now: now) }
        }
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
        let data = CookieTransfer.encode(cookies)
        #expect(String(decoding: data, as: UTF8.self) == expected)
        var floored = cookies
        floored[1].expires = 1_800_000_000
        let read = try CookieTransfer.decode(data, now: now)
        #expect(read.skipped == 0)
        #expect(read.cookies == [floored[2], floored[1], floored[0]])
        #expect(String(decoding: CookieTransfer.encode([]), as: UTF8.self) == "[]\n")
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

    @Test("Exports read Storage.getCookies and leave partitioned cookies out")
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
            ]])
        }
        defer { server.stop() }
        let export = try await CookieTransfer.exportCookies(from: server.endpoint)
        #expect(export.count == 2)
        #expect(try CookieTransfer.decode(export.data, now: now).cookies == [
            BrowserCookie(name: "sid", value: "abc", domain: ".example.com", path: "/", expires: 1_900_000_000,
                          httpOnly: true, secure: true, sameSite: .lax),
            BrowserCookie(name: "pref", value: "x", domain: "example.com", path: "/", expires: nil,
                          httpOnly: false, secure: false, sameSite: nil),
        ])
    }

    @Test("Imports retry a refused batch one cookie at a time")
    func importsInBatches() async throws {
        let server = try await FakeDevTools.start { method, params in
            guard method == "Storage.setCookies", let cookies = params["cookies"] as? [[String: Any]] else {
                return .error(-32601, "not found")
            }
            return cookies.contains { $0["name"] as? String == "bad" } ? .error(-32602, "Invalid cookie fields") : .result([:])
        }
        defer { server.stop() }
        var entries: [[String: Any]] = (0..<205).map { ["name": "c\($0)", "value": "\($0)", "domain": "example.com"] }
        entries[150]["name"] = "bad"
        entries.append(["name": "", "domain": "example.com"])
        let data = try JSONSerialization.data(withJSONObject: entries)

        let result = try await CookieTransfer.importCookies(data, into: server.endpoint)
        #expect(result.imported == 204)
        #expect(result.skipped == 2)
        let batches = server.commands.compactMap { $0["cookies"] as? [[String: Any]] }
        // Typed separately: Swift 6.1 cannot type-check the whole expression inside #expect in time.
        let sizes: [Int] = [100, 100] + Array(repeating: 1, count: 100) + [5]
        #expect(batches.map(\.count) == sizes)
        let first = try #require(batches.first?.first)
        #expect(first as NSDictionary == [
            "name": "c0", "value": "0", "domain": "example.com", "path": "/", "httpOnly": false, "secure": false,
        ] as NSDictionary)
    }

    @Test("An import stops when the browser goes away")
    func importStopsOnDisconnect() async throws {
        let server = try await FakeDevTools.start { _, _ in .hangUp }
        defer { server.stop() }
        let data = Data(#"[{"name": "a", "value": "1", "domain": "example.com"}]"#.utf8)
        let started = Date()
        await #expect(throws: ProfileError.self) { try await CookieTransfer.importCookies(data, into: server.endpoint) }
        // Fails as soon as the connection drops rather than after the command timeout.
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(server.methods == ["Storage.setCookies"])
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
