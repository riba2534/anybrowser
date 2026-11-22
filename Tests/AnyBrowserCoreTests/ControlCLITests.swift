@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

/// The anybrowserctl executable, built next to the test bundle.
private let controlPath = builtProduct("anybrowserctl")

/// One run of anybrowserctl.
private struct ControlRun: Sendable {
    var status: Int32 = -1
    var output = ""
    var errors = ""

    var json: [String: Any]? { try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] }

    /// Runs off the main actor, which has to stay free to answer the API.
    static func run(_ arguments: [String], environment: [String: String], input: Data? = nil) async -> ControlRun {
        guard let path = controlPath else { return ControlRun(errors: "anybrowserctl is not built") }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = environment
            let output = Pipe()
            let errors = Pipe()
            let stdin = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin
            do {
                try process.run()
            } catch {
                return ControlRun(errors: "\(error)")
            }
            if let input {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            let reported = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ControlRun(status: process.terminationStatus, output: String(decoding: printed, as: UTF8.self),
                              errors: String(decoding: reported, as: UTF8.self))
        }.value
    }
}

@Suite("anybrowserctl", .serialized,
       .enabled(if: controlPath != nil, "Build the anybrowserctl product (swift build) to run the CLI tests."))
@MainActor
struct ControlCLITests {
    /// A home and a data directory of its own, so the CLI never reads the user's AnyBrowser data.
    private struct Sandbox {
        let root: URL
        var data: URL { root.appendingPathComponent("data", isDirectory: true) }

        init() throws {
            root = try scratchDirectory("anybrowserctl")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        }

