import AnyBrowserCore
import AppKit
import Combine
import Darwin
import SwiftUI

@main
@MainActor
struct AnyBrowserApp: App {
    @StateObject private var workbench: Workbench

    init() {
        // One window: no tab bar to open a second one from, and no "Merge All Windows".
        NSWindow.allowsAutomaticWindowTabbing = false
        let instance = SingleInstance.claim()
        _workbench = StateObject(wrappedValue: Workbench(instance: instance))
    }

    var body: some Scene {
        // `Window` would keep it to one, but needs macOS 13. Without File > New Window and the tab
        // bar, a second window only comes from external events, which this one takes instead.
        WindowGroup("AnyBrowser") {
            Workspace(workbench: workbench)
                .frame(minWidth: 880, idealWidth: 1080, minHeight: 620, idealHeight: 756)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建 Profile") { workbench.request(.new) }
                    .keyboardShortcut("n")
                    .disabled(workbench.store == nil)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Passkey Box 账号…") { workbench.showingPasskeyBox = true }
                    .keyboardShortcut(",")
                    .disabled(workbench.store == nil)
            }
            CommandGroup(after: .newItem) {
                Button("批量新建 Profile…") { workbench.showingBatchCreate = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(workbench.store == nil)
                Button("保存 Profile") { workbench.save() }
                    .keyboardShortcut("s")
                    .disabled(!workbench.hasChanges)
                Divider()
                Button("导入 Profile…") { workbench.importProfiles() }
                    .disabled(workbench.store == nil)
                Button("导出 Profile…") { workbench.exportProfiles(includeSecrets: false) }
                    .disabled(workbench.profiles.isEmpty)
                Button("导出 Profile（含密码）…") { workbench.exportProfiles(includeSecrets: true) }
                    .disabled(workbench.profiles.isEmpty)
            }
            CommandGroup(after: .appSettings) {
                Button("自动化接口…") { workbench.showingAutomation = true }
                    .disabled(workbench.automation == nil)
            }
        }
    }
}

/// One AnyBrowser per data directory: a second one would overwrite the first one's edits with its
/// own stale copy of the Profiles. Opening AnyBrowser again brings the running one forward.
@MainActor
enum SingleInstance {
    /// This process's hold on the data directory.
    struct Claim {
        var directory: URL
        var lock: InstanceLock?
        /// Why the directory could not be locked, when no running AnyBrowser was found to hand over to.
        var failure: String?
    }

    private static let activationRequest = Notification.Name("cn.riba2534.anybrowser.activate")

    /// Locks the data directory. When another AnyBrowser holds it, asks that one to come forward
    /// and exits. Nil when the directory cannot be located; opening the database reports why.
    static func claim() -> Claim? {
        guard let located = try? ProfileStore.defaultDirectory(),
              (try? FileManager.default.createDirectory(at: located, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil,
              let resolved = realpath(located.path, nil) else { return nil }
        // The lock wants the real path, as the database does: a folder in the path may be a link.
        let directory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        do {
            return Claim(directory: directory, lock: try ProfileStore.acquireInstanceLock(in: directory))
        } catch {
            if handOff(directory) { exit(0) }
            return Claim(directory: directory, failure: error.localizedDescription)
        }
    }

    /// Answers the requests of AnyBrowsers opened later on the same data directory.
    static func listen(_ directory: URL) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: activationRequest, object: directory.path,
                                                            queue: .main) { _ in
            Task { @MainActor in comeForward() }
        }
    }

    /// Asks the AnyBrowser holding `directory` to come forward; false when none was found.
    private static func handOff(_ directory: URL) -> Bool {
        guard let pid = holders(of: directory.appendingPathComponent(".instance.lock")).first,
              let other = NSRunningApplication(processIdentifier: pid) else { return false }
        DistributedNotificationCenter.default().postNotificationName(activationRequest, object: directory.path,
                                                                     userInfo: nil, deliverImmediately: true)
        if #available(macOS 14, *) {
            NSApplication.shared.yieldActivation(to: other)
            other.activate(options: [.activateAllWindows])
        } else {
            other.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        return true
    }

    /// Other processes that have `file` open. Only an AnyBrowser opens the lock file, and its
    /// browsers do not inherit it.
    private static func holders(of file: URL) -> [Int32] {
        var pids = [Int32](repeating: 0, count: 64)
        let size = Int32(pids.count * MemoryLayout<Int32>.stride)
        let bytes = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, file.path, UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY),
                                      &pids, size)
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<Int32>.stride).filter { $0 > 0 && $0 != getpid() }
    }

    private static func comeForward() {
        if #available(macOS 14, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        // What a click on the Dock icon does: the window comes back if it was closed or minimized.
        let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                            transactionID: AETransactionID(kAnyTransactionID))
        _ = try? reopen.sendEvent(options: [.noReply], timeout: 2)
    }
}
