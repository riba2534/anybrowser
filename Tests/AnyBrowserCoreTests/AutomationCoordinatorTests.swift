@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

// The automation API answered by a real LaunchCoordinator on the fake engine, which listens on
// ports 11800–11809 here (plus ANYBROWSER_TEST_PORT_OFFSET).

@Suite("Automation API on the coordinator", .serialized)
@MainActor
struct AutomationCoordinatorTests {
    private func profileID(_ reply: RawClient.Reply) -> UUID? {
        ((reply.json?["profile"] as? [String: Any])?["id"] as? String).flatMap { UUID(uuidString: $0) }
    }

    private func pendingRestart(_ port: Int, _ id: UUID) async -> Bool? {
        let list = await automationRequest(port, "GET", "/api/v1/profiles")
        return (list.json?["profiles"] as? [[String: Any]])?.first { $0["id"] as? String == id.uuidString }?["pendingRestart"] as? Bool
    }

    @Test("A Profile created over the API starts with one-off options, restarts, stops, and goes to the recycle bin and back")
    func lifecycle() async throws {
        let fixture = try CoordinatorFixture("api-lifecycle")
        fixture.coordinator.exitLookup = { _ in ProxyExit(ip: "203.0.113.9", countryCode: "JP", timeZone: "Asia/Tokyo", languages: ["ja-JP"]) }
        var created: [BrowserProfile] = []
        do {
            try await serveAutomation(fixture.coordinator) { port in
                let reply = await automationRequest(port, "POST", "/api/v1/profiles", json: [
                    "name": "API", "port": testPort(11800), "proxy": "127.0.0.1:9", "fingerprint": ["platform": "macos"],
                ])
                #expect(reply.status == 201, "\(reply.errorMessage ?? "")")
                let id = try #require(profileID(reply))
                let profile = try #require(fixture.store.profiles.first { $0.id == id })
                created.append(profile)
                // The exit lookup is the coordinator's, as for "整套重新生成".
                #expect(profile.fingerprint.timeZone == "Asia/Tokyo" && profile.fingerprint.language == "ja-JP")
                #expect(fixture.coordinator.lastExit(for: id)?.exit.ip == "203.0.113.9")
                // The fake engine needs no proxy to run.
                #expect(await automationRequest(port, "PATCH", "/api/v1/profiles/\(id)", json: ["proxy": ""]).status == 200)

                let path = "/api/v1/profiles/\(id)"
                let started = await automationRequest(port, "POST", path + "/start", json: [
                    "headless": true, "args": ["--mute-audio"], "urls": [],
                ])
                #expect(started.status == 200, "\(started.errorMessage ?? "")")
                let pid = try #require(fixture.pid(profile))
                let arguments = ProcessInspection.arguments(pid) ?? []
                #expect(arguments.contains("--headless=new") && arguments.contains("--mute-audio"))
                #expect((started.json?["debug"] as? [String: String])?["http"] == "http://127.0.0.1:\(testPort(11800))")
                // One-off options are not a configuration change.
                #expect(await pendingRestart(port, id) == false)

                let patched = await automationRequest(port, "PATCH", path, json: ["fingerprint": ["timeZone": "Europe/Paris"]])
                #expect(patched.json?["pendingRestart"] as? Bool == true)
                #expect(await pendingRestart(port, id) == true)

                let restarted = await automationRequest(port, "POST", path + "/restart")
                #expect(restarted.status == 200, "\(restarted.errorMessage ?? "")")
                let second = try #require(fixture.pid(profile))
                #expect(second != pid && !isAlive(pid))
                #expect(!(ProcessInspection.arguments(second) ?? []).contains("--headless=new"))
                #expect(await pendingRestart(port, id) == false)

                #expect(await automationRequest(port, "DELETE", path).errorCode == "running")
                #expect(await automationRequest(port, "POST", path + "/stop?force=1").status == 200)
                #expect(fixture.runtime.status(for: id) == .stopped && !isAlive(second))
                #expect(await automationRequest(port, "GET", path + "/log").json?["log"] is String)

                #expect(await automationRequest(port, "DELETE", path).json?["result"] as? String == "trashed")
                #expect(fixture.store.trashed.map(\.id) == [id])
                #expect(await automationRequest(port, "POST", path + "/restore").status == 200)
                #expect(fixture.store.profiles.map(\.id) == [id])

                let data = fixture.runtime.dataDirectory(for: id)
                #expect(fixture.exists(data))
                let purged = await automationRequest(port, "DELETE", path + "?purge=1&deleteData=1")
                #expect(purged.status == 200 && purged.json?["warnings"] as? [String] == [])
                #expect(fixture.store.profiles.isEmpty && fixture.store.trashed.isEmpty)
                #expect(!fixture.exists(data))
            }
        } catch {
            await fixture.fake.cleanUp(created)
            throw error
        }
        await fixture.fake.cleanUp(created)
    }

    @Test("A cookie transfer on a stopped Profile stops the browser it started, even when the transfer fails")
    func temporaryBrowser() async throws {
        let fixture = try CoordinatorFixture("api-cookies")
        let profile = try fixture.add(11801)
        try await fixture.run([profile]) {
            try await serveAutomation(fixture.coordinator) { port in
                // The fake engine answers Storage.getCookies with an empty result, which is no cookie list.
                let reply = await automationRequest(port, "GET", "/api/v1/profiles/\(profile.id)/cookies")
                #expect(reply.status == 500 && reply.errorCode == "cookies_failed")
                #expect(fixture.fake.commands(profile).contains { $0["method"] as? String == "Storage.getCookies" })
                #expect(fixture.runtime.status(for: profile.id) == .stopped)
                #expect(fixture.fake.lockHolder(profile) == nil)
                #expect(!fixture.coordinator.isBusy(profile.id))
            }
        }
    }

    @Test("Proxy checks and window tiling go through the coordinator")
    func checksAndTiles() async throws {
        let fixture = try CoordinatorFixture("api-tools")
        let stopped = try fixture.add(11802)
        let running = try fixture.add(11803)
        // Nothing listens on port 9, so every lookup service fails at once.
        let entry = try #require(try fixture.coordinator.proxyLibrary.add(["127.0.0.1:9"]).first)
        try await fixture.run([stopped, running]) {
            try await fixture.coordinator.start(running.id)
            try await serveAutomation(fixture.coordinator) { port in
                let checked = await automationRequest(port, "POST", "/api/v1/proxies/check")
                #expect(checked.status == 200)
                let result = try #require((checked.json?["results"] as? [[String: Any]])?.first)
                #expect((result["error"] as? String)?.hasPrefix("无法查询出口 IP") == true)
                #expect(fixture.coordinator.proxyLibrary.entries.first { $0.id == entry.id }?.lastCheckedAt != nil)

                let tiled = await automationRequest(port, "POST", "/api/v1/windows/arrange",
                                                    json: ["ids": [stopped.id.uuidString, running.id.uuidString]])
                #expect(tiled.status == 200, "\(tiled.errorMessage ?? "")")
                let windows = try #require(tiled.json?["windows"] as? [[String: Any]])
                try #require(windows.map { $0["id"] as? String } == [stopped.id.uuidString, running.id.uuidString])
                #expect(windows[0]["error"] as? String == "浏览器没有运行，或调试端口尚未就绪。")
                // The fake engine has no page targets, so no window to move.
                #expect(windows[1]["error"] as? String == "浏览器没有打开的窗口。")
                #expect(windows[1]["frame"] is [String: Any])
            }
        }
    }
}
