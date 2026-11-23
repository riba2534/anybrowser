@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

// Several worktrees run the unit tests at the same time, so these tests take a free port per run
// instead of fixed ones; a port handed out once is never handed out again in this process.
private final class PortPool: @unchecked Sendable {
    static let shared = PortPool()
    private let lock = NSLock()
    private var used: Set<Int> = []

    func take() -> Int {
        lock.lock()
        defer { lock.unlock() }
        while true {
            let port = Int.random(in: 20_000...59_999)
            if !used.contains(port), ProcessInspection.portAvailable(port) {
                used.insert(port)
                return port
            }
        }
    }
}

func freeTestPort() -> Int { PortPool.shared.take() }

private func method(_ command: [String: Any]) -> String { command["method"] as? String ?? "" }
private func parameters(_ command: [String: Any]) -> [String: Any] { command["params"] as? [String: Any] ?? [:] }

extension BrowserRunState {
    var isUp: Bool {
        if case .running = self { return true }
        return false
    }
}

private let newTabPage = #"[{"targetId":"ntp","type":"page","url":"chrome://newtab/","title":"New Tab"}]"#

@MainActor
struct RuntimeLaunchTests {
    @Test("Start pages open over DevTools once the browser is ready, not as engine arguments")
    func startPagesOpenOverDevTools() async throws {
        let fixture = try FakeEngineFixture("runtime-pages")
        var profile = fixture.profile(port: freeTestPort())
        profile.launch.startURLs = ["https://first.example/", "https://second.example/", "https://third.example/"]
        try fixture.configure(profile, ["targets": newTabPage])
        try await fixture.run([profile]) {
            let outcome = try await fixture.runtime.start(profile)
            // The fake engine has no cookie jar, so the seeder reports each host.
            #expect(outcome.startedFresh)
            #expect(outcome.warnings.allSatisfy { $0.contains("设备 Cookie") })
            guard case let .running(pid, _, true) = fixture.runtime.status(for: profile.id) else {
                Issue.record("Not running: \(fixture.runtime.status(for: profile.id))")
                return
            }
            let arguments = try #require(ProcessInspection.arguments(pid))
            #expect(!arguments.contains { $0.contains("example") })

            let commands = fixture.commands(profile)
            // The first page reuses the new tab page; the others open behind it, in order.
            let attach = try #require(commands.first { method($0) == "Target.attachToTarget" })
            #expect(parameters(attach)["targetId"] as? String == "ntp")
            let navigation = try #require(commands.first { method($0) == "Page.navigate" })
            #expect(parameters(navigation)["url"] as? String == "https://first.example/")
            #expect(navigation["sessionId"] as? String == "fake-session")
            let created = commands.filter { method($0) == "Target.createTarget" }.map(parameters)
            #expect(created.map { $0["url"] as? String } == ["https://second.example/", "https://third.example/"])
            #expect(created.allSatisfy { $0["background"] as? Bool == true })
            #expect(!commands.contains { method($0) == "Target.closeTarget" })

            // Editing the start pages does not make the running browser outdated.
            var edited = profile
            edited.launch.startURLs = ["https://other.example/"]
            #expect(fixture.runtime.matchesRunningConfiguration(edited) == true)
            try await fixture.runtime.stop(profile.id)
            #expect(fixture.runtime.status(for: profile.id) == .stopped)
        }
    }

