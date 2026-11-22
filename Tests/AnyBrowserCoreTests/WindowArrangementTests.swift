@testable import AnyBrowserCore
import AppKit
import Foundation
import Testing

private typealias Frame = WindowArrangement.Frame

struct WindowArrangementTests {
    @Test("Without a column count the grid is the one closest to a square")
    func defaultColumns() {
        #expect([0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 16, 17].map(WindowArrangement.defaultColumns) == [1, 1, 2, 2, 2, 3, 3, 3, 3, 4, 4, 5])
    }

    @Test("Cells fill the area row by row and end exactly at its edges")
    func gridFillsTheArea() {
        let area = Frame(left: 0, top: 25, width: 1000, height: 800)
        #expect(WindowArrangement.grid(count: 2, in: area) == [
            Frame(left: 0, top: 25, width: 500, height: 800),
            Frame(left: 500, top: 25, width: 500, height: 800),
        ])
        // Three windows use two rows; the last row is not stretched over the empty cell.
        #expect(WindowArrangement.grid(count: 3, in: area) == [
            Frame(left: 0, top: 25, width: 500, height: 400),
            Frame(left: 500, top: 25, width: 500, height: 400),
            Frame(left: 0, top: 425, width: 500, height: 400),
        ])
        // Rounding is spread over the cells, so they touch and the last one ends at the edge.
        let uneven = WindowArrangement.grid(count: 3, in: Frame(left: -1001, top: 0, width: 1001, height: 601), columns: 3)
        #expect(uneven.map(\.left) == [-1001, -668, -334])
        #expect(uneven.map(\.width) == [333, 334, 334])
        #expect(uneven.allSatisfy { $0.height == 601 })
        #expect(WindowArrangement.grid(count: 0, in: area).isEmpty)
    }

    @Test("A given column count is kept within one and the number of windows")
    func columnsAreBounded() {
        let area = Frame(left: 10, top: 20, width: 1200, height: 600)
        #expect(WindowArrangement.grid(count: 4, in: area, columns: 4).map(\.top) == [20, 20, 20, 20])
        #expect(WindowArrangement.grid(count: 2, in: area, columns: 10) == WindowArrangement.grid(count: 2, in: area, columns: 2))
        let column = WindowArrangement.grid(count: 3, in: area, columns: 0)
        #expect(column == [
            Frame(left: 10, top: 20, width: 1200, height: 200),
            Frame(left: 10, top: 220, width: 1200, height: 200),
            Frame(left: 10, top: 420, width: 1200, height: 200),
        ])
    }

    @Test("AppKit screen rectangles turn into Chromium's top-left coordinates")
    func screenCoordinates() {
        // The main display's visible frame, above a 70 pt Dock and below a 37 pt menu bar.
        #expect(WindowArrangement.frame(fromScreenRect: CGRect(x: 0, y: 70, width: 1512, height: 875), mainDisplayHeight: 982)
            == Frame(left: 0, top: 37, width: 1512, height: 875))
        // A display placed above and to the left of the main one.
        #expect(WindowArrangement.frame(fromScreenRect: CGRect(x: -1920, y: 982, width: 1920, height: 1080), mainDisplayHeight: 982)
            == Frame(left: -1920, top: -1080, width: 1920, height: 1080))
    }

    @Test("Browsers that cannot be reached fail one by one, in the order given")
    func failuresAreReportedPerProfile() async throws {
        let first = UUID()
        let second = UUID()
        // Only this Mac's browser endpoints are accepted.
        let foreign = try #require(URL(string: "ws://192.0.2.1:9222/devtools/browser/abc"))
        let closed = try #require(URL(string: "ws://127.0.0.1:17499/devtools/browser/abc"))
        let area = Frame(left: 0, top: 0, width: 800, height: 600)
        let outcomes = await WindowArrangement.arrange([(first, foreign), (second, closed)], in: area)
        #expect(outcomes.map(\.id) == [first, second])
        #expect(outcomes.map(\.frame) == WindowArrangement.grid(count: 2, in: area))
        #expect(outcomes[0].failure == "只能连接本机浏览器的调试地址。")
        #expect(outcomes[1].failure != nil)
    }

    @Test("Profiles that are not running get no cell")
    @MainActor
    func stoppedProfilesTakeNoCell() async throws {
        let directory = try scratchDirectory("tile-stopped")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = BrowserEngine(version: "test", executable: URL(fileURLWithPath: "/bin/true"),
                                   passkeyBoxDirectory: directory)
        let runtime = BrowserRuntime(engine: engine, storage: directory)
        let id = UUID()
        let outcomes = await runtime.arrangeWindows([id, id], in: Frame(left: 0, top: 0, width: 800, height: 600))
        #expect(outcomes == [WindowArrangement.Outcome(id: id, frame: nil, failure: "浏览器没有运行，或调试端口尚未就绪。")])
    }
}

