import AppKit
import Foundation

// What the automation API needs from the coordinator beyond launches and the recycle bin, which
// it answers with the methods the window uses.
extension LaunchCoordinator {
    /// Uses the same lookup as identity generation, so tests and the window see one behaviour.
    public func lookUpExit(through proxy: String) async -> ProxyExit? {
        await exitLookup(proxy)
    }

    public func checkProxy(_ entry: ProxyEntry) async throws -> ProxyExit {
        guard let endpoint = entry.endpoint else { throw ProfileError.invalid("代理地址无效。") }
        return try await ProxyProbe.lookupExit(through: endpoint)
    }

    /// Tiles the windows on the main display, the one with the menu bar, below it and beside the Dock.
    public func arrangeWindows(_ ids: [UUID], columns: Int?) async throws -> [WindowArrangement.Outcome] {
        guard let screen = NSScreen.screens.first else { throw ProfileError.invalid("没有可用的显示器，无法排列窗口。") }
        let chosen = ids.compactMap { id in store.profiles.first { $0.id == id } }
        return await runtime.arrangeWindows(chosen, in: WindowArrangement.visibleArea(of: screen), columns: columns)
    }
}
