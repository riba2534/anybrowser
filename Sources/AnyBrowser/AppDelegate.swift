import AppKit

/// Asks about unsaved edits before AnyBrowser quits, however the quit was asked for (⌘Q, the Dock,
/// logging out). Running browsers are not affected: they keep running and are taken over again.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The window's state. Set by the Workbench itself, which SwiftUI creates before the app
    /// finishes launching.
    static weak var workbench: Workbench?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workbench = Self.workbench, workbench.hasChanges, let draft = workbench.draft else { return .terminateNow }
        let name = draft.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = NSAlert()
        alert.messageText = workbench.isNewDraft ? "保存新建的 Profile？" : "保存对「\(name.isEmpty ? "未命名 Profile" : name)」的修改？"
        alert.informativeText = "退出后，尚未保存的修改将会丢失。正在运行的浏览器不受影响。"
        alert.addButton(withTitle: "保存并退出")
        let discard = alert.addButton(withTitle: "放弃修改")
        discard.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // A launch clears the old site data of a new identity before it starts, so the mark
            // saved here is enough; a failed save stays in the window with its message.
            return workbench.save(clearingSiteData: false) ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
