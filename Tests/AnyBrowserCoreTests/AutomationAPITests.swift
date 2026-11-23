@testable import AnyBrowserCore
import Foundation
import Testing

// The endpoints added to the automation API, through a real server on a `FakeBackend`.

@Suite("Automation API endpoints", .serialized)
@MainActor
struct AutomationAPITests {
    private func get(_ port: Int, _ path: String) async -> RawClient.Reply {
        await automationRequest(port, "GET", path)
    }

    private func call(_ port: Int, _ method: String, _ path: String, _ body: Any? = nil) async -> RawClient.Reply {
        guard let body else { return await automationRequest(port, method, path) }
        return await automationRequest(port, method, path, json: body)
    }

    private func objects(_ reply: RawClient.Reply, _ key: String = "profiles") -> [[String: Any]] {
        reply.json?[key] as? [[String: Any]] ?? []
    }

    /// The id of the Profile an answer names under `profile`.
    private func createdID(_ reply: RawClient.Reply) -> UUID? {
        ((reply.json?["profile"] as? [String: Any])?["id"] as? String).flatMap { UUID(uuidString: $0) }
    }

    private func names(_ reply: RawClient.Reply) -> [String] {
        objects(reply).compactMap { $0["name"] as? String }
    }

    // MARK: Bodies

    @Test("Bodies must be JSON objects; malformed ones get 400 and change nothing")
    func jsonBodies() async throws {
        let backend = try FakeBackend()
        let profile = try backend.add("Alpha", port: 9401)
        try await serveAutomation(backend) { port in
            for body in ["{\"headless\":", "[1]", "\"text\"", "null", "{\"headless\": true}x"] {
                let start = await automationRequest(port, "POST", "/api/v1/profiles/\(profile.id)/start", body: body)
                #expect(start.status == 400, "\(body)")
                #expect(start.errorCode == "invalid_json")
                #expect(await automationRequest(port, "POST", "/api/v1/profiles", body: body).errorCode == "invalid_json")
                #expect(await automationRequest(port, "PATCH", "/api/v1/profiles/\(profile.id)", body: body).errorCode == "invalid_json")
            }
            #expect(backend.started.isEmpty)
            #expect(backend.profiles.count == 1)
            // Whitespace counts as no body.
            #expect(await automationRequest(port, "POST", "/api/v1/profiles/\(profile.id)/start", body: " \n").status == 200)

            // Over 64 KB in total gets 413 before any of it is read as JSON.
            let large = "{\"notes\":\"\(String(repeating: "a", count: 70_000))\"}"
            let refused = await automationRequest(port, "POST", "/api/v1/profiles", body: large)
            #expect(refused.status == 413)
            #expect(refused.errorCode == "payload_too_large")
            #expect(backend.profiles.count == 1)
        }
    }

    // MARK: Listing

    @Test("The list filters by search, group, tag, browser state and account state")
    func listFilters() async throws {
        let backend = try FakeBackend()
        let alpha = try backend.add("Alpha", port: 9401, group: "工作") {
            $0.tags = ["Shop", "us"]
            $0.accountStatus = .banned
        }
        let beta = try backend.add("Beta", port: 9402, group: "工作") { $0.tags = ["shop"] }
        _ = try backend.add("Gamma", port: 9403) { $0.notes = "备用" }
        backend.states[beta.id] = .running(pid: 7, port: 9402, debugReady: true)
        backend.pendingRestarts = [beta.id, alpha.id]
        try await serveAutomation(backend) { port in
            #expect(names(await get(port, "/api/v1/profiles")) == ["Alpha", "Beta", "Gamma"])
            #expect(names(await get(port, "/api/v1/profiles?q=tag:shop")) == ["Alpha", "Beta"])
            #expect(names(await get(port, "/api/v1/profiles?q=status:%E5%B7%B2%E5%B0%81%E7%A6%81")) == ["Alpha"])
            #expect(names(await get(port, "/api/v1/profiles?q=%E5%A4%87%E7%94%A8")) == ["Gamma"])
            #expect(names(await get(port, "/api/v1/profiles?group=%E5%B7%A5%E4%BD%9C")) == ["Alpha", "Beta"])
            // The whole group name, not a part of it; an empty one means ungrouped.
            #expect(names(await get(port, "/api/v1/profiles?group=%E5%B7%A5")) == [])
            #expect(names(await get(port, "/api/v1/profiles?group=")) == ["Gamma"])
            #expect(names(await get(port, "/api/v1/profiles?tag=SHOP")) == ["Alpha", "Beta"])
            #expect(names(await get(port, "/api/v1/profiles?tag=shop&tag=us")) == ["Alpha"])
            #expect(names(await get(port, "/api/v1/profiles?tag=sh")) == [])
            #expect(names(await get(port, "/api/v1/profiles?status=running")) == ["Beta"])
            #expect(names(await get(port, "/api/v1/profiles?status=stopped&status=running")) == ["Alpha", "Beta", "Gamma"])
            #expect(names(await get(port, "/api/v1/profiles?accountStatus=banned")) == ["Alpha"])
            #expect(names(await get(port, "/api/v1/profiles?accountStatus=none")) == ["Beta", "Gamma"])
            #expect(names(await get(port, "/api/v1/profiles?group=%E5%B7%A5%E4%BD%9C&status=stopped")) == ["Alpha"])
            for bad in ["status=banned", "accountStatus=running"] {
                let reply = await get(port, "/api/v1/profiles?\(bad)")
                #expect(reply.status == 400, "\(bad)")
                #expect(reply.errorCode == "invalid")
            }

            let listed = objects(await get(port, "/api/v1/profiles"))
            #expect(listed[0]["tags"] as? [String] == ["Shop", "us"])
            #expect(listed[0]["accountStatus"] as? String == "banned")
            // Only a running browser can wait for a restart.
            #expect(listed[0]["pendingRestart"] as? Bool == false)
            #expect(listed[1]["pendingRestart"] as? Bool == true)
        }
    }

    @Test("A Profile's config is its whole configuration, without secrets unless asked")
    func configWithoutSecrets() async throws {
        let backend = try FakeBackend()
        let account = PasskeyBoxAccount(serverURL: "https://box.example", username: "own", password: "pw")
        let profile = try backend.add("Alpha", port: 9401) {
            $0.proxy = "http://user:s3cret@proxy.example:8080"
            $0.passkeyBox = account
            $0.launch.startURLs = ["https://example.com/"]
            $0.fingerprint.timeZone = "Europe/Berlin"
        }
        try await serveAutomation(backend) { port in
            let plain = await get(port, "/api/v1/profiles/\(profile.id)")
            #expect(plain.status == 200)
            let config = try #require(plain.json?["config"] as? [String: Any])
            #expect(config["proxy"] as? String == "http://proxy.example:8080")
            #expect(config["passkeyBox"] == nil)
            #expect(!String(decoding: plain.body, as: UTF8.self).contains("s3cret"))
            #expect((config["launch"] as? [String: Any])?["startURLs"] as? [String] == ["https://example.com/"])
            #expect((config["fingerprint"] as? [String: Any])?["timeZone"] as? String == "Europe/Berlin")
            #expect((config["fingerprint"] as? [String: Any])?["seed"] as? Int == 9401)
            #expect(config["id"] as? String == profile.id.uuidString)
            #expect((plain.json?["profile"] as? [String: Any])?["name"] as? String == "Alpha")

            let full = await get(port, "/api/v1/profiles/\(profile.id)?secrets=1")
            let secret = try #require(full.json?["config"] as? [String: Any])
            #expect(secret["proxy"] as? String == "http://user:s3cret@proxy.example:8080")
            #expect((secret["passkeyBox"] as? [String: Any])?["password"] as? String == "pw")
            // Decodes as the Profile it came from.
            let data = try JSONSerialization.data(withJSONObject: secret)
            #expect(try JSONDecoder().decode(BrowserProfile.self, from: data) == profile)

            #expect(await get(port, "/api/v1/profiles/\(profile.id)?secrets=maybe").status == 400)
        }
    }

