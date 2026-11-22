import AppKit
import Foundation

/// Tiles the windows of running Profiles in a grid. It goes through each browser's DevTools
/// endpoint (`Browser.setWindowBounds`), so AnyBrowser needs no Accessibility permission.
public enum WindowArrangement {
    /// A window rectangle in Chromium's screen coordinates: points, with the origin at the top
    /// left of the main display and y growing downwards. AppKit puts the origin at the bottom
    /// left; `visibleArea(of:)` converts.
    public struct Frame: Equatable, Sendable {
        public var left: Int
        public var top: Int
        public var width: Int
        public var height: Int

        public init(left: Int, top: Int, width: Int, height: Int) {
            self.left = left
            self.top = top
            self.width = width
            self.height = height
        }
    }

    /// What happened to one Profile's window.
    public struct Outcome: Equatable, Sendable {
        public var id: UUID
        /// The cell the window was given; nil when it got none, as for a Profile that is not running.
        public var frame: Frame?
        /// Why the window was not moved there; nil when it was.
        public var failure: String?

        public init(id: UUID, frame: Frame?, failure: String? = nil) {
            self.id = id
            self.frame = frame
            self.failure = failure
        }
    }

    /// The columns used when none are given: the grid closest to a square, with as many columns
    /// as rows or one more (2 windows side by side, 3 or 4 in two rows, 5 or 6 in three columns).
    public static func defaultColumns(for count: Int) -> Int {
        var columns = 1
        while columns * columns < count { columns += 1 }
        return columns
    }

    /// Cells for `count` windows filling `area` row by row, left to right. `columns` defaults to
    /// `defaultColumns(for:)` and is kept within 1...count. Cells touch, and the rounding is spread
    /// so the last column and row end exactly at the area's edges.
    public static func grid(count: Int, in area: Frame, columns: Int? = nil) -> [Frame] {
        guard count > 0 else { return [] }
        let columns = min(max(columns ?? defaultColumns(for: count), 1), count)
        let rows = (count + columns - 1) / columns
        let width = max(area.width, 0)
        let height = max(area.height, 0)
        return (0..<count).map { index in
            let column = index % columns
            let row = index / columns
            let left = area.left + width * column / columns
            let right = area.left + width * (column + 1) / columns
            let top = area.top + height * row / rows
            let bottom = area.top + height * (row + 1) / rows
            return Frame(left: left, top: top, width: right - left, height: bottom - top)
        }
    }

    /// `rect` in AppKit's screen coordinates, such as `NSScreen.visibleFrame`, as a Chromium frame.
    /// Both measure from the main display (`NSScreen.screens[0]`), AppKit up from its bottom edge
    /// and Chromium down from its top edge, so only y changes.
    public static func frame(fromScreenRect rect: CGRect, mainDisplayHeight: CGFloat) -> Frame {
        Frame(left: Int(rect.minX.rounded()), top: Int((mainDisplayHeight - rect.maxY).rounded()),
              width: Int(rect.width.rounded()), height: Int(rect.height.rounded()))
    }

    /// The part of `screen` that windows can use, below the menu bar and beside the Dock.
    @MainActor
    public static func visibleArea(of screen: NSScreen) -> Frame {
        let main = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return frame(fromScreenRect: screen.visibleFrame, mainDisplayHeight: main)
    }

    /// Moves one window of each browser into its cell of `grid(count:in:columns:)`, in the order
    /// given. A minimized, maximized or full-screen window is returned to normal first. Outcomes
    /// come back in the same order; a browser that fails leaves the others alone.
    public static func arrange(_ windows: [(id: UUID, endpoint: URL)], in area: Frame,
                               columns: Int? = nil) async -> [Outcome] {
        let frames = grid(count: windows.count, in: area, columns: columns)
        return await withTaskGroup(of: (Int, Outcome).self) { group in
            for (index, window) in windows.enumerated() {
                let frame = frames[index]
                group.addTask {
                    do {
                        try await place(window.endpoint, at: frame)
                        return (index, Outcome(id: window.id, frame: frame))
                    } catch {
                        return (index, Outcome(id: window.id, frame: frame, failure: error.localizedDescription))
                    }
                }
            }
            var outcomes = [Outcome?](repeating: nil, count: windows.count)
            for await (index, outcome) in group { outcomes[index] = outcome }
            return outcomes.compactMap { $0 }
        }
    }

    private static func place(_ endpoint: URL, at frame: Frame) async throws {
        let client = try DevToolsClient(endpoint: endpoint)
        defer { client.close() }
        let window = try await firstWindow(client)
        if window.state != "normal" {
            // Chromium refuses a position together with another state, so the state goes first.
            _ = try await client.send("Browser.setWindowBounds",
                                      ["windowId": window.id, "bounds": ["windowState": "normal"]])
            try await waitUntilNormal(window.id, client)
        }
        _ = try await client.send("Browser.setWindowBounds", [
            "windowId": window.id,
            "bounds": ["left": frame.left, "top": frame.top, "width": frame.width, "height": frame.height],
        ])
    }

    /// The window of the first page that has one. Extension pages such as offscreen documents are
    /// pages without a window and are passed over.
    private static func firstWindow(_ client: DevToolsClient) async throws -> (id: Int, state: String) {
        let targets = try await client.send("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
        for target in targets where target["type"] as? String == "page" {
            guard let targetId = target["targetId"] as? String else { continue }
            let reply: [String: Any]
            do {
                reply = try await client.send("Browser.getWindowForTarget", ["targetId": targetId])
            } catch is DevToolsCommandError {
                continue
            }
            guard let id = reply["windowId"] as? Int else { continue }
            return (id, (reply["bounds"] as? [String: Any])?["windowState"] as? String ?? "normal")
        }
        throw ProfileError.invalid("浏览器没有打开的窗口。")
    }

    /// Leaving full screen or the Dock is animated, and bounds set before it ends are lost.
    private static func waitUntilNormal(_ id: Int, _ client: DevToolsClient) async throws {
        for _ in 0..<50 {
            let bounds = try await client.send("Browser.getWindowBounds", ["windowId": id])["bounds"] as? [String: Any]
            if bounds?["windowState"] as? String == "normal" { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ProfileError.invalid("窗口没有退出最小化或全屏状态。")
    }
}

extension BrowserRuntime {
    /// Tiles the windows of the Profiles in `ids` with `WindowArrangement.arrange`. Only browsers
    /// running with a window take a cell; the others are reported with the reason and no frame.
    public func arrangeWindows(_ ids: [UUID], in area: WindowArrangement.Frame,
                               columns: Int? = nil) async -> [WindowArrangement.Outcome] {
        var order: [UUID] = []
        var windows: [(id: UUID, endpoint: URL)] = []
        var unplaced: [UUID: String] = [:]
        for id in ids where !order.contains(id) {
            order.append(id)
            guard case let .running(pid, _, _) = status(for: id), let endpoint = await devToolsEndpoint(for: id) else {
                unplaced[id] = "浏览器没有运行，或调试端口尚未就绪。"
                continue
            }
            // A headless browser has windows nobody sees; it would leave a gap in the grid.
            if ProcessInspection.arguments(pid)?.contains(where: { $0.hasPrefix("--headless") }) == true {
                unplaced[id] = "浏览器以无窗口模式运行。"
                continue
            }
            windows.append((id, endpoint))
        }
        let placed = await WindowArrangement.arrange(windows, in: area, columns: columns)
        return order.map { id in
            placed.first { $0.id == id } ?? WindowArrangement.Outcome(id: id, frame: nil, failure: unplaced[id])
        }
    }
}
