@testable import AnyBrowserCore
import Foundation
import Testing

// Uses debugging port 9306.
@Suite(.serialized)
struct CookieEngineTests {
    @Test(
        "Cookies move in and out of a running Profile",
        .enabled(
            if: ProcessInfo.processInfo.environment["ANYBROWSER_TEST_APP"] != nil,
            "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test."
        )
    )
    @MainActor
    func importsAndExportsCookies() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ANYBROWSER_TEST_APP"])
        let engine = try BrowserEngine.bundled(in: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anybrowser-cookies-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try await LoopbackPage.start(title: "AnyBrowser cookie fixture")
        defer { page.listener.cancel() }
        let host = try #require(page.url.host)
        let store = try ProfileStore(directory: directory)
        var profile = try store.makeDraft()
        profile.port = 9306
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

    private func documentCookies(_ page: DevToolsPage) async throws -> Set<String> {
        let value = try #require(try await page.evaluate("document.cookie") as? String)
        return Set(value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) })
    }
}