    // MARK: Creating

    @Test("A new Profile gets a free port, a sampled identity and its proxy exit's locale")
    func createDefaults() async throws {
        let backend = try FakeBackend()
        _ = try backend.add("Profile 1", port: 9222)
        backend.lookups[BrowserProfile.defaultProxy] = ProxyExit(ip: "203.0.113.5", countryCode: "DE", timeZone: "Europe/Berlin",
                                                                languages: ["de-DE"])
        try await serveAutomation(backend) { port in
            let created = await call(port, "POST", "/api/v1/profiles")
            #expect(created.status == 201)
            let id = try #require(createdID(created))
            let saved = try #require(backend.profiles.first { $0.id == id })
            #expect(saved.name == "Profile 2")
            #expect(saved.port == 9223)
            #expect(saved.proxy == BrowserProfile.defaultProxy)
            #expect(saved.fingerprint.platform == .macOS)
            #expect(saved.fingerprint.language == "de-DE" && saved.fingerprint.timeZone == "Europe/Berlin")
            #expect(backend.lookedUp == [BrowserProfile.defaultProxy])
            // The exit found is kept, so the first launch need not look it up again.
            #expect(backend.proxyLibrary.lastExit(forProfile: id)?.exit.ip == "203.0.113.5")
            #expect(created.json?["warnings"] as? [String] == [])
            #expect((created.json?["config"] as? [String: Any])?["name"] as? String == "Profile 2")
            #expect(await get(port, "/api/v1/profiles/\(id)").status == 200)

            // A failed lookup keeps the sampled locale and says so.
            backend.lookups = [:]
            let unaligned = await call(port, "POST", "/api/v1/profiles", ["proxy": "socks5://user:pw@proxy.example:1080"])
            #expect(unaligned.status == 201)
            #expect(unaligned.json?["warnings"] as? [String] == ["代理 socks5://proxy.example:1080 的出口检测失败，语言和时区保持随机。"])
            #expect(!String(decoding: unaligned.body, as: UTF8.self).contains("pw@"))
        }
    }

    @Test("Fields, a preset and a proxy from the library shape the new Profile")
    func createWithFields() async throws {
        let backend = try FakeBackend()
        let entries = try backend.proxyLibrary.add(["http://a:1@one.example:8000", "two.example:8000"])
        _ = try backend.add("Used", port: 9401) { $0.proxy = "http://a:1@one.example:8000" }
        backend.lookups["http://two.example:8000"] = ProxyExit(ip: "198.51.100.2", countryCode: "JP", timeZone: "Asia/Tokyo",
                                                              languages: ["ja-JP"])
        try await serveAutomation(backend) { port in
            let created = await call(port, "POST", "/api/v1/profiles", [
                "name": "Shop 1", "group": "电商", "tags": ["new"], "accountStatus": "verifying", "preset": "win11-chrome",
                "port": 9555, "launch": ["startURLs": ["https://example.com"]], "proxyFromLibrary": "unused",
            ])
            #expect(created.status == 201)
            let id = try #require(createdID(created))
            let saved = try #require(backend.profiles.first { $0.id == id })
            #expect(saved.name == "Shop 1" && saved.group == "电商" && saved.tags == ["new"] && saved.accountStatus == .verifying)
            #expect(saved.port == 9555)
            #expect(saved.fingerprint.platform == .windows && saved.fingerprint.brand == .chrome)
            #expect(saved.launch.startURLs == ["https://example.com/"])
            // The first entry is used by "Used"; the second is free.
            #expect(saved.proxy == "http://two.example:8000")
            #expect(saved.fingerprint.timeZone == "Asia/Tokyo" && saved.fingerprint.language == "ja-JP")

            // A specific entry, its own locale fields, and no lookup for them.
            backend.lookups = [:]
            let chosen = await call(port, "POST", "/api/v1/profiles", [
                "proxyFromLibrary": entries[0].id.uuidString, "fingerprint": ["timeZone": "America/Chicago", "language": "en-US"],
            ])
            #expect(chosen.status == 201)
            let second = try #require(backend.profiles.last)
            #expect(second.proxy == "http://a:1@one.example:8000")
            #expect(second.fingerprint.timeZone == "America/Chicago")
            #expect(backend.lookedUp == ["http://two.example:8000"])
            #expect(chosen.json?["warnings"] as? [String] == [])

            let quiet = await call(port, "POST", "/api/v1/profiles", ["localeFromExit": false])
            #expect(quiet.status == 201)
            #expect(backend.lookedUp.count == 1)

            // Every proxy in the library is taken now.
            let exhausted = await call(port, "POST", "/api/v1/profiles", ["proxyFromLibrary": "unused"])
            #expect(exhausted.status == 409)
            #expect(exhausted.errorCode == "conflict")
        }
    }

    @Test("Bad create requests get 400, and a taken port or seed 409; nothing is saved")
    func createErrors() async throws {
        let backend = try FakeBackend()
        let existing = try backend.add("Alpha", port: 9401)
        backend.lookups[BrowserProfile.defaultProxy] = ProxyExit(ip: "203.0.113.5")
        try await serveAutomation(backend) { port in
            for (body, code) in [
                (["nmae": "Typo"], "invalid"),
                (["fingerprint": ["platfrom": "windows"]], "invalid"),
                (["fingerprint": ["platform": "android"]], "invalid"),
                (["accountStatus": "lost"], "invalid"),
                (["name": ""], "invalid"),
                (["port": 80], "invalid"),
                (["port": "9500"], "invalid"),
                (["id": UUID().uuidString], "invalid"),
                (["preset": "amiga"], "invalid"),
                (["proxy": "socks4://h:1"], "invalid"),
                (["proxy": "h:1", "proxyFromLibrary": "unused"], "invalid"),
                (["proxyFromLibrary": UUID().uuidString], "invalid"),
                (["proxyFromLibrary": [UUID().uuidString]], "invalid"),
                (["localeFromExit": 1], "invalid"),
                (["port": 9401], "conflict"),
                (["fingerprint": ["seed": 9401]], "conflict"),
            ] as [([String: Any], String)] {
                let reply = await call(port, "POST", "/api/v1/profiles", body)
                #expect(reply.status == (code == "conflict" ? 409 : 400), "\(body)")
                #expect(reply.errorCode == code, "\(body): \(reply.errorMessage ?? "")")
            }
            let typo = await call(port, "POST", "/api/v1/profiles", ["nmae": "Typo", "fingerprint": ["platfrom": "windows"]])
            #expect(typo.errorMessage == "无法识别的字段或取值：fingerprint.platfrom、nmae")
            let taken = await call(port, "POST", "/api/v1/profiles", ["port": 9401])
            #expect(taken.errorMessage == "调试端口 9401 已分配给 Alpha。")
            #expect(backend.profiles == [existing])
        }
    }