        func environment(_ extra: [String: String] = [:]) -> [String: String] {
            ["HOME": root.appendingPathComponent("home").path, "ANYBROWSER_DATA_DIR": data.path].merging(extra) { $1 }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("Every command reaches its endpoint, and answers come back as JSON")
    func commands() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let backend = try FakeBackend()
        let alpha = try backend.add("Alpha", port: 9401) {
            $0.tags = ["shop"]
            $0.proxy = "http://user:s3cret@proxy.example:8080"
        }
        let beta = try backend.add("Beta", port: 9402)
        backend.logs[alpha.id] = "launch output"
        let devTools = try await FakeDevTools.start { method, _ in
            switch method {
            case "Storage.getCookies":
                return .result(["cookies": [["name": "sid", "value": "abc", "domain": ".example.com", "path": "/",
                                             "expires": 1_900_000_000, "httpOnly": true, "secure": true, "session": false]]])
            case "Storage.setCookies": return .result([:])
            default: return .error(-32601, "not found")
            }
        }
        defer { devTools.stop() }
        backend.endpoints[alpha.id] = devTools.endpoint
        try await serveAutomation(backend) { port in
            let environment = sandbox.environment(["ANYBROWSER_TOKEN": automationTestToken, "ANYBROWSER_PORT": String(port)])
            func ctl(_ arguments: String..., input: Data? = nil) async -> ControlRun {
                await ControlRun.run(arguments, environment: environment, input: input)
            }
            func names(_ run: ControlRun) -> [String] {
                (run.json?["profiles"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            }

            let list = await ctl("list")
            #expect(list.status == 0, "\(list.errors)")
            #expect(names(list) == ["Alpha", "Beta"])
            #expect(names(await ctl("list", "--tag", "shop", "--status", "stopped")) == ["Alpha"])
            #expect(names(await ctl("list", "--query", "Bet")) == ["Beta"])
            let pretty = await ctl("--pretty", "list")
            #expect(pretty.output.contains("\n  \"profiles\" : [\n"))

            let shown = await ctl("show", "Alpha", "--secrets")
            #expect((shown.json?["config"] as? [String: Any])?["proxy"] as? String == "http://user:s3cret@proxy.example:8080")
            #expect(((await ctl("show", alpha.id.uuidString)).json?["config"] as? [String: Any])?["proxy"] as? String
                == "http://proxy.example:8080")

            let added = await ctl("proxies", "add", "--label", "批次", "one.example:1", "two.example:2:u:p")
            #expect(added.status == 0, "\(added.errors)")
            #expect((added.json?["added"] as? [[String: Any]])?.count == 2)
            let fromFile = sandbox.root.appendingPathComponent("proxies.txt")
            try Data("three.example:3\nnot a proxy\n".utf8).write(to: fromFile)
            #expect((await ctl("proxies", "add", "--file", fromFile.path)).json?["rejected"] as? [String] == ["not a proxy"])
            #expect((await ctl("proxies", "add", "-", input: Data("four.example:4\n".utf8))).json?["added"] is [Any])
            let proxies = await ctl("proxies", "list", "--secrets")
            #expect((proxies.json?["proxies"] as? [[String: Any]])?.map { $0["url"] as? String }
                == ["http://one.example:1", "http://u:p@two.example:2", "http://three.example:3", "http://four.example:4"])
            let first = backend.proxyLibrary.entries[0]
            backend.proxyChecks[first.url] = ProxyExit(ip: "1.1.1.1")
            let checked = await ctl("proxies", "check", first.id.uuidString)
            #expect((checked.json?["results"] as? [[String: Any]])?.count == 1)
            #expect(backend.checked == [first.id])

            let created = await ctl("create", "--name", "Shop", "--group", "电商", "--tag", "a", "--tag", "b",
                                    "--preset", "win11-chrome", "--no-exit-locale")
            #expect(created.status == 0, "\(created.errors)")
            let shop = try #require(backend.profiles.first { $0.name == "Shop" })
            #expect(shop.group == "电商" && shop.tags == ["a", "b"] && shop.fingerprint.platform == .windows)
            #expect(backend.lookedUp.isEmpty)
            let batch = await ctl("create", "--count", "2", "--prefix", "Batch", "--proxy-from-library", "unused", "--no-exit-locale")
            #expect(batch.status == 0, "\(batch.errors)")
            #expect(names(batch) == ["Batch 1", "Batch 2"])
            #expect(backend.profiles.suffix(2).map(\.proxy) == ["http://one.example:1", "http://u:p@two.example:2"])

            let updated = await ctl("update", "Shop", "--notes", "备注", "--json", #"{"fingerprint":{"timeZone":"Asia/Tokyo"}}"#)
            #expect(updated.status == 0, "\(updated.errors)")
            #expect(backend.profiles.first { $0.id == shop.id }?.notes == "备注")
            #expect(backend.profiles.first { $0.id == shop.id }?.fingerprint.timeZone == "Asia/Tokyo")
            #expect((await ctl("clone", "Shop", "--name", "Shop 2")).status == 0)
            #expect(backend.profiles.contains { $0.name == "Shop 2" })

            let started = await ctl("start", "Alpha", "--headless", "--url", "https://example.com", "--arg", "--mute-audio")
            #expect(started.status == 0, "\(started.errors)")
            #expect((started.json?["debug"] as? [String: String])?["webSocket"] == devTools.endpoint.absoluteString)
            #expect(backend.overrides.last == LaunchOverrides(headless: true, urls: ["https://example.com"], arguments: ["--mute-audio"]))
            #expect((await ctl("restart", "Alpha", "--arg=--lang=de")).status == 0)
            #expect(backend.overrides.last == LaunchOverrides(arguments: ["--lang=de"]))
            #expect((await ctl("cookies", "export", "Alpha")).json?["startedHeadless"] as? Bool == false)
            #expect((await ctl("stop", "Alpha", "--force")).status == 0)
            #expect(backend.forced == [true])
            #expect((await ctl("log", "Alpha")).json?["log"] as? String == "launch output")

            let file = sandbox.root.appendingPathComponent("cookies.json")
            // An existing file is replaced, and only this user can read the new one.
            FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o644])
            let exported = await ctl("cookies", "export", "Alpha", "--format", "devTools", "--output", file.path)
            #expect(exported.status == 0, "\(exported.errors)")
            #expect(exported.json?["cookies"] == nil && exported.json?["output"] as? String == file.path)
            #expect(exported.json?["startedHeadless"] as? Bool == true)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
            #expect(saved?.first?["name"] as? String == "sid")
            #expect(try permissions(file) == 0o600)
            #expect((await ctl("cookies", "import", "Alpha", file.path)).json?["startedHeadless"] as? Bool == true)
            let piped = await ctl("cookies", "import", "Alpha", "-", input: try Data(contentsOf: file))
            #expect(piped.status == 0, "\(piped.errors)")
            #expect(devTools.methods.filter { $0 == "Storage.setCookies" }.count == 2)

            backend.states[beta.id] = .running(pid: 7, port: 9402, debugReady: true)
            let arranged = await ctl("arrange", "Alpha", "Beta", "--columns", "2")
            #expect(arranged.status == 0, "\(arranged.errors)")
            #expect(backend.arranged.last?.ids == [alpha.id, beta.id] && backend.arranged.last?.columns == 2)

            #expect((await ctl("delete", "Shop 2")).json?["result"] as? String == "trashed")
            #expect((await ctl("list", "--trash")).output.contains("Shop 2"))
            #expect((await ctl("restore", "Shop 2")).status == 0)
            #expect((await ctl("delete", "Shop 2")).status == 0)
            let purged = await ctl("delete", "Shop 2", "--purge", "--delete-data")
            #expect(purged.json?["result"] as? String == "removed")
            #expect(backend.removed.last?.browserData == true)
            #expect(!backend.profiles.contains { $0.name == "Shop 2" } && backend.store.trashed.isEmpty)
        }
    }