// Uses debugging ports 9350 and 9351.
@Suite(.serialized)
struct WindowArrangementEngineTests {
    @Test(
        "Two Profiles' windows are tiled side by side, a minimized one restored first",
        .enabled(
            if: testAppPath != nil,
            "Set ANYBROWSER_TEST_APP to a packaged AnyBrowser.app to run the local browser test."
        )
    )
    @MainActor
    func tilesTwoWindows() async throws {
        let engine = try testEngine()
        let directory = try scratchDirectory("tile")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        var profiles: [BrowserProfile] = []
        for port in [testPort(9350), testPort(9351)] {
            var profile = try store.makeDraft()
            profile.port = port
            profile.proxy = ""
            try store.save(profile)
            profiles.append(profile)
        }
        let runtime = BrowserRuntime(engine: engine, storage: store.directory)
        do {
            for profile in profiles { try await runtime.start(profile) }
            let minimized = try await Window.first(of: profiles[1], in: runtime)
            defer { minimized.client.close() }
            _ = try await minimized.client.send("Browser.setWindowBounds",
                                                ["windowId": minimized.id, "bounds": ["windowState": "minimized"]])
            try await minimized.wait { $0["windowState"] as? String == "minimized" }

            let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
            let area = WindowArrangement.visibleArea(of: screen)
            let outcomes = await runtime.arrangeWindows(profiles.map(\.id), in: area)
            let expected = WindowArrangement.grid(count: 2, in: area)
            #expect(outcomes == zip(profiles, expected).map { WindowArrangement.Outcome(id: $0.id, frame: $1) })
            for (profile, frame) in zip(profiles, expected) {
                let window = try await Window.first(of: profile, in: runtime)
                defer { window.client.close() }
                let bounds = try await window.bounds()
                #expect(bounds["windowState"] as? String == "normal")
                #expect(Frame(left: bounds["left"] as? Int ?? -1, top: bounds["top"] as? Int ?? -1,
                              width: bounds["width"] as? Int ?? -1, height: bounds["height"] as? Int ?? -1) == frame)
            }
            for profile in profiles { try await runtime.stop(profile.id) }
        } catch {
            for profile in profiles { try? await runtime.stop(profile.id) }
            throw error
        }
    }

    /// The window of a Profile's first page, read over its own DevTools connection.
    private struct Window {
        let client: DevToolsClient
        let id: Int

        @MainActor
        static func first(of profile: BrowserProfile, in runtime: BrowserRuntime) async throws -> Window {
            let client = try DevToolsClient(endpoint: try #require(await runtime.devToolsEndpoint(for: profile.id)))
            let targets = try await client.send("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
            let page = try #require(targets.first { $0["type"] as? String == "page" }?["targetId"] as? String)
            let window = try await client.send("Browser.getWindowForTarget", ["targetId": page])
            return Window(client: client, id: try #require(window["windowId"] as? Int))
        }

        func bounds() async throws -> [String: Any] {
            try #require(try await client.send("Browser.getWindowBounds", ["windowId": id])["bounds"] as? [String: Any])
        }

        func wait(until condition: ([String: Any]) -> Bool) async throws {
            for _ in 0..<50 {
                if condition(try await bounds()) { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw VerificationFailure.message("The window did not reach the expected state")
        }
    }
}