    @Test("A batch gets one identity per Profile, a proxy each from the library and each exit's locale")
    func batches() async throws {
        let backend = try FakeBackend()
        let entries = try backend.proxyLibrary.add(["one.example:1", "two.example:2", "three.example:3"])
        backend.lookups["http://one.example:1"] = ProxyExit(ip: "1.1.1.1", timeZone: "Europe/Paris", languages: ["fr-FR"])
        backend.lookups["http://two.example:2"] = ProxyExit(ip: "2.2.2.2", timeZone: "Asia/Tokyo", languages: ["ja-JP"])
        try await serveAutomation(backend) { port in
            let created = await call(port, "POST", "/api/v1/profiles/batch", [
                "count": 3, "prefix": "Shop", "group": "电商", "tags": ["batch"], "preset": "macos26-chrome",
                "proxyFromLibrary": "unused",
            ])
            #expect(created.status == 201)
            #expect(names(created) == ["Shop 1", "Shop 2", "Shop 3"])
            let saved = backend.profiles
            #expect(saved.count == 3)
            #expect(saved.map(\.proxy) == entries.map(\.url))
            #expect(Set(saved.map(\.port)).count == 3 && Set(saved.map(\.fingerprint.seed)).count == 3)
            #expect(saved.allSatisfy {
                $0.group == "电商" && $0.tags == ["batch"] && $0.fingerprint.platform == .macOS
                    // Each Profile gets a display and font of its own; the font follows the version.
                    && ["26", "15"].contains(where: $0.fingerprint.platformVersion.hasPrefix)
            })
            #expect(saved[0].fingerprint.timeZone == "Europe/Paris")
            #expect(saved[1].fingerprint.timeZone == "Asia/Tokyo")
            // Each address is looked up once, all at the same time.
            #expect(Set(backend.lookedUp) == Set(entries.map(\.url)) && backend.lookedUp.count == 3)
            #expect(created.json?["warnings"] as? [String] == ["代理 http://three.example:3 的出口检测失败，语言和时区保持随机。"])

            // Ids in order, one per Profile.
            let listed = await call(port, "POST", "/api/v1/profiles/batch", [
                "count": 2, "prefix": "Pair", "proxyFromLibrary": [entries[2].id.uuidString, entries[0].id.uuidString],
                "localeFromExit": false,
            ])
            #expect(listed.status == 201)
            #expect(backend.profiles.suffix(2).map(\.proxy) == [entries[2].url, entries[0].url])