    @Test("Errors exit non-zero with a Chinese reason on stderr and nothing on stdout")
    func errors() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let backend = try FakeBackend()
        _ = try backend.add("Alpha", port: 9401)
        _ = try backend.add("Dup", port: 9402)
        _ = try backend.add("Dup", port: 9403)
        try await serveAutomation(backend) { port in
            let environment = sandbox.environment(["ANYBROWSER_TOKEN": automationTestToken, "ANYBROWSER_PORT": String(port)])
            func ctl(_ arguments: String...) async -> ControlRun { await ControlRun.run(arguments, environment: environment) }

            let notRunning = await ctl("selfcheck", "Alpha")
            #expect(notRunning.status == 1 && notRunning.output.isEmpty)
            #expect(notRunning.errors == "anybrowserctl：自检需要 Profile 正在运行，请先启动它。（HTTP 409，not_running）\n")
            let invalid = await ctl("update", "Alpha", "--json", #"{"port": 80}"#)
            #expect(invalid.status == 1 && invalid.errors.contains("调试端口须为 1024–65535。（HTTP 400，invalid）"))
            // A name that matches no Profile or several exits 1, as an unknown id does.
            let ambiguous = await ctl("show", "Dup")
            #expect(ambiguous.status == 1 && ambiguous.errors.contains("有 2 个名为「Dup」的 Profile，请改用 id。"))
            let missing = await ctl("start", "Ghost")
            #expect(missing.status == 1 && missing.errors.contains("找不到名为「Ghost」的 Profile。"))
            #expect((await ctl("show", UUID().uuidString)).status == 1)
            for usage in [["frob"], ["start"], ["update", "Alpha"], ["list", "--bogus"], ["create", "--prefix", "x"],
                          ["delete", "Alpha", "--delete-data"], ["cookies", "copy", "Alpha"], ["create", "--json", "[1]"]] {
                let run = await ControlRun.run(usage, environment: environment)
                #expect(run.status == 2, "\(usage)")
                #expect(run.errors.hasPrefix("anybrowserctl："), "\(usage)")
                #expect(run.output.isEmpty, "\(usage)")
            }
            #expect(backend.profiles.count == 3 && backend.started.isEmpty)

            let wrongToken = await ControlRun.run(["list", "--token", String(repeating: "5b", count: 32)], environment: environment)
            #expect(wrongToken.status == 1 && wrongToken.errors.contains("令牌") && wrongToken.errors.contains("HTTP 401"))
            let help = await ctl("help")
            #expect(help.status == 0 && help.output.hasPrefix("用法：anybrowserctl"))
        }
        let unreachable = await ControlRun.run(["list", "--token", automationTestToken, "--port", "1"], environment: sandbox.environment())
        #expect(unreachable.status == 3 && unreachable.errors.contains("无法连接 127.0.0.1:1"))
        let tokenless = await ControlRun.run(["list"], environment: sandbox.environment())
        #expect(tokenless.status == 3 && tokenless.errors.contains("没有访问令牌"))
    }

