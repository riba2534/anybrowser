@testable import AnyBrowserCore
import Foundation
import Testing

// Uses debugging port 9306.
@Suite(.serialized)
struct CookieEngineTests {
    @Test(
        "Cookies move in and out of a running Profile",
        .enabled(
            if: testAppPath != nil,
            "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test."
        )
    )
    @MainActor
    func importsAndExportsCookies() async throws {
        let engine = try testEngine()
        let directory = try scratchDirectory("cookies")
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try await LoopbackPage.start(title: "AnyBrowser cookie fixture")
        defer { page.listener.cancel() }
        let host = try #require(page.url.host)
        let store = try ProfileStore(directory: directory)
        var profile = try store.makeDraft()
        profile.port = testPort(9306)
        profile.proxy = ""
        try store.save(profile)

        let runtime = BrowserRuntime(engine: engine, storage: store.directory)
        try await runtime.start(profile)
        do {
            let endpoint = try #require(await runtime.devToolsEndpoint(for: profile.id))
            let expiry = Int(Date().timeIntervalSince1970) + 3600
            // The browser refuses the third name, which costs only that cookie. It would accept and then drop
            // the last one (SameSite=None without Secure), so that one is skipped before the import.
            let file = """
            [
              {"name": "visible", "value": "one", "domain": "\(host)", "path": "/", "expires": -1,
               "httpOnly": false, "secure": false},
              {"name": "hidden", "value": "two", "domain": "\(host)", "hostOnly": true, "path": "/",
               "expirationDate": \(expiry), "httpOnly": true, "secure": false, "sameSite": "lax", "session": false},
              {"name": "bad;name", "value": "three", "domain": "\(host)"},
              {"name": "", "value": "four", "domain": "\(host)"},
              {"name": "loose", "value": "five", "domain": "\(host)", "sameSite": "no_restriction", "secure": false}
            ]
            """
            let first = try await CookieTransfer.importCookies(Data(file.utf8), into: endpoint)
            #expect(first.imported == 2)
            #expect(first.skipped == 3)

            let tab = try await DevToolsPage.open(port: profile.port, url: page.url)
            defer { tab.socket.cancel(with: .normalClosure, reason: nil) }
            #expect(try await documentCookies(tab) == ["visible=one"])

            // Importing keeps the cookies already there and replaces one with the same name.
            _ = try await tab.evaluate("document.cookie = 'page=set; path=/'")
            let again = Data(#"[{"name": "visible", "value": "again", "domain": "\#(host)"}]"#.utf8)
            let second = try await CookieTransfer.importCookies(again, into: endpoint)
            #expect(second.imported == 1)
            #expect(second.skipped == 0)
            try await tab.navigate(to: page.url)
            #expect(try await documentCookies(tab) == ["visible=again", "page=set"])

            let export = try await CookieTransfer.exportCookies(from: endpoint)
            let exported = try CookieTransfer.decode(export.data, now: Date()).cookies
            #expect(export.count == exported.count)
            let local = exported.filter { $0.domain == host }.sorted { $0.name < $1.name }
            #expect(local == [
                BrowserCookie(name: "hidden", value: "two", domain: host, path: "/", expires: Double(expiry),
                              httpOnly: true, secure: false, sameSite: .lax),
                BrowserCookie(name: "page", value: "set", domain: host, path: "/", expires: nil,
                              httpOnly: false, secure: false, sameSite: nil),
                BrowserCookie(name: "visible", value: "again", domain: host, path: "/", expires: nil,
                              httpOnly: false, secure: false, sameSite: nil),
            ])
            try await runtime.stop(profile.id)
        } catch {
            try? await runtime.stop(profile.id)
            throw error
        }
    }

    @Test(
        "Partitioned cookies round-trip, other tools' files import, and evictions are counted",
        .enabled(
            if: testAppPath != nil,
            "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test."
        )
    )
    @MainActor
    func importsOtherFormatsAndPartitions() async throws {
        let engine = try testEngine()
        let directory = try scratchDirectory("cookie-formats")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        var profile = try store.makeDraft()
        profile.port = testPort(9306)
        profile.proxy = ""
        try store.save(profile)

        let runtime = BrowserRuntime(engine: engine, storage: store.directory)
        try await runtime.start(profile)
        do {
            let endpoint = try #require(await runtime.devToolsEndpoint(for: profile.id))
            let client = try DevToolsClient(endpoint: endpoint)
            defer { client.close() }
            let expiry = Int(Date().timeIntervalSince1970) + 3600
            let shop = "https://shop.example.com"
            // Chromium keeps the partition as a site: scheme and registrable domain.
            let site = "https://example.com"

            // Cookie-Editor's JSON array, with a CHIPS cookie and a session cookie written as expiry 0.
            let editor = """
            [{"domain": "widget.example.com", "hostOnly": true, "name": "chips", "value": "1", "path": "/",
              "secure": true, "sameSite": "no_restriction", "session": true, "storeId": "0",
              "partitionKey": {"topLevelSite": "\(shop)", "hasCrossSiteAncestor": false}},
             {"domain": ".example.com", "hostOnly": false, "name": "editor", "value": "2", "path": "/",
              "expirationDate": 0, "secure": false, "sameSite": "lax"}]
            """
            #expect(try await CookieTransfer.importCookies(Data(editor.utf8), into: endpoint)
                == CookieTransfer.ImportResult(imported: 2, skipped: 0))
            // Playwright's storage state.
            let playwright = """
            {"cookies": [{"name": "playwright", "value": "3", "domain": "app.example.org", "path": "/x",
                          "expires": \(expiry), "httpOnly": true, "secure": true, "sameSite": "Strict"}], "origins": []}
            """
            #expect(try await CookieTransfer.importCookies(Data(playwright.utf8), into: endpoint).imported == 1)
            // A Netscape cookies.txt.
            let netscape = "# Netscape HTTP Cookie File\n.netscape.example.net\tTRUE\t/\tFALSE\t\(expiry)\tnetscape\t4\n"
                + "#HttpOnly_host.example.net\tFALSE\t/\tFALSE\t0\thidden\t5\n"
            #expect(try await CookieTransfer.importCookies(Data(netscape.utf8), into: endpoint).imported == 2)

            let stored = try await browserCookies(client)
            let chips = try #require(stored["chips"])
            #expect((chips["partitionKey"] as? [String: Any])?["topLevelSite"] as? String == site)
            #expect(stored["editor"]?["domain"] as? String == ".example.com" && stored["editor"]?["session"] as? Bool == true)
            #expect(stored["playwright"]?["httpOnly"] as? Bool == true && stored["playwright"]?["sameSite"] as? String == "Strict")
            #expect(stored["playwright"]?["expires"] as? Double == Double(expiry))
            #expect(stored["netscape"]?["domain"] as? String == ".netscape.example.net")
            #expect(stored["hidden"]?["domain"] as? String == "host.example.net" && stored["hidden"]?["httpOnly"] as? Bool == true)

            // Out and back in, the partitioned cookie keeps its partition.
            let export = try await CookieTransfer.exportCookies(from: endpoint)
            #expect(export.count == 5 && export.skipped == 0)
            _ = try await client.send("Storage.clearCookies")
            #expect(try await browserCookies(client).isEmpty)
            #expect(try await CookieTransfer.importCookies(export.data, into: endpoint)
                == CookieTransfer.ImportResult(imported: 5, skipped: 0))
            let restored = try await browserCookies(client)
            #expect(Set(restored.keys) == ["chips", "editor", "playwright", "netscape", "hidden"])
            #expect((restored["chips"]?["partitionKey"] as? [String: Any])?["topLevelSite"] as? String == site)

            // Chromium keeps at most 180 cookies per site; the import says how many it dropped.
            let many = try JSONSerialization.data(withJSONObject: (0..<200).map {
                ["name": "c\($0)", "value": "\($0)", "domain": "evict.example.edu", "expirationDate": expiry] as [String: Any]
            })
            let crowded = try await CookieTransfer.importCookies(many, into: endpoint)
            let kept = try await client.send("Storage.getCookies")["cookies"] as? [[String: Any]] ?? []
            #expect(crowded.evicted > 0 && crowded.imported + crowded.evicted == 200, "\(crowded)")
            #expect(kept.filter { $0["domain"] as? String == "evict.example.edu" }.count == crowded.imported)
            #expect(crowded.displaced == 0)
            try await runtime.stop(profile.id)
        } catch {
            try? await runtime.stop(profile.id)
            throw error
        }
    }

    /// The Profile's cookies by name.
    private func browserCookies(_ client: DevToolsClient) async throws -> [String: [String: Any]] {
        let cookies = try await client.send("Storage.getCookies")["cookies"] as? [[String: Any]] ?? []
        return Dictionary(cookies.compactMap { cookie in (cookie["name"] as? String).map { ($0, cookie) } }) { first, _ in first }
    }

    private func documentCookies(_ page: DevToolsPage) async throws -> Set<String> {
        let value = try #require(try await page.evaluate("document.cookie") as? String)
        return Set(value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) })
    }
}