    @Test("Placeholder tabs from positional arguments are reused or closed")
    func placeholderTabs() async throws {
        let fixture = try FakeEngineFixture("runtime-placeholders")
        fixture.runtime.additionalArguments = ["-AppleLanguages", "(de-DE)", "(fr-FR)"]
        let placeholders = #"""
            [{"targetId":"p1","type":"page","url":"http://(de-de)/","title":"(de-de)"},
             {"targetId":"p2","type":"page","url":"chrome-error://chromewebdata/","title":"(fr-fr)"}]
            """#.replacingOccurrences(of: "\n", with: "")
        var withPages = fixture.profile(port: freeTestPort())
        withPages.launch.startURLs = ["https://first.example/"]
        let withoutPages = fixture.profile(port: freeTestPort())
        var restored = fixture.profile(port: freeTestPort())
        restored.launch.restoreSession = true
        try fixture.configure(withPages, ["targets": placeholders])
        try fixture.configure(withoutPages, ["targets": placeholders])
        try fixture.configure(restored, ["targets": placeholders.replacingOccurrences(
            of: "]", with: #",{"targetId":"old","type":"page","url":"https://restored.example/","title":"Restored"}]"#)])
        func summary(_ profile: BrowserProfile) -> [String] {
            fixture.commands(profile).compactMap { command in
                switch method(command) {
                case "Target.attachToTarget": return "attach \(parameters(command)["targetId"] as? String ?? "")"
                case "Page.navigate": return "navigate \(parameters(command)["url"] as? String ?? "")"
                case "Target.closeTarget": return "close \(parameters(command)["targetId"] as? String ?? "")"
                case "Target.createTarget": return "create \(parameters(command)["url"] as? String ?? "")"
                default: return nil
                }
            }
        }
        try await fixture.run([withPages, withoutPages, restored]) {
            for profile in [withPages, withoutPages, restored] {
                let outcome = try await fixture.runtime.start(profile)
                // The fake engine has no cookie jar, so the seeder reports each host.
                #expect(outcome.warnings.allSatisfy { $0.contains("设备 Cookie") })
            }
            #expect(summary(withPages) == ["close p2", "attach p1", "navigate https://first.example/"])
            #expect(summary(withoutPages) == ["close p2", "attach p1", "navigate chrome://newtab/"])
            // Restored tabs stay; the placeholders go.
            #expect(summary(restored) == ["close p2", "close p1"])
        }
    }

    @Test("Start pages that take longer than the budget become a warning, not a failure")
    func startPageBudget() async throws {
        let fixture = try FakeEngineFixture("runtime-budget")
        // The budget also bounds the DevTools handshake, which can take longer than half a second
        // on a loaded machine and would then report a connection failure instead. The cookie
        // seeding before the pages has its own two-second budget, so the bound below covers both.
        fixture.runtime.startPageBudget = 1
        var profile = fixture.profile(port: freeTestPort())
        profile.launch.startURLs = ["https://first.example/"]
        try fixture.configure(profile, ["targets": newTabPage, "cdp": "silent"])
        try await fixture.run([profile]) {
            let began = Date()
            let outcome = try await fixture.runtime.start(profile)
            #expect(Date().timeIntervalSince(began) < 6)
            #expect(outcome.startedFresh)
            #expect(outcome.warnings.contains { $0.contains("秒内") })
            guard case .running(_, _, true) = fixture.runtime.status(for: profile.id) else {
                Issue.record("Not running: \(fixture.runtime.status(for: profile.id))")
                return
            }
        }
    }

    @Test("Launch overrides add headless and extra switches last and replace the start pages")
    func overrides() async throws {
        let fixture = try FakeEngineFixture("runtime-overrides")
        var profile = fixture.profile(port: freeTestPort())
        profile.launch.startURLs = ["https://saved.example/"]
        try fixture.configure(profile, ["targets": newTabPage])
        try await fixture.run([profile]) {
            let overrides = LaunchOverrides(headless: true, urls: ["https://Override.example"], arguments: ["--lang=fr", "--mute-audio"])
            try await fixture.runtime.start(profile, overrides: overrides)
            guard case let .running(pid, _, true) = fixture.runtime.status(for: profile.id) else {
                Issue.record("Not running: \(fixture.runtime.status(for: profile.id))")
                return
            }
            let arguments = try #require(ProcessInspection.arguments(pid))
            #expect(Array(arguments.suffix(3)) == ["--headless=new", "--lang=fr", "--mute-audio"])
            let navigation = fixture.commands(profile).first { method($0) == "Page.navigate" }
            #expect(navigation.map(parameters)?["url"] as? String == "https://override.example/")
            // The saved configuration did not change, but this browser does not run it.
            #expect(fixture.runtime.matchesRunningConfiguration(profile) == false)
        }
    }

    @Test("Switches that change which process is the Profile's browser are refused before launching")
    func refusedOverrides() async throws {
        let fixture = try FakeEngineFixture("runtime-refused")
        let profile = fixture.profile(port: freeTestPort())
        try await fixture.run([profile]) {
            for argument in ["--user-data-dir=/tmp/other", "--remote-debugging-port=9", "--remote-debugging-pipe",
                             "--remote-debugging-address=0.0.0.0", "-user-data-dir=/tmp/other", "https://example.com/",
                             "(de-DE)", "--", "--=x", "--lang=fr\nhttps://example.com/"] {
                await #expect(throws: ProfileError.self, "\(argument)") {
                    try await fixture.runtime.start(profile, overrides: LaunchOverrides(arguments: [argument]))
                }
            }
            await #expect(throws: ProfileError.self) {
                try await fixture.runtime.start(profile, overrides: LaunchOverrides(urls: ["javascript:alert(1)"]))
            }
            #expect(fixture.runtime.status(for: profile.id) == .stopped)
            #expect(fixture.lockHolder(profile) == nil)
        }
    }

    @Test("resetSiteData clears site data and the cache directory before the browser starts")
    func resetSiteDataBeforeLaunch() async throws {
        let fixture = try FakeEngineFixture("runtime-reset")
        let profile = fixture.profile(port: freeTestPort())
        let data = fixture.runtime.dataDirectory(for: profile.id)
        let cache = fixture.runtime.cacheDirectory(for: profile.id)
        #expect(cache.path.hasPrefix(fixture.caches.path + "/"))
        let cookies = data.appendingPathComponent("Default/Network/Cookies")
        let localStorage = data.appendingPathComponent("Default/Local Storage/leveldb/CURRENT")
        let preferences = data.appendingPathComponent("Default/Preferences")
        let cached = cache.appendingPathComponent("Default/Cache/Cache_Data/index")
        // The fake engine writes the cookie file as it starts: it survives only if the reset came first.
        try fixture.configure(profile, ["touch": "Default/Network/Cookies", "touch_text": "new"])
        for file in [cookies, localStorage, preferences, cached] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data("old".utf8).write(to: file)
        }
        try await fixture.run([profile]) {
            try await fixture.runtime.start(profile, overrides: LaunchOverrides(resetSiteData: true))
            let cookieText = try String(contentsOf: cookies, encoding: .utf8)
            #expect(cookieText == "new")
            #expect(!FileManager.default.fileExists(atPath: localStorage.path))
            #expect(!FileManager.default.fileExists(atPath: cache.path))
            #expect(FileManager.default.fileExists(atPath: preferences.path))

            // A running browser keeps its data, and the launch says why it did not reset.
            let written = data.appendingPathComponent("Default/Local Storage/written-while-running")
            try FileManager.default.createDirectory(at: written.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("new".utf8).write(to: written)
            let error = await #expect(throws: (any Error).self) {
                try await fixture.runtime.start(profile, overrides: LaunchOverrides(resetSiteData: true))
            }
            #expect(error?.localizedDescription.contains("正在运行") == true)
            #expect(fixture.runtime.status(for: profile.id).isUp)
            #expect(FileManager.default.fileExists(atPath: written.path))
        }
    }
}

@MainActor
struct RuntimeFailureTests {
    @Test("A browser that exits before it is ready reports its exit code and last output")
    func earlyExit() async throws {
        let fixture = try FakeEngineFixture("runtime-exit")
        let profile = fixture.profile(port: freeTestPort())
        try fixture.configure(profile, ["output": "fake-engine: the profile is broken", "exit_ms": "100",
                                        "exit_code": "7", "ready_ms": "5000"])
        try await fixture.run([profile]) {
            #expect(fixture.runtime.launchLog(for: profile.id) == nil)
            let error = await #expect(throws: (any Error).self) { try await fixture.runtime.start(profile) }
            let message = error?.localizedDescription ?? ""
            let lines = message.split(separator: "\n")
            #expect(lines.first == "Chromium 在调试端口就绪前退出（退出码 7）。")
            #expect(lines.contains("fake-engine: the profile is broken"))
            guard case .failed(let shown) = fixture.runtime.status(for: profile.id) else {
                Issue.record("Not failed: \(fixture.runtime.status(for: profile.id))")
                return
            }
            #expect(shown == message)
            #expect(await fixture.eventually {
                fixture.runtime.launchLog(for: profile.id)?.contains("[AnyBrowser] Chromium 已退出（退出码 7）") == true
            })
            #expect(fixture.runtime.launchLog(for: profile.id)?.contains("fake-engine: exiting with 7") == true)
        }
    }

    @Test("A browser killed by a signal before it is ready names the signal")
    func signalExit() async throws {
        let fixture = try FakeEngineFixture("runtime-signal")
        let profile = fixture.profile(port: freeTestPort())
        try fixture.configure(profile, ["kill_ms": "100", "kill_signal": "9", "ready_ms": "5000"])
        try await fixture.run([profile]) {
            let error = await #expect(throws: (any Error).self) { try await fixture.runtime.start(profile) }
            #expect(error?.localizedDescription.contains("SIGKILL") == true)
        }
    }

    @Test("Output is read as it comes, so a chatty browser never blocks, and only the last 64 KB is kept")
    func boundedLog() async throws {
        let fixture = try FakeEngineFixture("runtime-log")
        let profile = fixture.profile(port: freeTestPort())
        try fixture.configure(profile, ["spam_kb": "512"])
        try await fixture.run([profile]) {
            try await fixture.runtime.start(profile)
            #expect(fixture.runtime.status(for: profile.id).isUp)
            #expect(await fixture.eventually {
                fixture.runtime.launchLog(for: profile.id)?.contains("fake-engine: noise done") == true
            })
            let log = try #require(fixture.runtime.launchLog(for: profile.id))
            #expect(log.utf8.count <= LaunchLog.capacity)
            #expect(log.utf8.count > LaunchLog.capacity / 2)
        }
    }

    @Test("A browser that never becomes ready and ignores SIGTERM is killed")
    func readinessTimeout() async throws {
        let fixture = try FakeEngineFixture("runtime-timeout")
        fixture.runtime.readinessTimeout = 1
        let profile = fixture.profile(port: freeTestPort())
        try fixture.configure(profile, ["ready_ms": "60000", "ignore_term": "1"])
        try await fixture.run([profile]) {
            let error = await #expect(throws: (any Error).self) { try await fixture.runtime.start(profile) }
            #expect(error?.localizedDescription.contains("未能在本机端口 \(profile.port) 启用调试") == true)
            let lock = fixture.runtime.dataDirectory(for: profile.id).appendingPathComponent("SingletonLock").path
            let pid = try #require(Int32(try FileManager.default.destinationOfSymbolicLink(atPath: lock)
                .split(separator: "-").last ?? ""))
            #expect(!isAlive(pid))
            guard case .failed = fixture.runtime.status(for: profile.id) else {
                Issue.record("Not failed: \(fixture.runtime.status(for: profile.id))")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.runtime.receiptURL(
                fixture.runtime.dataDirectory(for: profile.id)).path))
        }
    }

    @Test("A browser that ignores a normal stop can be force-stopped")
    func forceStop() async throws {
        let fixture = try FakeEngineFixture("runtime-force")
        let profile = fixture.profile(port: freeTestPort())
        let other = fixture.profile(port: freeTestPort())
        try fixture.configure(profile, ["ignore_term": "1"])
        try fixture.configure(other, [:])
        try await fixture.run([profile, other]) {
            try await fixture.runtime.start(profile)
            guard case let .running(pid, _, _) = fixture.runtime.status(for: profile.id) else {
                Issue.record("Not running: \(fixture.runtime.status(for: profile.id))")
                return
            }
            let error = await #expect(throws: (any Error).self) { try await fixture.runtime.stop(profile.id) }
            #expect(error?.localizedDescription.contains("尚未退出") == true)
            #expect(fixture.runtime.status(for: profile.id).isUp)
            #expect(isAlive(pid))

            try await fixture.runtime.stop(profile.id, force: true)
            #expect(fixture.runtime.status(for: profile.id) == .stopped)
            #expect(!isAlive(pid))
            let receipt = fixture.runtime.receiptURL(fixture.runtime.dataDirectory(for: profile.id))
            #expect(!FileManager.default.fileExists(atPath: receipt.path))

            // Forcing works right away too.
            try await fixture.runtime.start(other)
            guard case let .running(otherPID, _, _) = fixture.runtime.status(for: other.id) else {
                Issue.record("Not running: \(fixture.runtime.status(for: other.id))")
                return
            }
            try await fixture.runtime.stop(other.id, force: true)
            #expect(!isAlive(otherPID))
            #expect(fixture.runtime.status(for: other.id) == .stopped)
            // The Profile starts again right after.
            try await fixture.runtime.start(other)
            #expect(fixture.runtime.status(for: other.id).isUp)
        }
    }
}

@MainActor
struct RuntimeAdoptionTests {
    @Test("A new runtime adopts a running browser and notices when it exits")
    func adoptsAndWatches() async throws {
        let fixture = try FakeEngineFixture("runtime-adopt")
        let profile = fixture.profile(port: freeTestPort())
        let started = fixture.profile(port: freeTestPort())
        try fixture.configure(profile, [:])
        try fixture.configure(started, [:])
        let restarted = fixture.makeRuntime()
        try await fixture.run([profile, started], runtimes: [restarted]) {
            try await fixture.runtime.start(profile)
            try await fixture.runtime.start(started)
            // One is found by a refresh, the other by starting it again.
            await restarted.refresh([profile])
            #expect(restarted.status(for: profile.id) == fixture.runtime.status(for: profile.id))
            let adopted = try await restarted.start(started)
            #expect(adopted.startedFresh == false)
            for item in [profile, started] {
                guard case let .running(pid, _, true) = restarted.status(for: item.id) else {
                    Issue.record("Not adopted: \(restarted.status(for: item.id))")
                    return
                }
                // The adopted browser is not its child: an exit source reports it without a refresh.
                kill(pid, SIGKILL)
                #expect(await fixture.eventually(3) { restarted.status(for: item.id) == .stopped })
            }
        }
    }

    @Test("A browser whose receipt is gone is adopted through SingletonLock")
    func adoptsLockHolder() async throws {
        let fixture = try FakeEngineFixture("runtime-lock")
        let profile = fixture.profile(port: freeTestPort())
        // The session brought back an -AppleLanguages placeholder next to a real tab.
        try fixture.configure(profile, ["targets": #"[{"targetId":"p1","type":"page","url":"http://(de-de)/","title":"(de-de)"},"#
                                            + #"{"targetId":"tab","type":"page","url":"https://kept.example/","title":"Kept"}]"#])
        let restarted = fixture.makeRuntime()
        func closed() -> [String] {
            fixture.commands(profile).filter { method($0) == "Target.closeTarget" }
                .compactMap { parameters($0)["targetId"] as? String }
        }
        try await fixture.run([profile], runtimes: [restarted]) {
            try await fixture.runtime.start(profile)
            let status = fixture.runtime.status(for: profile.id)
            let receipt = fixture.runtime.receiptURL(fixture.runtime.dataDirectory(for: profile.id))
            try FileManager.default.removeItem(at: receipt)

            #expect(fixture.commands(profile).isEmpty)
            await restarted.refresh([profile])
            #expect(restarted.status(for: profile.id) == status)
            #expect(FileManager.default.fileExists(atPath: receipt.path))
            // Only the placeholder goes; nothing is opened in a browser the user restarted.
            #expect(closed() == ["p1"])
            #expect(!fixture.commands(profile).contains { ["Page.navigate", "Target.createTarget"].contains(method($0)) })
            try FileManager.default.removeItem(at: receipt)
            // Starting it adopts it the same way.
            let fresh = fixture.makeRuntime()
            let adopted = try await fresh.start(profile)
            #expect(adopted == LaunchOutcome(startedFresh: false))
            #expect(fresh.status(for: profile.id) == status)
            #expect(closed() == ["p1", "p1"])
            try await fresh.stop(profile.id)
            #expect(fresh.status(for: profile.id) == .stopped)
        }
    }

    @Test("A browser that relaunched itself with a new pid is still the Profile's")
    func followsRelaunch() async throws {
        let fixture = try FakeEngineFixture("runtime-relaunch")
        let profile = fixture.profile(port: freeTestPort())
        let refreshed = fixture.profile(port: freeTestPort())
        // Both launches must finish before either browser relaunches, also on a busy machine.
        try fixture.configure(profile, ["relaunch_ms": "4000"])
        try fixture.configure(refreshed, ["relaunch_ms": "4000"])
        try await fixture.run([profile, refreshed]) {
            var first: [UUID: Int32] = [:]
            for item in [profile, refreshed] {
                try await fixture.runtime.start(item)
                guard case let .running(pid, _, _) = fixture.runtime.status(for: item.id) else {
                    Issue.record("Not running: \(fixture.runtime.status(for: item.id))")
                    return
                }
                first[item.id] = pid
            }
            for item in [profile, refreshed] {
                #expect(await fixture.eventually(10) { fixture.runtime.status(for: item.id) == .stopped })
                #expect(await fixture.eventually(10) { fixture.lockHolder(item).map { $0 != first[item.id] } == true })
            }
            // Stopping finds the new process through the old receipt's port, without a refresh.
            let relaunched = try #require(fixture.lockHolder(profile))
            #expect(await fixture.eventually { ProcessInspection.arguments(relaunched) != nil })
            try await fixture.runtime.stop(profile.id)
            #expect(await fixture.eventually { !isAlive(relaunched) })

            // A refresh shows it running again.
            let other = try #require(fixture.lockHolder(refreshed))
            #expect(await fixture.eventually {
                await fixture.runtime.refresh([refreshed])
                return fixture.runtime.status(for: refreshed.id) == .running(pid: other, port: refreshed.port, debugReady: true)
            })
        }
    }

    @Test("SingletonLock is only followed to this engine on this directory and port")
    func refusesForeignLockHolder() async throws {
        let fixture = try FakeEngineFixture("runtime-foreign")
        let profile = fixture.profile(port: freeTestPort())
        let directory = fixture.runtime.dataDirectory(for: profile.id)
        try fixture.configure(profile, [:])
        // Same arguments, different program.
        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = ["-c", "sleep 30", "anybrowser-test", "--user-data-dir=\(directory.path)",
                          "--remote-debugging-port=\(profile.port)"]
        try bash.run()
        defer { bash.terminate() }
        let lock = directory.appendingPathComponent("SingletonLock").path
        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: "host-\(bash.processIdentifier)")
        try await fixture.run([profile]) {
            await fixture.runtime.refresh([profile])
            #expect(fixture.runtime.status(for: profile.id) == .stopped)
            await #expect(throws: (any Error).self) { try await fixture.runtime.start(profile) }
            bash.terminate()
            bash.waitUntilExit()

            // The right program on another port.
            try FileManager.default.removeItem(atPath: lock)
            let stray = Process()
            stray.executableURL = try FakeEngine.executable()
            stray.arguments = ["--user-data-dir=\(directory.path)", "--remote-debugging-port=\(freeTestPort())"]
            stray.standardError = FileHandle.nullDevice
            try stray.run()
            defer { stray.terminate() }
            #expect(await fixture.eventually { fixture.lockHolder(profile) == stray.processIdentifier })
            await fixture.runtime.refresh([profile])
            #expect(!fixture.runtime.status(for: profile.id).isUp)
            let error = await #expect(throws: (any Error).self) { try await fixture.runtime.start(profile) }
            #expect(error?.localizedDescription.contains("正在使用") == true)
            #expect(!FileManager.default.fileExists(atPath: fixture.runtime.receiptURL(directory).path))
        }
    }

    @Test("A port someone else listens on is named in the error")
    func portConflictNamesHolder() async throws {
        let fixture = try FakeEngineFixture("runtime-port")
        let profile = fixture.profile(port: freeTestPort())
        try fixture.configure(profile, [:])
        let socket = try listen(on: "0.0.0.0", port: profile.port)
        defer { close(socket) }
        try await fixture.run([profile]) {
            let error = await #expect(throws: (any Error).self) { try await fixture.runtime.start(profile) }
            let message = error?.localizedDescription ?? ""
            #expect(message.contains("调试端口 \(profile.port) 已被「\(ProcessInspection.name(getpid()))」（PID \(getpid())）占用"))
        }
    }

    @Test("Activating needs this Profile's running browser")
    func activateNeedsOwnBrowser() async throws {
        let fixture = try FakeEngineFixture("runtime-activate")
        let profile = fixture.profile(port: freeTestPort())
        try fixture.configure(profile, [:])
        try await fixture.run([profile]) {
            #expect(fixture.runtime.activate(profile.id) == false)
            try await fixture.runtime.start(profile)
            // The fake engine is not an app macOS could bring forward.
            #expect(fixture.runtime.activate(profile.id) == false)
        }
    }
}

// MARK: Pure functions

struct RuntimeArgumentTests {
    @Test("Launch arguments name the window and leave the start pages out")
    func launchArguments() throws {
        var profile = BrowserProfile(name: "Shop · 2", port: 9300, fingerprint: FingerprintSettings(seed: 9300), proxy: "")
        profile.launch = LaunchOptions(startURLs: ["https://example.com/"], window: WindowLayout(width: 800, height: 600))
        let directory = URL(fileURLWithPath: "/tmp/anybrowser-profile", isDirectory: true)
        let arguments = profile.launchArguments(userDataDirectory: directory)
        #expect(arguments.contains("--window-name=Shop · 2"))
        #expect(!arguments.contains("https://example.com/"))
        #expect(!arguments.contains("--restore-last-session"))
        #expect(arguments.last == "--window-size=800,600")
        profile.launch.restoreSession = true
        #expect(profile.launchArguments(userDataDirectory: directory).last == "--restore-last-session")
    }

    @Test("Only placeholder-shaped positional arguments and their tabs count as placeholders")
    func placeholders() {
        #expect(BrowserRuntime.placeholderCount(["--lang=de", "-AppleLanguages", "(de-DE)", "(x)", "de-DE", "-(y)"]) == 2)
        func target(_ url: String, _ title: String = "") -> [String: Any] { ["url": url, "title": title] }
        #expect(BrowserRuntime.isPlaceholder(target("http://(de-de)/")))
        #expect(BrowserRuntime.isPlaceholder(target("https://(pt-br)")))
        #expect(BrowserRuntime.isPlaceholder(target("chrome-error://chromewebdata/", "(de-de)")))
        #expect(!BrowserRuntime.isPlaceholder(target("chrome-error://chromewebdata/", "example.com")))
        #expect(!BrowserRuntime.isPlaceholder(target("http://(de-de)/path")))
        #expect(!BrowserRuntime.isPlaceholder(target("chrome://newtab/")))
        // Every URL the new tab page shows up at is reused for the first start page.
        for url in ["chrome://newtab/", "chrome://new-tab-page/", "chrome://new-tab-page-third-party/"] {
            #expect(BrowserRuntime.isNewTabPage(target(url)))
        }
        #expect(!BrowserRuntime.isNewTabPage(target("https://example.com/")))
    }

    @Test("Running cookie cleanup matches a site's own, parent-domain and subdomain cookies")
    func cookieMatching() {
        let hosts = ["m.stripe.com", "link.com", "127.0.0.1"]
        func matches(_ name: String, _ domain: String, names: Set<String> = []) -> Bool {
            BrowserRuntime.cookie(["name": name, "domain": domain], matches: hosts, names: names)
        }
        #expect(matches("m", ".m.stripe.com"))
        #expect(matches("m", "m.stripe.com"))
        #expect(matches("dom", ".stripe.com"))
        #expect(matches("mid", ".app.link.com"))
        #expect(matches("site", "127.0.0.1"))
        #expect(!matches("keep", ".example.com"))
        #expect(!matches("keep", "js.stripe.com"))
        #expect(!matches("keep", ".notlink.com"))
        #expect(matches("__stripe_mid", ".shop.example", names: ["__stripe_mid"]))
    }

    @Test("Info.plist explains every permission a website in a Profile can request")
    func usageDescriptions() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let values = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
            as? [String: Any])
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSLocationUsageDescription",
                    "NSLocationWhenInUseUsageDescription", "NSBluetoothAlwaysUsageDescription",
                    "NSLocalNetworkUsageDescription", "NSAudioCaptureUsageDescription"] {
            #expect((values[key] as? String)?.contains("Profile") == true, "\(key)")
        }
    }
}

// MARK: Ports

/// A socket listening on `address`, an IPv4 or IPv6 literal.
func listen(on address: String, port: Int) throws -> Int32 {
    let ipv6 = address.contains(":")
    let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var result: Int32
    if ipv6 {
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        var value = sockaddr_in6()
        value.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        value.sin6_family = sa_family_t(AF_INET6)
        value.sin6_port = UInt16(port).bigEndian
        inet_pton(AF_INET6, address, &value.sin6_addr)
        result = withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    } else {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, address, &value.sin_addr)
        result = withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
    guard result == 0, Darwin.listen(fd, 4) == 0 else {
        close(fd)
        throw VerificationFailure.message("Cannot listen on \(address):\(port): \(String(cString: strerror(errno)))")
    }
    return fd
}

struct PortProbeTests {
    @Test("A port is taken by a listener on any loopback or wildcard address",
          arguments: ["127.0.0.1", "0.0.0.0", "::1", "::"])
    func listenerTakesPort(address: String) async throws {
        let port = freeTestPort()
        #expect(ProcessInspection.portAvailable(port))
        let fd = try listen(on: address, port: port)
        #expect(!ProcessInspection.portAvailable(port))
        #expect(ProcessInspection.listener(onPort: port)?.pid == getpid())
        close(fd)
        // A parallel test inspecting this process's sockets can hold the closed one for a moment.
        var available = false
        for _ in 0..<100 where !available {
            available = ProcessInspection.portAvailable(port)
            if !available { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        #expect(available)
    }

    @Test("Connections left in TIME_WAIT do not block the port")
    func timeWaitLeavesPortFree() async throws {
        let port = freeTestPort()
        let server = try listen(on: "127.0.0.1", port: port)
        let client = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(connected == 0)
        let accepted = accept(server, nil, nil)
        try #require(accepted >= 0)
        // The side that closes first keeps the port in TIME_WAIT, as a browser that quit does.
        close(accepted)
        try await Task.sleep(nanoseconds: 50_000_000)
        close(client)
        close(server)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ProcessInspection.portAvailable(port))
    }
}