    @Test("delete --purge looks a name up among saved and trashed Profiles together, and never guesses between namesakes")
    func purgeByName() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let backend = try FakeBackend()
        _ = try backend.add("Dup", port: 9401)
        _ = try backend.add("Dup", port: 9402)
        let trashedDup = try backend.add("Dup", port: 9403)
        let pair = try backend.add("Pair", port: 9404)
        let trashedPair = try backend.add("Pair", port: 9405)
        let old = try backend.add("Old", port: 9406)
        for id in [trashedDup.id, trashedPair.id, old.id] { try backend.trash(id) }
        try await serveAutomation(backend) { port in
            let environment = sandbox.environment(["ANYBROWSER_TOKEN": automationTestToken, "ANYBROWSER_PORT": String(port)])
            func ctl(_ arguments: String...) async -> ControlRun { await ControlRun.run(arguments, environment: environment) }

            let crowded = await ctl("delete", "Dup", "--purge", "--delete-data")
            #expect(crowded.status == 1 && crowded.output.isEmpty)
            #expect(crowded.errors.contains("有 3 个名为「Dup」的 Profile（含回收站），请改用 id。"))
            // One saved and one trashed is just as ambiguous.
            let split = await ctl("delete", "Pair", "--purge")
            #expect(split.status == 1 && split.errors.contains("有 2 个名为「Pair」的 Profile（含回收站），请改用 id。"))
            #expect(backend.removed.isEmpty)
            #expect(Set(backend.store.trashed.map(\.id)) == [trashedDup.id, trashedPair.id, old.id])
            #expect(backend.profiles.contains { $0.id == pair.id })
            // Without --purge only saved Profiles are searched, so the trashed namesake does not count.
            #expect((await ctl("delete", "Pair")).json?["result"] as? String == "trashed")

            let missing = await ctl("delete", "Ghost", "--purge")
            #expect(missing.status == 1 && missing.errors.contains("找不到名为「Ghost」的 Profile（含回收站）。"))
            let purged = await ctl("delete", "Old", "--purge", "--delete-data")
            #expect(purged.status == 0, "\(purged.errors)")
            #expect(backend.removed.map(\.id) == [old.id] && backend.removed.map(\.browserData) == [true])
        }
    }

    @Test("Without a token it reads AnyBrowser's saved settings read-only, and options win over the environment")
    func savedSettings() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let backend = try FakeBackend()
        _ = try backend.add("Alpha", port: 9401)
        try await serveAutomation(backend) { port in
            let store = try ProfileStore(directory: sandbox.data)
            try store.saveAutomationConfiguration(AutomationConfiguration(enabled: true, port: port, token: automationTestToken))
            let before = try snapshot(sandbox.data)

            let saved = await ControlRun.run(["list"], environment: sandbox.environment())
            #expect(saved.status == 0, "\(saved.errors)")
            #expect((saved.json?["profiles"] as? [[String: Any]])?.count == 1)
            // Nothing in the data directory changed: no migration, backup or new permissions.
            #expect(try snapshot(sandbox.data) == before)

            let wrong = sandbox.environment(["ANYBROWSER_TOKEN": String(repeating: "5b", count: 32), "ANYBROWSER_PORT": "1"])
            #expect((await ControlRun.run(["list"], environment: wrong)).status != 0)
            let overridden = await ControlRun.run(["list", "--token", automationTestToken, "--port", String(port)], environment: wrong)
            #expect(overridden.status == 0, "\(overridden.errors)")
            // A token alone takes the port from the saved settings.
            #expect((await ControlRun.run(["list", "--token", automationTestToken], environment: sandbox.environment())).status == 0)
            // So does a port given elsewhere than the database.
            let elsewhere = try scratchDirectory("anybrowserctl-elsewhere")
            defer { try? FileManager.default.removeItem(at: elsewhere) }
            #expect((await ControlRun.run(["list", "--data-dir", sandbox.data.path],
                                          environment: ["HOME": elsewhere.path, "ANYBROWSER_DATA_DIR": elsewhere.path])).status == 0)
            // A data directory reached through a symbolic link, as anything under /tmp is.
            let link = elsewhere.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sandbox.data)
            let linked = await ControlRun.run(["list", "--data-dir", link.path], environment: ["HOME": elsewhere.path])
            #expect(linked.status == 0, "\(linked.errors)")
            #expect(try snapshot(sandbox.data) == before)

            try store.saveAutomationConfiguration(AutomationConfiguration(enabled: false, port: port, token: automationTestToken))
            let disabled = await ControlRun.run(["list"], environment: sandbox.environment())
            #expect(disabled.status == 3 && disabled.errors.contains("自动化接口未开启"))
            #expect((await ControlRun.run(["list", "--token", automationTestToken], environment: sandbox.environment())).status == 0)
        }
    }

    /// Every file under `directory` with its size, permissions, modification time and contents.
    private func snapshot(_ directory: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let contents = (try? Data(contentsOf: url)).map { String($0.hashValue) } ?? "directory"
            files[String(url.path.dropFirst(directory.path.count))] = [
                "\(attributes[.size] ?? "")", "\(attributes[.posixPermissions] ?? "")",
                "\(attributes[.modificationDate] ?? "")", contents,
            ].joined(separator: " ")
        }
        return files
    }
}