            let before = backend.profiles
            for body in [
                ["count": 0], ["count": 51], ["count": 2, "name": "X"], ["count": 2, "port": 9500],
                ["count": 2, "fingerprint": ["seed": 5]], ["prefix": "No count"], ["count": 2, "tags": ["a,b"]],
                ["count": 2, "proxyFromLibrary": [entries[0].id.uuidString, entries[1].id.uuidString, entries[2].id.uuidString]],
            ] as [[String: Any]] {
                let reply = await call(port, "POST", "/api/v1/profiles/batch", body)
                #expect(reply.status == 400, "\(body)")
            }
            let crowded = await call(port, "POST", "/api/v1/profiles/batch", ["count": 2, "proxyFromLibrary": "unused"])
            #expect(crowded.status == 409)
            #expect(backend.profiles == before)
        }
    }

    @Test("A clone gets a new id, name, port and seed, and the fields given")
    func clones() async throws {
        let backend = try FakeBackend()
        let original = try backend.add("Alpha", port: 9401, group: "工作") { $0.tags = ["x"] }
        try await serveAutomation(backend) { port in
            let copy = await call(port, "POST", "/api/v1/profiles/\(original.id)/clone")
            #expect(copy.status == 201)
            let clone = try #require(backend.profiles.last)
            #expect(clone.id != original.id && clone.name == "Alpha 副本" && clone.group == "工作" && clone.tags == ["x"])
            #expect(clone.port != original.port && clone.fingerprint.seed != original.fingerprint.seed)
            #expect((copy.json?["config"] as? [String: Any])?["name"] as? String == "Alpha 副本")

            let named = await call(port, "POST", "/api/v1/profiles/\(original.id)/clone", ["name": "Beta", "group": ""])
            #expect(named.status == 201)
            #expect(backend.profiles.last?.name == "Beta" && backend.profiles.last?.group == "")
            #expect(await call(port, "POST", "/api/v1/profiles/\(original.id)/clone", ["id": UUID().uuidString]).status == 400)
            #expect(await call(port, "POST", "/api/v1/profiles/\(UUID())/clone").status == 404)
            #expect(backend.profiles.count == 3)
        }
    }

    @Test("Creations sent at once each get their own port, seed and unused proxy")
    func overlappingCreations() async throws {
        let backend = try FakeBackend()
        let original = try backend.add("Alpha", port: 9222)
        let entries = try backend.proxyLibrary.add(["one.example:1", "two.example:2", "three.example:3", "four.example:4"])
        // Every exit lookup takes a while, so the requests overlap.
        backend.duringLookup = { _ in try? await Task.sleep(nanoseconds: 200_000_000) }
        try await serveAutomation(backend) { port in
            async let plain = call(port, "POST", "/api/v1/profiles")
            // Ports of their own, so only the proxy could be picked twice.
            async let first = call(port, "POST", "/api/v1/profiles", ["port": 9501, "proxyFromLibrary": "unused"])
            async let second = call(port, "POST", "/api/v1/profiles", ["port": 9502, "proxyFromLibrary": "unused"])
            async let batch = call(port, "POST", "/api/v1/profiles/batch", ["count": 2, "proxyFromLibrary": "unused"])
            async let copy = call(port, "POST", "/api/v1/profiles/\(original.id)/clone")
            let replies = await [plain, first, second, batch, copy]
            #expect(replies.map(\.status) == [201, 201, 201, 201, 201], "\(replies.map { $0.errorMessage ?? "" })")
            let profiles = backend.profiles
            #expect(profiles.count == 7)
            #expect(Set(profiles.map(\.port)).count == 7 && Set(profiles.map(\.fingerprint.seed)).count == 7)
            // Four unused proxies for four Profiles: one each.
            #expect(Set(profiles.map(\.proxy)) == Set(entries.map(\.url) + [BrowserProfile.defaultProxy]))
        }
    }

    // MARK: Changing

    @Test("PATCH merges any field into the saved configuration and reports a pending restart")
    func patches() async throws {
        let backend = try FakeBackend()
        let profile = try backend.add("Alpha", port: 9401) {
            $0.proxy = "http://user:s3cret@proxy.example:8080"
            $0.accountStatus = .active
            $0.fingerprint.language = "de-DE"
            $0.fingerprint.timeZone = "Europe/Berlin"
        }
        let other = try backend.add("Beta", port: 9402)
        try await serveAutomation(backend) { port in
            let path = "/api/v1/profiles/\(profile.id)"
            let renamed = await call(port, "PATCH", path, [
                "name": "Alpha 2", "tags": ["a", "b"], "accountStatus": NSNull(),
                "fingerprint": ["timeZone": "Asia/Tokyo"], "launch": ["startURLs": ["https://example.com"]],
            ])
            #expect(renamed.status == 200)
            #expect(renamed.json?["pendingRestart"] as? Bool == false)
            var saved = try #require(backend.profiles.first { $0.id == profile.id })
            #expect(saved.name == "Alpha 2" && saved.tags == ["a", "b"] && saved.accountStatus == nil)
            // Objects merge: the language stays, only the time zone changed.
            #expect(saved.fingerprint.timeZone == "Asia/Tokyo" && saved.fingerprint.language == "de-DE")
            #expect(saved.launch.startURLs == ["https://example.com/"])
            #expect(saved.proxy == "http://user:s3cret@proxy.example:8080")

            // Sending back the configuration read without secrets keeps the proxy's credentials.
            let read = try #require(await get(port, path).json?["config"] as? [String: Any])
            var roundTrip = read
            roundTrip["notes"] = "round trip"
            #expect(await call(port, "PATCH", path, roundTrip).status == 200)
            saved = try #require(backend.profiles.first { $0.id == profile.id })
            #expect(saved.notes == "round trip")
            #expect(saved.proxy == "http://user:s3cret@proxy.example:8080")

            // Every field may change, the Passkey Box account and extension folders included.
            backend.states[profile.id] = .running(pid: 7, port: 9401, debugReady: true)
            backend.pendingRestarts = [profile.id]
            let reach = await call(port, "PATCH", path, [
                "passkeyBox": ["serverURL": "https://box.example", "username": "u", "password": "p"],
                "launch": ["extensionDirectories": ["/tmp/extension"]], "proxy": "",
            ])
            #expect(reach.status == 200)
            #expect(reach.json?["pendingRestart"] as? Bool == true)
            #expect((reach.json?["profile"] as? [String: Any])?["pendingRestart"] as? Bool == true)
            saved = try #require(backend.profiles.first { $0.id == profile.id })
            #expect(saved.passkeyBox?.username == "u" && saved.launch.extensionDirectories == ["/tmp/extension"] && saved.proxy == "")
            #expect((reach.json?["config"] as? [String: Any])?["passkeyBox"] == nil)

            let before = backend.profiles
            for (body, status) in [
                (["nmae": "x"], 400), (["name": ""], 400), (["port": 9402], 409), (["fingerprint": ["seed": 9402]], 409),
                (["id": other.id.uuidString], 400), (["launch": ["startURLs": ["ftp://x"]]], 400), (["tags": "a"], 400),
            ] as [([String: Any], Int)] {
                let reply = await call(port, "PATCH", path, body)
                #expect(reply.status == status, "\(body)")
            }
            #expect(await call(port, "PATCH", path, ["id": profile.id.uuidString, "notes": "same id"]).status == 200)
            backend.busy = [profile.id]
            #expect(await call(port, "PATCH", path, ["notes": "busy"]).errorCode == "busy")
            backend.busy = []
            #expect(backend.profiles.first { $0.id == profile.id }?.notes == "same id")
            #expect(backend.profiles.first { $0.id == other.id } == before.first { $0.id == other.id })
        }
    }

    @Test("Spaces around the language, time zone and versions are dropped, as the editor drops them")
    func spacesDropped() async throws {
        let backend = try FakeBackend()
        let profile = try backend.add("Alpha", port: 9401)
        let fingerprint = profile.fingerprint
        try await serveAutomation(backend) { port in
            let patched = await call(port, "PATCH", "/api/v1/profiles/\(profile.id)", ["fingerprint": [
                "language": " en-US", "timeZone": " Asia/Tokyo ",
                "platformVersion": " \(fingerprint.platformVersion) ", "brandVersion": "\(fingerprint.brandVersion)\n",
            ]])
            #expect(patched.status == 200, "\(patched.errorMessage ?? "")")
            let saved = try #require(backend.profiles.first { $0.id == profile.id }?.fingerprint)
            #expect(saved.language == "en-US" && saved.timeZone == "Asia/Tokyo")
            #expect(saved.platformVersion == fingerprint.platformVersion && saved.brandVersion == fingerprint.brandVersion)

            let created = await call(port, "POST", "/api/v1/profiles", ["fingerprint": ["language": "fr-FR ", "timeZone": "\tEurope/Paris"]])
            #expect(created.status == 201, "\(created.errorMessage ?? "")")
            let new = try #require(createdID(created).flatMap { id in backend.profiles.first { $0.id == id } })
            #expect(new.fingerprint.language == "fr-FR" && new.fingerprint.timeZone == "Europe/Paris")
        }
    }

    @Test("DELETE moves to the recycle bin; purge removes for good, with deleteData the browser data too")
    func deletes() async throws {
        let backend = try FakeBackend()
        let alpha = try backend.add("Alpha", port: 9401)
        let beta = try backend.add("Beta", port: 9402)
        let gamma = try backend.add("Gamma", port: 9403)
        backend.states[gamma.id] = .running(pid: 7, port: 9403, debugReady: true)
        try await serveAutomation(backend) { port in
            let trashed = await call(port, "DELETE", "/api/v1/profiles/\(alpha.id)")
            #expect(trashed.status == 200)
            #expect(trashed.json?["result"] as? String == "trashed")
            #expect(trashed.json?["deletedAt"] is String)
            #expect(backend.store.trashed.map(\.id) == [alpha.id])
            #expect(!backend.profiles.contains { $0.id == alpha.id })
            let bin = await get(port, "/api/v1/trash")
            #expect(names(bin) == ["Alpha"])
            #expect(objects(bin).first?["deletedAt"] is String)
            #expect(objects(await get(port, "/api/v1/profiles")).allSatisfy { $0["deletedAt"] == nil })
            #expect(await get(port, "/api/v1/profiles/\(alpha.id)").status == 404)

            let again = await call(port, "DELETE", "/api/v1/profiles/\(alpha.id)")
            #expect(again.status == 409 && again.errorCode == "trashed")
            let running = await call(port, "DELETE", "/api/v1/profiles/\(gamma.id)")
            #expect(running.status == 409 && running.errorCode == "running")
            #expect(running.errorMessage == "请先停止此 Profile 的浏览器，再移除。")
            backend.busy = [beta.id]
            #expect(await call(port, "DELETE", "/api/v1/profiles/\(beta.id)").errorCode == "busy")
            backend.busy = []
            // A batch in progress is another operation, also for a running browser; stopping it would not help.
            backend.batchRunning = true
            for profile in [beta, gamma] {
                let waiting = await call(port, "DELETE", "/api/v1/profiles/\(profile.id)")
                #expect(waiting.status == 409 && waiting.errorCode == "busy")
                #expect(waiting.errorMessage == "批量操作进行中，完成后再移除 Profile。")
            }
            backend.batchRunning = false
            #expect(await call(port, "DELETE", "/api/v1/profiles/\(beta.id)?deleteData=1").status == 400)
            #expect(await call(port, "DELETE", "/api/v1/profiles/\(beta.id)?purge=yes").status == 400)
            #expect(await call(port, "DELETE", "/api/v1/profiles/\(UUID())").status == 404)
            #expect(backend.removed.isEmpty)

            backend.removeProblem = "无法删除 Extensions 目录。"
            let removed = await call(port, "DELETE", "/api/v1/profiles/\(beta.id)?purge=1")
            #expect(removed.status == 200)
            #expect(removed.json?["result"] as? String == "removed")
            #expect(removed.json?["dataDeleted"] as? Bool == false)
            #expect(removed.json?["warnings"] as? [String] == ["无法删除 Extensions 目录。"])
            backend.removeProblem = nil
            // Purging reaches the recycle bin too.
            let purged = await call(port, "DELETE", "/api/v1/profiles/\(alpha.id)?purge=1&deleteData=1")
            #expect(purged.status == 200)
            #expect(purged.json?["dataDeleted"] as? Bool == true)
            #expect(backend.removed.map(\.id) == [beta.id, alpha.id])
            #expect(backend.removed.map(\.browserData) == [false, true])
            #expect(backend.store.trashed.isEmpty)
            #expect(backend.profiles.map(\.id) == [gamma.id])
        }
    }

    @Test("A trashed Profile is restored in place; one not in the recycle bin gets 404")
    func restores() async throws {
        let backend = try FakeBackend()
        let alpha = try backend.add("Alpha", port: 9401)
        let beta = try backend.add("Beta", port: 9402)
        try backend.trash(alpha.id)
        try await serveAutomation(backend) { port in
            #expect(await call(port, "POST", "/api/v1/profiles/\(beta.id)/restore").status == 404)
            // A busy Profile, such as one being purged, stays in the recycle bin.
            backend.busy = [alpha.id]
            let waiting = await call(port, "POST", "/api/v1/profiles/\(alpha.id)/restore")
            #expect(waiting.status == 409 && waiting.errorCode == "busy")
            #expect(backend.store.trashed.map(\.id) == [alpha.id])
            backend.busy = []
            let restored = await call(port, "POST", "/api/v1/profiles/\(alpha.id)/restore")
            #expect(restored.status == 200)
            #expect((restored.json?["profile"] as? [String: Any])?["name"] as? String == "Alpha")
            #expect(restored.json?["config"] is [String: Any])
            #expect(backend.profiles.map(\.id) == [alpha.id, beta.id])
            #expect(backend.store.trashed.isEmpty)
            #expect(await call(port, "POST", "/api/v1/profiles/\(alpha.id)/restore").status == 404)
        }
    }

    @Test("When a newer version wrote the database, every change answers 409 read_only and changes nothing")
    func readOnly() async throws {
        let writable = try FakeBackend()
        let alpha = try writable.add("Alpha", port: 9401)
        let beta = try writable.add("Beta", port: 9402)
        try writable.trash(beta.id)
        let entry = try #require(try writable.proxyLibrary.add(["one.example:1"]).first)
        try execute("PRAGMA user_version = 99", in: writable.directory)
        let backend = try FakeBackend(directory: writable.directory)
        #expect(backend.store.isReadOnly)
        try await serveAutomation(backend) { port in
            for (method, path, body) in [
                ("POST", "/api/v1/profiles", nil),
                ("POST", "/api/v1/profiles/batch", ["count": 1]),
                ("POST", "/api/v1/profiles/\(alpha.id)/clone", nil),
                ("PATCH", "/api/v1/profiles/\(alpha.id)", ["notes": "x"]),
                ("DELETE", "/api/v1/profiles/\(alpha.id)", nil),
                ("DELETE", "/api/v1/profiles/\(beta.id)?purge=1", nil),
                ("POST", "/api/v1/profiles/\(beta.id)/restore", nil),
                ("POST", "/api/v1/proxies", ["urls": ["two.example:2"]]),
                ("PATCH", "/api/v1/proxies/\(entry.id)", ["label": "x"]),
                ("DELETE", "/api/v1/proxies/\(entry.id)", nil),
            ] as [(String, String, [String: Any]?)] {
                let reply = await call(port, method, path, body)
                #expect(reply.status == 409 && reply.errorCode == "read_only", "\(method) \(path): \(reply.errorMessage ?? "")")
                #expect(reply.errorMessage?.contains("更新版本") == true)
            }
            #expect(await get(port, "/api/v1/profiles").status == 200)
            #expect(await get(port, "/api/v1/proxies").status == 200)
        }
        #expect(backend.profiles == [alpha] && backend.store.trashed.map(\.id) == [beta.id])
        #expect(backend.proxyLibrary.entries.map(\.id) == [entry.id] && backend.proxyLibrary.entries.map(\.label) == [""])
        #expect(backend.removed.isEmpty && backend.lookedUp.isEmpty)
    }

    // MARK: Launches

    @Test("Start and restart take headless, urls and args for one launch; stop takes force")
    func launchOverrides() async throws {
        let backend = try FakeBackend()
        let profile = try backend.add("Alpha", port: 9401)
        backend.startWarnings = ["代理 http://127.0.0.1:7890 无法连接。"]
        try await serveAutomation(backend) { port in
            let path = "/api/v1/profiles/\(profile.id)"
            let started = await call(port, "POST", path + "/start", [
                "headless": true, "urls": ["https://example.com"], "args": ["--mute-audio", "--lang=de"],
            ])
            #expect(started.status == 200)
            #expect(backend.overrides == [LaunchOverrides(headless: true, urls: ["https://example.com"], arguments: ["--mute-audio", "--lang=de"])])
            #expect(started.json?["warnings"] as? [String] == ["代理 http://127.0.0.1:7890 无法连接。"])
            #expect((started.json?["debug"] as? [String: String])?["http"] == "http://127.0.0.1:9401")

            // Already running: nothing starts, and the options are said not to apply.
            let again = await call(port, "POST", path + "/start", ["headless": true])
            #expect(again.status == 200)
            #expect(again.json?["startedFresh"] as? Bool == false)
            #expect(again.json?["warnings"] as? [String] == ["浏览器已在运行，本次的启动参数没有生效；需要时用 restart。"])
            #expect(backend.started == [profile.id])

            let restarted = await call(port, "POST", path + "/restart", ["urls": []])
            #expect(restarted.status == 200)
            #expect(backend.restarted == [profile.id])
            #expect(backend.overrides.last == LaunchOverrides(urls: []))
            #expect((restarted.json?["profile"] as? [String: Any])?["status"] as? String == "running")

            #expect(await call(port, "POST", path + "/stop?force=1").status == 200)
            #expect(await call(port, "POST", path + "/stop").status == 200)
            #expect(backend.forced == [true, false])
            #expect(await call(port, "POST", path + "/stop?force=2").status == 400)

            for body in [
                ["headless": 1], ["urls": ["ftp://example.com"]], ["urls": "https://example.com"],
                ["args": ["--user-data-dir=/tmp/x"]], ["args": ["no-dashes"]], ["startURLs": ["https://example.com"]],
            ] as [[String: Any]] {
                let reply = await call(port, "POST", path + "/start", body)
                #expect(reply.status == 400, "\(body)")
                #expect(await call(port, "POST", path + "/restart", body).status == 400, "\(body)")
            }
            #expect(backend.started == [profile.id] && backend.restarted == [profile.id])
            backend.busy = [profile.id]
            #expect(await call(port, "POST", path + "/restart").errorCode == "busy")
            backend.busy = []
            backend.startError = ProfileError.invalid("端口被占用。")
            let failed = await call(port, "POST", path + "/restart")
            #expect(failed.status == 500 && failed.errorCode == "start_failed" && failed.errorMessage == "端口被占用。")
        }
    }

    @Test("reset-identity stops the browser first, answers the new config, and starts it again")
    func resetIdentity() async throws {
        let backend = try FakeBackend()
        let profile = try backend.add("Reset", port: 9404) { $0.deviceIdentity = DeviceIdentity.mint() }
        backend.states[profile.id] = .running(pid: 7, port: 9404, debugReady: true)
        try await serveAutomation(backend) { port in
            let path = "/api/v1/profiles/\(profile.id)"
            let reply = await call(port, "POST", path + "/reset-identity")
            #expect(reply.status == 200, "\(reply.errorMessage ?? "")")
            #expect(backend.resetSteps == ["stop", "reset", "start"])
            let config = try #require(reply.json?["config"] as? [String: Any])
            #expect((config["fingerprint"] as? [String: Any])?["seed"] as? Int != profile.fingerprint.seed)
            #expect(config["deviceIdentity"] as? String != profile.deviceIdentity)
            #expect(reply.json?["warnings"] as? [String] == [])
            #expect((reply.json?["profile"] as? [String: Any])?["status"] as? String == "running")
            let saved = try #require(backend.store.profiles.first { $0.id == profile.id })
            #expect(!saved.launch.restoreSession)
            #expect(backend.store.pendingIdentityReset(profile.id))

            // A Profile already busy refuses the reset.
            backend.busy = [profile.id]
            #expect(await call(port, "POST", path + "/reset-identity").errorCode == "busy")
            backend.busy = []

            // A stage failure comes back with its message.
            backend.startError = ProfileError.invalid("端口被占用。")
            let failed = await call(port, "POST", path + "/reset-identity")
            #expect(failed.status == 500 && failed.errorCode == "reset_failed" && failed.errorMessage == "端口被占用。")
            #expect(await call(port, "GET", path + "/reset-identity").errorCode == "method_not_allowed")
        }
    }

    @Test("The launch log comes back as text, or null when there is none")
    func launchLogs() async throws {
        let backend = try FakeBackend()
        let alpha = try backend.add("Alpha", port: 9401)
        let beta = try backend.add("Beta", port: 9402)
        backend.logs[alpha.id] = "[1:2] ERROR: crashed\n"
        try await serveAutomation(backend) { port in
            let log = await get(port, "/api/v1/profiles/\(alpha.id)/log")
            #expect(log.status == 200)
            #expect(log.json?["log"] as? String == "[1:2] ERROR: crashed\n")
            #expect(await get(port, "/api/v1/profiles/\(beta.id)/log").json?["log"] is NSNull)
            #expect(await get(port, "/api/v1/profiles/\(UUID())/log").status == 404)
        }
    }

    // MARK: Cookies

    private static let cookieReply: [String: Any] = ["cookies": [
        ["name": "sid", "value": "abc", "domain": ".example.com", "path": "/", "expires": 1_900_000_000,
         "httpOnly": true, "secure": true, "session": false, "sameSite": "None"],
    ]]

    @Test("Cookies of a stopped Profile are read from a browser started without windows, which stops again")
    func cookiesOfStoppedProfiles() async throws {
        let backend = try FakeBackend()
        let profile = try backend.add("Alpha", port: 9401)
        let devTools = try await FakeDevTools.start { method, _ in
            method == "Storage.getCookies" ? .delayed(0.5, Self.cookieReply) : .error(-32601, "not found")
        }
        defer { devTools.stop() }
        backend.endpoints[profile.id] = devTools.endpoint
        try await serveAutomation(backend) { port in
            let path = "/api/v1/profiles/\(profile.id)"
            let export = Task { await get(port, path + "/cookies?format=devTools") }
            // While the transfer runs, the API keeps the browser to itself.
            let deadline = Date().addingTimeInterval(5)
            while backend.started.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            let competing = await call(port, "POST", path + "/start")
            #expect(competing.status == 409 && competing.errorCode == "busy")
            #expect(await call(port, "POST", path + "/stop").errorCode == "busy")
            #expect(await call(port, "DELETE", path).errorCode == "busy")
            let reply = await export.value
            #expect(reply.status == 200)
            #expect(reply.json?["format"] as? String == "devTools")
            #expect(reply.json?["count"] as? Int == 1)
            #expect(reply.json?["startedHeadless"] as? Bool == true)
            let cookie = try #require((reply.json?["cookies"] as? [[String: Any]])?.first)
            #expect(cookie["name"] as? String == "sid" && cookie["sameSite"] as? String == "None")
            #expect(cookie["expires"] as? Int == 1_900_000_000)
            #expect(backend.overrides == [LaunchOverrides(headless: true, urls: [])])
            #expect(backend.stopped == [profile.id] && backend.forced == [false])
            #expect(backend.state(for: profile.id) == .stopped)
            // The hold ends with the transfer.
            #expect(await call(port, "POST", path + "/start").status == 200)

            // A running Profile is used as it is.
            let running = await get(port, path + "/cookies")
            #expect(running.status == 200)
            #expect(running.json?["startedHeadless"] as? Bool == false)
            #expect(((running.json?["cookies"] as? [[String: Any]])?.first)?["sameSite"] as? String == "no_restriction")
            #expect(backend.started == [profile.id, profile.id] && backend.stopped == [profile.id])
            #expect(await get(port, path + "/cookies?format=netscape").status == 400)
        }
    }

    @Test("Cookie imports take every file format, refuse unreadable ones and stop a browser they started")
    func cookieImports() async throws {
        let backend = try FakeBackend()
        let profile = try backend.add("Alpha", port: 9401)
        let devTools = try await FakeDevTools.start { method, _ in
            switch method {
            case "Storage.getCookies": return .result(["cookies": []])
            case "Storage.setCookies": return .result([:])
            default: return .error(-32601, "not found")
            }
        }
        defer { devTools.stop() }
        backend.endpoints[profile.id] = devTools.endpoint
        try await serveAutomation(backend) { port in
            let path = "/api/v1/profiles/\(profile.id)/cookies"
            let netscape = "# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t1900000000\tsid\tabc\n"
            let imported = await automationRequest(port, "POST", path, body: netscape)
            #expect(imported.status == 200)
            #expect(imported.json?["imported"] as? Int == 0)
            #expect(imported.json?["startedHeadless"] as? Bool == true)
            #expect(devTools.methods.contains("Storage.setCookies"))
            #expect(backend.stopped == [profile.id])

            for body in ["not cookies", "{\"cookie\": []}", ""] {
                let reply = await automationRequest(port, "POST", path, body: body)
                #expect(reply.status == 400, "\(body)")
            }
            #expect(backend.started.count == 1)
        }
    }

    @Test("A cookie transfer that fails still stops the browser it started")
    func cookieFailures() async throws {
        let backend = try FakeBackend()
        let profile = try backend.add("Alpha", port: 9401)
        let devTools = try await FakeDevTools.start { _, _ in .error(-32000, "Browser closing") }
        defer { devTools.stop() }
        backend.endpoints[profile.id] = devTools.endpoint
        try await serveAutomation(backend) { port in
            let path = "/api/v1/profiles/\(profile.id)/cookies"
            let failed = await get(port, path)
            #expect(failed.status == 500 && failed.errorCode == "cookies_failed")
            #expect(backend.stopped == [profile.id])
            #expect(backend.state(for: profile.id) == .stopped)

            backend.startError = ProfileError.invalid("内置 Chromium 不可用。")
            let unstarted = await get(port, path)
            #expect(unstarted.status == 500 && unstarted.errorCode == "start_failed")
            backend.startError = nil
            backend.busy = [profile.id]
            #expect(await get(port, path).errorCode == "busy")
            backend.busy = []
            // Running but not ready.
            backend.states[profile.id] = .running(pid: 7, port: 9401, debugReady: false)
            #expect(await get(port, path).status == 503)
            #expect(backend.stopped == [profile.id])
        }
    }

    // MARK: Self-check

    @Test("The self-check runs only in a running browser and returns the report itself")
    func selfChecks() async throws {
        let backend = try FakeBackend()
        var fingerprint = FingerprintSettings(seed: 4243)
        fingerprint.platform = .macOS
        fingerprint.language = "de-DE"
        fingerprint.timeZone = "Europe/Berlin"
        let profile = try backend.add("Alpha", port: 9401) { $0.fingerprint = fingerprint }
        let observation = SelfCheckObservation(
            main: .init(userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/148.0.0.0", platform: "MacIntel",
                        hardwareConcurrency: 8, deviceMemory: 8, language: "de-DE", languages: ["de-DE", "de"],
                        timeZone: "Europe/Berlin", locale: "de", dateString: "Thu Jan 15 2026 12:00:00 GMT+0100",
                        measureText: 337, webGLVendor: nil, webGLRenderer: nil),
            worker: nil, frame: nil, clientHints: nil,
            screen: .init(width: 1440, height: 900, availWidth: 1440, availHeight: 875, colorDepth: 24, devicePixelRatio: 2),
            canvasMeasureText: 337, canvasStable: true, markers: [], expectedZoneName: nil)
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observation))
        final class Page: @unchecked Sendable { var url = "" }
        let page = Page()
        let devTools = try await FakeDevTools.start { method, params in
            switch method {
            case "Target.createTarget":
                page.url = params["url"] as? String ?? ""
                return .result(["targetId": "probe"])
            case "Target.attachToTarget":
                return .result(["sessionId": "session"])
            case "Runtime.evaluate":
                let expression = params["expression"] as? String ?? ""
                return .result(["result": ["value": expression.hasPrefix("document.readyState") ? page.url : value]])
            case "Target.closeTarget":
                return .result([:])
            default:
                return .error(-32601, "not found")
            }
        }
        defer { devTools.stop() }
        backend.endpoints[profile.id] = devTools.endpoint
        backend.exits[profile.id] = ProxyExit(ip: "203.0.113.5", countryCode: "DE", timeZone: "Europe/Berlin")
        try await serveAutomation(backend) { port in
            let path = "/api/v1/profiles/\(profile.id)/selfcheck"
            let stopped = await get(port, path)
            #expect(stopped.status == 409 && stopped.errorCode == "not_running")
            #expect(backend.started.isEmpty)

            backend.states[profile.id] = .running(pid: 7, port: 9401, debugReady: true)
            let report = await get(port, path)
            #expect(report.status == 200)
            #expect(report.json?["profileID"] as? String == profile.id.uuidString)
            #expect(report.json?["checkedAt"] is String)
            #expect(report.json?["passed"] is Bool)
            let items = try #require(report.json?["items"] as? [[String: Any]])
            #expect(items.contains { $0["id"] as? String == "time-zone" && $0["status"] as? String == "pass" })
            #expect(items.contains { $0["id"] as? String == "markers" && $0["status"] as? String == "pass" })
            // Compared with the Profile's last exit as well.
            #expect(items.contains { $0["id"] as? String == "exit-time-zone" && $0["status"] as? String == "pass" })
            #expect(devTools.methods.contains("Target.closeTarget"))

            backend.busy = [profile.id]
            #expect(await get(port, path).errorCode == "busy")
            backend.busy = []
            backend.endpointAvailable = false
            #expect(await get(port, path).status == 503)
            backend.refreshedStates[profile.id] = .stopped
            #expect(await get(port, path).errorCode == "not_running")
        }
    }

    // MARK: Windows

    @Test("Windows are arranged for the ids given, or every running Profile")
    func arrangesWindows() async throws {
        let backend = try FakeBackend()
        let alpha = try backend.add("Alpha", port: 9401)
        let beta = try backend.add("Beta", port: 9402)
        backend.states[beta.id] = .running(pid: 7, port: 9402, debugReady: true)
        try await serveAutomation(backend) { port in
            let all = await call(port, "POST", "/api/v1/windows/arrange")
            #expect(all.status == 200)
            #expect(backend.arranged.last?.ids == [beta.id] && backend.arranged.last?.columns == nil)
            let placed = try #require(objects(all, "windows").first)
            #expect(placed["id"] as? String == beta.id.uuidString)
            #expect(placed["frame"] as? [String: Int] == ["left": 0, "top": 25, "width": 100, "height": 200])
            #expect(placed["error"] is NSNull)

            let chosen = await call(port, "POST", "/api/v1/windows/arrange", ["ids": [alpha.id.uuidString, beta.id.uuidString], "columns": 2])
            #expect(chosen.status == 200)
            #expect(backend.arranged.last?.ids == [alpha.id, beta.id] && backend.arranged.last?.columns == 2)
            let first = try #require(objects(chosen, "windows").first)
            #expect(first["frame"] is NSNull && first["error"] as? String == "浏览器没有运行，或调试端口尚未就绪。")

            let count = backend.arranged.count
            #expect(await call(port, "POST", "/api/v1/windows/arrange", ["ids": [UUID().uuidString]]).status == 404)
            for body in [["columns": 0], ["ids": []], ["ids": ["x"]], ["rows": 2]] as [[String: Any]] {
                #expect(await call(port, "POST", "/api/v1/windows/arrange", body).status == 400, "\(body)")
            }
            #expect(backend.arranged.count == count)
            backend.arrangeError = ProfileError.invalid("没有可用的显示器，无法排列窗口。")
            let failed = await call(port, "POST", "/api/v1/windows/arrange")
            #expect(failed.status == 500 && failed.errorCode == "arrange_failed")
        }
    }

    // MARK: Proxy library

    @Test("Proxies are added from text or a list, listed without credentials and edited")
    func proxyLibrary() async throws {
        let backend = try FakeBackend()
        try await serveAutomation(backend) { port in
            let added = await call(port, "POST", "/api/v1/proxies", [
                "text": "# 美国\nus.example:8000:user:s3cret\n\nnot a proxy\nhttp://us.example:8001\nsocks4://old.example:1\n",
                "label": "批次一",
            ])
            #expect(added.status == 201)
            #expect(added.json?["rejected"] as? [String] == ["not a proxy", "socks4://old.example:1"])
            #expect(added.json?["duplicates"] as? Int == 0)
            let entries = objects(added, "added")
            #expect(entries.map { $0["url"] as? String } == ["http://us.example:8000", "http://us.example:8001"])
            #expect(entries.map { $0["hasCredentials"] as? Bool } == [true, false])
            #expect(entries.allSatisfy { $0["label"] as? String == "批次一" && $0["lastExit"] is NSNull })
            #expect(!String(decoding: added.body, as: UTF8.self).contains("s3cret"))
            #expect(backend.proxyLibrary.entries.first?.url == "http://user:s3cret@us.example:8000")

            let listed = await call(port, "POST", "/api/v1/proxies", ["urls": ["us.example:8001", "socks5://a:b@eu.example:1080", "::bad"]])
            #expect(listed.status == 201)
            #expect(listed.json?["duplicates"] as? Int == 1)
            #expect(listed.json?["rejected"] as? [String] == ["::bad"])
            let nothing = await call(port, "POST", "/api/v1/proxies", ["urls": ["us.example:8001"]])
            #expect(nothing.status == 200 && objects(nothing, "added").isEmpty)
            for body in [["text": "a:1", "urls": ["b:1"]], [:], ["urls": "a:1"], ["text": "a:1", "tags": []]] as [[String: Any]] {
                #expect(await call(port, "POST", "/api/v1/proxies", body).status == 400, "\(body)")
            }

            let first = backend.proxyLibrary.entries[0]
            let user = try backend.add("Alpha", port: 9401) { $0.proxy = "us.example:8000:user:s3cret" }
            let plain = objects(await get(port, "/api/v1/proxies"), "proxies")
            #expect(plain.count == 3)
            #expect(plain[0]["profiles"] as? [String] == [user.id.uuidString])
            #expect(plain[0]["url"] as? String == "http://us.example:8000")
            let secret = objects(await get(port, "/api/v1/proxies?secrets=1"), "proxies")
            #expect(secret[0]["url"] as? String == "http://user:s3cret@us.example:8000")
            #expect((await get(port, "/api/v1/proxies/\(first.id)").json?["proxy"] as? [String: Any])?["label"] as? String == "批次一")

            // The address as listed keeps the saved credentials; label, tags and note change.
            let edited = await call(port, "PATCH", "/api/v1/proxies/\(first.id)", [
                "url": "http://us.example:8000", "label": "主力", "tags": ["us"], "note": "备注",
            ])
            #expect(edited.status == 200)
            var entry = try #require(backend.proxyLibrary.entries.first { $0.id == first.id })
            #expect(entry.url == first.url && entry.label == "主力" && entry.tags == ["us"] && entry.note == "备注")
            #expect(await call(port, "PATCH", "/api/v1/proxies/\(first.id)", ["url": "us.example:9000:new:pw"]).status == 200)
            entry = try #require(backend.proxyLibrary.entries.first { $0.id == first.id })
            #expect(entry.url == "http://new:pw@us.example:9000")
            let taken = await call(port, "PATCH", "/api/v1/proxies/\(first.id)", ["url": "us.example:8001"])
            #expect(taken.status == 409 && taken.errorCode == "conflict")
            for body in [["url": "nope"], ["tags": ["a,b"]], ["label": 1], ["exit": "x"]] as [[String: Any]] {
                #expect(await call(port, "PATCH", "/api/v1/proxies/\(first.id)", body).status == 400, "\(body)")
            }

            let removed = await call(port, "DELETE", "/api/v1/proxies/\(first.id)")
            #expect(removed.status == 200 && removed.json?["removed"] as? Bool == true)
            #expect(!backend.proxyLibrary.entries.contains { $0.id == first.id })
            #expect(await call(port, "DELETE", "/api/v1/proxies/\(first.id)").status == 404)
            #expect(await get(port, "/api/v1/proxies/\(UUID())").status == 404)
        }
    }

    @Test("Checking proxies records each exit, or the reason a check failed")
    func proxyChecks() async throws {
        let backend = try FakeBackend()
        let entries = try backend.proxyLibrary.add(["one.example:1", "two.example:2", "three.example:3"])
        backend.proxyChecks["http://one.example:1"] = ProxyExit(ip: "1.1.1.1", countryCode: "FR")
        backend.proxyChecks["http://three.example:3"] = ProxyExit(ip: "3.3.3.3")
        try await serveAutomation(backend) { port in
            let all = await call(port, "POST", "/api/v1/proxies/check")
            #expect(all.status == 200)
            let results = objects(all, "results")
            #expect(results.count == 3)
            #expect(results.map { ($0["proxy"] as? [String: Any])?["id"] as? String } == entries.map(\.id.uuidString))
            #expect(((results[0]["proxy"] as? [String: Any])?["lastExit"] as? [String: Any])?["ip"] as? String == "1.1.1.1")
            #expect(results[0]["error"] is NSNull)
            #expect(results[1]["error"] as? String == "无法查询出口 IP：代理拒绝了连接。")
            #expect((results[1]["proxy"] as? [String: Any])?["lastCheckedAt"] is String)
            #expect(backend.proxyLibrary.entries.map { $0.lastExit?.ip } == ["1.1.1.1", nil, "3.3.3.3"])
            #expect(backend.proxyLibrary.entries.allSatisfy { $0.lastCheckedAt != nil })

            let one = await call(port, "POST", "/api/v1/proxies/check", ["ids": [entries[2].id.uuidString]])
            #expect(objects(one, "results").count == 1)
            #expect(backend.checked.suffix(1) == [entries[2].id])
            let count = backend.checked.count
            #expect(await call(port, "POST", "/api/v1/proxies/check", ["ids": [UUID().uuidString]]).status == 404)
            #expect(await call(port, "POST", "/api/v1/proxies/check", ["ids": "all"]).status == 400)
            #expect(backend.checked.count == count)
        }
    }

    @Test("Repeated creation with one preset keeps finding free combinations")
    func repeatedPresetCreation() async throws {
        let backend = try FakeBackend()
        try await serveAutomation(backend) { port in
            // macOS offers ten screen and font combinations; eight never exhausts them.
            for index in 0..<8 {
                let created = await call(port, "POST", "/api/v1/profiles", ["preset": "macos26-chrome"])
                #expect(created.status == 201, "第 \(index + 1) 个被拒：\(created.body)")
            }
            #expect(backend.profiles.count == 8)
            let combinations = Set(backend.profiles.compactMap { ScreenFontCombination($0.fingerprint) })
            #expect(combinations.count == backend.profiles.count)
        }
    }
}
