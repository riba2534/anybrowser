@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

@Suite("Automation API", .serialized)
@MainActor
struct AutomationTests {
    nonisolated static let token = String(repeating: "5a", count: 32)

    @Test("Settings default to disabled on port 50330 with a fresh 32-byte token")
    func defaultSettings() throws {
        let first = try AutomationConfiguration.newToken()
        let second = try AutomationConfiguration.newToken()
        #expect(first.count == 64 && first.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(first != second)

        let directory = try scratchDirectory("automation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let defaults = try store.automationConfiguration()
        #expect(!defaults.enabled)
        #expect(defaults.port == 50330)
        #expect(try defaults.validated() == defaults)
        #expect(try store.setting(AutomationConfiguration.self, forKey: "automation") == defaults)
        #expect(try ProfileStore(directory: directory).automationConfiguration() == defaults)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any])
        #expect(Set(json.keys) == ["enabled", "port", "token"])

        let changed = AutomationConfiguration(enabled: true, port: 50331, token: second)
        try store.saveAutomationConfiguration(changed)
        #expect(try ProfileStore(directory: directory).automationConfiguration() == changed)

        for invalid in [
            AutomationConfiguration(port: 80, token: second),
            AutomationConfiguration(port: 65536, token: second),
            AutomationConfiguration(token: "abc"),
            AutomationConfiguration(token: second.uppercased()),
            AutomationConfiguration(token: String(repeating: "g", count: 64)),
        ] {
            #expect(throws: ProfileError.self) { try store.saveAutomationConfiguration(invalid) }
        }
        #expect(try store.automationConfiguration() == changed)

        // Unreadable settings fall back to disabled defaults with a new token.
        try store.saveSetting(AutomationConfiguration(enabled: true, port: 50331, token: "short"), forKey: "automation")
        let replaced = try store.automationConfiguration()
        #expect(!replaced.enabled && replaced.port == 50330 && replaced.token != second)
        try store.saveSetting(["enabled": true], forKey: "automation")
        #expect(try !store.automationConfiguration().enabled)
    }

    @Test("Requests without the right Bearer token get 401")
    func requiresTheToken() async throws {
        let backend = FakeBackend()
        try await serve(backend) { port in
            let host = "Host: 127.0.0.1:\(port)"
            for headers in [
                [host],
                [host, "Authorization: Bearer \(String(repeating: "5b", count: 32))"],
                [host, "Authorization: Bearer \(Self.token.dropLast())"],
                [host, "Authorization: Bearer \(Self.token)0"],
                [host, "Authorization: Bearer \(Self.token.uppercased())"],
                [host, "Authorization: Bearer"],
                [host, "Authorization: Basic \(Self.token)"],
                [host, "Authorization: \(Self.token)"],
                [host, "Authorization: Bearer \(Self.token)", "Authorization: Bearer \(Self.token)"],
            ] {
                let reply = await request(port, "GET", "/api/v1/profiles", headers: headers)
                #expect(reply.status == 401, "\(headers)")
                #expect(reply.errorCode == "unauthorized")
                #expect(reply.headers["www-authenticate"] == "Bearer")
            }
            let accepted = await request(port, "GET", "/api/v1/profiles", headers: [host, "Authorization: bearer \(Self.token)"])
            #expect(accepted.status == 200)
        }
    }

    @Test("Requests with an Origin header get 403 even with the token")
    func rejectsOrigins() async throws {
        let backend = FakeBackend()
        let profile = backend.add("Alpha", port: 9401)
        try await serve(backend) { port in
            for origin in ["http://evil.example", "null", "http://127.0.0.1:\(port)", ""] {
                let reply = await request(port, "POST", "/api/v1/profiles/\(profile.id)/start",
                                          headers: authorized(port) + ["Origin: \(origin)"])
                #expect(reply.status == 403, "\(origin)")
                #expect(reply.errorCode == "forbidden_origin")
            }
            #expect(backend.started.isEmpty)
        }
    }

    @Test("Only 127.0.0.1 or localhost with the server's port pass the Host check")
    func checksTheHost() async throws {
        let backend = FakeBackend()
        try await serve(backend) { port in
            let auth = "Authorization: Bearer \(Self.token)"
            for hosts in [
                [String](),
                ["Host: evil.example:\(port)"],
                ["Host: evil.example"],
                ["Host: 127.0.0.1"],
                ["Host: 127.0.0.1:\(port + 1)"],
                ["Host: [::1]:\(port)"],
                ["Host: localhost.:\(port)"],
                ["Host: 127.0.0.1:\(port)", "Host: evil.example"],
            ] {
                let reply = await request(port, "GET", "/api/v1/profiles", headers: hosts + [auth])
                #expect(reply.status == 403, "\(hosts)")
                #expect(reply.errorCode == "forbidden_host")
            }
            for host in ["127.0.0.1:\(port)", "localhost:\(port)", "LocalHost:\(port)"] {
                let reply = await request(port, "GET", "/api/v1/profiles", headers: ["Host: \(host)", auth])
                #expect(reply.status == 200, "\(host)")
            }
            // Host is checked first, then Origin, then the token.
            let rebinding = await request(port, "GET", "/api/v1/profiles", headers: ["Host: evil.example", "Origin: http://evil.example"])
            #expect(rebinding.errorCode == "forbidden_host")
            let page = await request(port, "GET", "/api/v1/profiles", headers: ["Host: localhost:\(port)", "Origin: http://evil.example"])
            #expect(page.errorCode == "forbidden_origin")
        }
    }

    @Test("Requests over 64 KB get 413")
    func limitsTheRequestSize() async throws {
        let backend = FakeBackend()
        let profile = backend.add("Alpha", port: 9401)
        try await serve(backend) { port in
            let long = await request(port, "GET", "/api/v1/profiles",
                                     headers: authorized(port) + ["X-Padding: \(String(repeating: "a", count: 70_000))"])
            #expect(long.status == 413)
            #expect(long.errorCode == "payload_too_large")

            func stop(declaring declared: Int, sending sent: Int) -> Data {
                let head = "POST /api/v1/profiles/\(profile.id)/stop HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
                    + "Authorization: Bearer \(Self.token)\r\nContent-Length: \(declared)\r\n\r\n"
                return Data((head + String(repeating: "x", count: sent)).utf8)
            }
            // The declared length alone is enough to refuse; the server does not wait for the body.
            #expect(await send(port, [stop(declaring: 65_536, sending: 0)]).status == 413)
            // Exactly 64 KB in total is still accepted.
            let fits = 65_536 - stop(declaring: 10_000, sending: 0).count
            #expect(stop(declaring: fits, sending: fits).count == 65_536)
            #expect(await send(port, [stop(declaring: fits + 1, sending: fits + 1)]).status == 413)
            #expect(backend.stopped.isEmpty)
            #expect(await send(port, [stop(declaring: fits, sending: fits)]).status == 200)
            #expect(backend.stopped == [profile.id])
        }
    }

    @Test("The four endpoints answer with the documented JSON")
    func endpoints() async throws {
        let backend = FakeBackend()
        let alpha = backend.add("Alpha", port: 9401, group: "工作")
        let beta = backend.add("Beta", port: 9402)
        backend.states[beta.id] = .running(pid: 7, port: 9410, debugReady: true)
        try await serve(backend) { port in
            let list = await request(port, "GET", "/api/v1/profiles")
            #expect(list.status == 200)
            #expect(list.headers["content-type"] == "application/json; charset=utf-8")
            #expect(list.headers["connection"] == "close")
            let profiles = try #require(list.json?["profiles"] as? [[String: Any]])
            #expect(profiles.count == 2)
            #expect(Set(profiles[0].keys) == ["id", "name", "group", "port", "status", "debugReady"])
            #expect(profiles[0]["id"] as? String == alpha.id.uuidString)
            #expect(profiles[0]["name"] as? String == "Alpha")
            #expect(profiles[0]["group"] as? String == "工作")
            #expect(profiles[0]["port"] as? Int == 9401)
            #expect(profiles[0]["status"] as? String == "stopped")
            #expect(profiles[0]["debugReady"] as? Bool == false)
            // A running browser reports the port it was started with.
            #expect(profiles[1]["port"] as? Int == 9410)
            #expect(profiles[1]["status"] as? String == "running")
            #expect(profiles[1]["debugReady"] as? Bool == true)
            #expect(await request(port, "GET", "/api/v1/profiles?view=all").status == 200)

            let single = await request(port, "GET", "/api/v1/profiles/\(alpha.id.uuidString.lowercased())")
            #expect(single.status == 200)
            #expect((single.json?["profile"] as? [String: Any])?["name"] as? String == "Alpha")

            let started = await request(port, "POST", "/api/v1/profiles/\(alpha.id)/start")
            #expect(started.status == 200)
            #expect(backend.started == [alpha.id])
            let profile = try #require(started.json?["profile"] as? [String: Any])
            #expect(profile["status"] as? String == "running")
            #expect(profile["debugReady"] as? Bool == true)
            let debug = try #require(started.json?["debug"] as? [String: String])
            #expect(debug == ["http": "http://127.0.0.1:9401",
                              "webSocket": "ws://127.0.0.1:9401/devtools/browser/\(alpha.id.uuidString.lowercased())"])

            // An already running Profile is not started again.
            let again = await request(port, "POST", "/api/v1/profiles/\(beta.id)/start", body: "{}")
            #expect(again.status == 200)
            #expect(backend.started == [alpha.id])
            #expect((again.json?["debug"] as? [String: String])?["http"] == "http://127.0.0.1:9410")

            let stopped = await request(port, "POST", "/api/v1/profiles/\(beta.id)/stop")
            #expect(stopped.status == 200)
            #expect(backend.stopped == [beta.id])
            #expect((stopped.json?["profile"] as? [String: Any])?["status"] as? String == "stopped")
        }
    }

    @Test("Unknown Profiles and paths get 404, but only after authentication")
    func unknownResources() async throws {
        let backend = FakeBackend()
        let profile = backend.add("Alpha", port: 9401)
        try await serve(backend) { port in
            for (method, path) in [
                ("GET", "/api/v1/profiles/\(UUID())"),
                ("POST", "/api/v1/profiles/\(UUID())/start"),
                ("POST", "/api/v1/profiles/\(UUID())/stop"),
                ("GET", "/api/v1/profiles/not-a-uuid"),
                ("GET", "/api/v1/profiles/"),
                ("POST", "/api/v1/profiles/\(profile.id)/restart"),
                ("GET", "/api/v1/profiles/\(profile.id)/start/now"),
                ("GET", "/api/v2/profiles"),
                ("GET", "/"),
            ] {
                let reply = await request(port, method, path)
                #expect(reply.status == 404, "\(method) \(path)")
                #expect(reply.errorCode == "not_found")
            }
            let anonymous = await request(port, "GET", "/api/v2/profiles", headers: ["Host: 127.0.0.1:\(port)"])
            #expect(anonymous.status == 401)
            #expect(backend.started.isEmpty && backend.stopped.isEmpty)
        }
    }

    @Test("Wrong methods get 405 with Allow")
    func wrongMethods() async throws {
        let backend = FakeBackend()
        let profile = backend.add("Alpha", port: 9401)
        try await serve(backend) { port in
            for (method, path, allowed) in [
                ("POST", "/api/v1/profiles", "GET"),
                ("DELETE", "/api/v1/profiles/\(profile.id)", "GET"),
                ("GET", "/api/v1/profiles/\(profile.id)/start", "POST"),
                ("PUT", "/api/v1/profiles/\(profile.id)/stop", "POST"),
                ("HEAD", "/api/v1/profiles", "GET"),
            ] {
                let reply = await request(port, method, path)
                #expect(reply.status == 405, "\(method) \(path)")
                #expect(reply.headers["allow"] == allowed)
                #expect(reply.errorCode == "method_not_allowed")
            }
            #expect(backend.started.isEmpty && backend.stopped.isEmpty)
        }
    }

    @Test("Busy Profiles get 409")
    func busyProfiles() async throws {
        let backend = FakeBackend()
        let profile = backend.add("Alpha", port: 9401)
        backend.busy = [profile.id]
        try await serve(backend) { port in
            for action in ["start", "stop"] {
                let reply = await request(port, "POST", "/api/v1/profiles/\(profile.id)/\(action)")
                #expect(reply.status == 409)
                #expect(reply.errorCode == "busy")
            }
            #expect(backend.started.isEmpty && backend.stopped.isEmpty)
        }
    }

    @Test("Start and stop failures get 500 with the reason")
    func failures() async throws {
        let backend = FakeBackend()
        let profile = backend.add("Alpha", port: 9401)
        try await serve(backend) { port in
            backend.startError = ProfileError.invalid("调试端口 9401 已占用。")
            let failed = await request(port, "POST", "/api/v1/profiles/\(profile.id)/start")
            #expect(failed.status == 500)
            #expect(failed.errorCode == "start_failed")
            #expect((failed.json?["error"] as? [String: String])?["message"] == "调试端口 9401 已占用。")

            backend.startError = nil
            backend.endpointAvailable = false
            let unverified = await request(port, "POST", "/api/v1/profiles/\(profile.id)/start")
            #expect(unverified.status == 500)
            #expect(unverified.errorCode == "start_failed")

            backend.stopError = ProfileError.invalid("浏览器尚未退出。")
            let stuck = await request(port, "POST", "/api/v1/profiles/\(profile.id)/stop")
            #expect(stuck.status == 500)
            #expect(stuck.errorCode == "stop_failed")
            #expect((stuck.json?["error"] as? [String: String])?["message"] == "浏览器尚未退出。")
        }
    }

    @Test("A running Profile whose debug port is not ready is reported, never started again")
    func runningWithoutEndpoint() async throws {
        let backend = FakeBackend()
        let profile = backend.add("Alpha", port: 9402)
        backend.states[profile.id] = .running(pid: 42, port: 9402, debugReady: false)
        backend.endpointAvailable = false
        try await serve(backend) { port in
            let pending = await request(port, "POST", "/api/v1/profiles/\(profile.id)/start")
            #expect(pending.status == 503)
            #expect(pending.errorCode == "unavailable")
            #expect(backend.started.isEmpty)

            // The browser has gone away since the window last refreshed: the API starts it.
            backend.refreshedStates[profile.id] = .stopped
            backend.endpointAvailable = true
            let restarted = await request(port, "POST", "/api/v1/profiles/\(profile.id)/start")
            #expect(restarted.status == 200)
            #expect(backend.started == [profile.id])
        }
    }

    @Test("Malformed requests get 400")
    func malformedRequests() throws {
        func parse(_ text: String) -> AutomationHTTP.Parse { AutomationHTTP.parse(Data(text.utf8)) }
        let bad = AutomationHTTP.Parse.reject(AutomationHTTP.badRequest)
        for text in [
            "GET /api/v1/profiles\r\nHost: a\r\n\r\n",
            "GET  /api/v1/profiles HTTP/1.1\r\n\r\n",
            "get /api/v1/profiles HTTP/1.1\r\n\r\n",
            "GET http://127.0.0.1/api/v1/profiles HTTP/1.1\r\n\r\n",
            "GET /api/v1/profiles HTTP/2\r\n\r\n",
            "GET /api/v1/\u{7f}profiles HTTP/1.1\r\n\r\n",
            "GET / HTTP/1.1\r\nHost : a\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n",
            "GET / HTTP/1.1\r\nNo colon\r\n\r\n",
            "GET / HTTP/1.1\r\nX: a\u{1}b\r\n\r\n",
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab",
            "POST / HTTP/1.1\r\nContent-Length: +1\r\n\r\na",
            "POST / HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n",
        ] {
            #expect(parse(text) == bad, "\(text)")
        }
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\n") == .incomplete)
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: 3\r\n\r\nab") == .incomplete)
        let complete = AutomationHTTP.Request(method: "POST", target: "/x?y", headers: ["content-length": ["3"], "x-a": ["1", "2"]])
        #expect(parse("POST /x?y HTTP/1.1\r\nContent-Length: 3\r\nX-A:  1 \r\nx-a:2\r\n\r\nabc") == .request(complete))

        #expect(AutomationHTTP.constantTimeEqual(Array("abc".utf8), Array("abc".utf8)))
        #expect(!AutomationHTTP.constantTimeEqual(Array("abd".utf8), Array("abc".utf8)))
        #expect(!AutomationHTTP.constantTimeEqual(Array("ab".utf8), Array("abc".utf8)))
        #expect(!AutomationHTTP.constantTimeEqual([], []))
    }

    @Test("Requests split across packets are read whole")
    func splitRequests() async throws {
        let backend = FakeBackend()
        let profile = backend.add("Alpha", port: 9401)
        try await serve(backend) { port in
            let text = "POST /api/v1/profiles/\(profile.id)/stop HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
                + "Authorization: Bearer \(Self.token)\r\nContent-Length: 4\r\n\r\n{}{}"
            let bytes = Data(text.utf8)
            let reply = await send(port, [bytes.prefix(20), bytes.dropFirst(20).dropLast(3), bytes.suffix(3)])
            #expect(reply.status == 200)
            #expect(backend.stopped == [profile.id])
        }
    }

    @Test("A new token applies without restarting the server")
    func updatesTheToken() async throws {
        let backend = FakeBackend()
        let server = AutomationServer(port: 0, token: Self.token, backend: backend)
        let port = try await server.start()
        let replacement = try AutomationConfiguration.newToken()
        server.update(token: replacement)
        #expect(await request(port, "GET", "/api/v1/profiles").status == 401)
        let reply = await request(port, "GET", "/api/v1/profiles",
                                  headers: ["Host: 127.0.0.1:\(port)", "Authorization: Bearer \(replacement)"])
        #expect(reply.status == 200)
        await server.stop()
    }

    @Test("The server listens on 127.0.0.1 only and reports a taken port")
    func listensOnLoopbackOnly() async throws {
        let backend = FakeBackend()
        let server = AutomationServer(port: 0, token: Self.token, backend: backend)
        let port = try await server.start()
        #expect(port > 0)
        #expect(ProcessInspection.hasLoopbackDebugListener(pid: getpid(), port: port))
        #expect(await RawClient.connects(to: "127.0.0.1", port: port))
        #expect(!(await RawClient.connects(to: "::1", port: port)))
        for address in RawClient.externalIPv4Addresses() {
            #expect(!(await RawClient.connects(to: address, port: port)), "\(address)")
        }

        let rival = AutomationServer(port: port, token: Self.token, backend: backend)
        let refusal = await #expect(throws: ProfileError.self) { _ = try await rival.start() }
        #expect(refusal?.localizedDescription == "端口 \(port) 已被占用，请换一个端口。")

        await server.stop()
        #expect(!(await RawClient.connects(to: "127.0.0.1", port: port)))
        let restarted = AutomationServer(port: port, token: Self.token, backend: backend)
        #expect(try await restarted.start() == port)
        #expect(await request(port, "GET", "/api/v1/profiles").status == 200)
        await restarted.stop()
    }

    @Test(
        "Scripts start and stop a real browser through the API",
        .enabled(
            if: testAppPath != nil,
            "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test."
        )
    )
    func startsARealBrowser() async throws {
        let engine = try testEngine()
        let directory = try scratchDirectory("automation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        var profile = try store.makeDraft()
        profile.port = testPort(9305)
        profile.proxy = ""
        try store.save(profile)
        let runtime = BrowserRuntime(engine: engine, storage: store.directory)
        let backend = RuntimeBackend(store: store, runtime: runtime)
        try await serve(backend) { port in
            do {
                let started = await request(port, "POST", "/api/v1/profiles/\(profile.id)/start")
                #expect(started.status == 200)
                #expect((started.json?["profile"] as? [String: Any])?["status"] as? String == "running")
                let debug = try #require(started.json?["debug"] as? [String: String])
                #expect(debug["http"] == "http://127.0.0.1:\(profile.port)")
                let webSocket = try #require(debug["webSocket"])
                #expect(webSocket.hasPrefix("ws://127.0.0.1:\(profile.port)/devtools/browser/"))
                let version = try #require(URL(string: "http://127.0.0.1:\(profile.port)/json/version"))
                let (data, _) = try await URLSession.shared.data(from: version)
                let info = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(info["webSocketDebuggerUrl"] as? String == webSocket)
                guard case let .running(pid, _, _) = runtime.status(for: profile.id) else {
                    throw VerificationFailure.message("The browser is not running")
                }

                let again = await request(port, "POST", "/api/v1/profiles/\(profile.id)/start")
                #expect((again.json?["debug"] as? [String: String])?["webSocket"] == webSocket)
                #expect(runtime.status(for: profile.id) == .running(pid: pid, port: profile.port, debugReady: true))

                let stopped = await request(port, "POST", "/api/v1/profiles/\(profile.id)/stop")
                #expect(stopped.status == 200)
                #expect((stopped.json?["profile"] as? [String: Any])?["status"] as? String == "stopped")
                #expect(runtime.status(for: profile.id) == .stopped)
            } catch {
                try? await runtime.stop(profile.id)
                throw error
            }
        }
    }

    // MARK: Helpers

    private func serve(_ backend: AutomationBackend, _ body: (Int) async throws -> Void) async throws {
        let server = AutomationServer(port: 0, token: Self.token, backend: backend)
        let port = try await server.start()
        do {
            try await body(port)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private func authorized(_ port: Int) -> [String] {
        ["Host: 127.0.0.1:\(port)", "Authorization: Bearer \(Self.token)"]
    }

    private func request(_ port: Int, _ method: String, _ path: String, headers: [String]? = nil,
                         body: String = "") async -> RawClient.Reply {
        var head = "\(method) \(path) HTTP/1.1\r\n" + (headers ?? authorized(port)).map { $0 + "\r\n" }.joined()
        if !body.isEmpty { head += "Content-Length: \(body.utf8.count)\r\n" }
        return await send(port, [Data((head + "\r\n" + body).utf8)])
    }

    private func send(_ port: Int, _ chunks: [Data]) async -> RawClient.Reply {
        await Task.detached { RawClient.exchange(port: port, chunks: chunks) }.value
    }

}

@MainActor
private final class FakeBackend: AutomationBackend {
    var profiles: [BrowserProfile] = []
    var states: [UUID: BrowserRunState] = [:]
    var busy: Set<UUID> = []
    var startError: Error?
    var stopError: Error?
    var endpointAvailable = true
    /// What a refresh finds on the system, when it differs from `states`.
    var refreshedStates: [UUID: BrowserRunState] = [:]
    private(set) var started: [UUID] = []
    private(set) var stopped: [UUID] = []

    @discardableResult
    func add(_ name: String, port: Int, group: String = "") -> BrowserProfile {
        let profile = BrowserProfile(name: name, port: port, fingerprint: FingerprintSettings(seed: port), group: group)
        profiles.append(profile)
        return profile
    }

    func state(for id: UUID) -> BrowserRunState { states[id] ?? .stopped }

    func isBusy(_ id: UUID) -> Bool { busy.contains(id) }

    func start(_ profile: BrowserProfile) async throws {
        started.append(profile.id)
        if let startError { throw startError }
        states[profile.id] = .running(pid: 42, port: profile.port, debugReady: true)
    }

    func stop(_ id: UUID) async throws {
        stopped.append(id)
        if let stopError { throw stopError }
        states[id] = .stopped
    }

    func refresh(_ id: UUID) async {
        if let state = refreshedStates[id] { states[id] = state }
    }

    func devToolsEndpoint(for id: UUID) async -> URL? {
        guard endpointAvailable, case let .running(_, port, true) = state(for: id) else { return nil }
        return URL(string: "ws://127.0.0.1:\(port)/devtools/browser/\(id.uuidString.lowercased())")
    }
}

/// The runtime alone, without the app's Workbench.
@MainActor
private final class RuntimeBackend: AutomationBackend {
    let store: ProfileStore
    let runtime: BrowserRuntime

    init(store: ProfileStore, runtime: BrowserRuntime) {
        self.store = store
        self.runtime = runtime
    }

    var profiles: [BrowserProfile] { store.profiles }

    func state(for id: UUID) -> BrowserRunState { runtime.status(for: id) }

    func isBusy(_ id: UUID) -> Bool { [.starting, .stopping].contains(runtime.status(for: id)) }

    func start(_ profile: BrowserProfile) async throws { try await runtime.start(profile) }

    func stop(_ id: UUID) async throws { try await runtime.stop(id) }

    func devToolsEndpoint(for id: UUID) async -> URL? { await runtime.devToolsEndpoint(for: id) }

    func refresh(_ id: UUID) async { await runtime.refresh(store.profiles.filter { $0.id == id }) }
}

/// A blocking HTTP client over BSD sockets, so tests control every byte of the request.
private enum RawClient {
    struct Reply {
        var status = 0
        var headers: [String: String] = [:]
        var body = Data()

        var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
        var errorCode: String? { (json?["error"] as? [String: Any])?["code"] as? String }
    }

    static func exchange(port: Int, chunks: [Data]) -> Reply {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return Reply() }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return Reply() }
        for (index, chunk) in chunks.enumerated() {
            if index > 0 { usleep(100_000) }
            var offset = 0
            while offset < chunk.count {
                let written = chunk.withUnsafeBytes { write(fd, $0.baseAddress! + offset, chunk.count - offset) }
                if written <= 0 { break }
                offset += written
            }
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            received.append(contentsOf: buffer[0..<count])
        }
        guard let split = received.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: received[..<split.lowerBound], encoding: .utf8) else { return Reply() }
        var lines = head.components(separatedBy: "\r\n")
        let status = lines.removeFirst().split(separator: " ")
        var reply = Reply(status: status.count > 1 ? Int(status[1]) ?? 0 : 0, body: received[split.upperBound...])
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            reply.headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return reply
    }

    static func connects(to host: String, port: Int) async -> Bool {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_flags = AI_NUMERICHOST
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return false }
            defer { freeaddrinfo(result) }
            let fd = socket(info.pointee.ai_family, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            return connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
        }.value
    }

    /// IPv4 addresses of this Mac other than loopback; the API must not answer on any of them.
    /// Point-to-point tunnels are left out because VPN and proxy apps accept any connection there.
    static func externalIPv4Addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var addresses: [String] = []
        var cursor = list
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_POINTOPOINT) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(cString: host)
            if !text.hasPrefix("127.") { addresses.append(text) }
        }
        return addresses
    }
}
