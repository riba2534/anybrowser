import AnyBrowserCore
import AppKit
import Combine
import Darwin
import SwiftUI

@main
@MainActor
struct AnyBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workbench: Workbench

    init() {
        // One window: no tab bar to open a second one from, and no "Merge All Windows".
        NSWindow.allowsAutomaticWindowTabbing = false
        let instance = SingleInstance.claim()
        DatabaseRestore.performRequested(in: instance)
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
            LibraryCommands(workbench: workbench)
        }
    }
}

/// The menus. Items that write are disabled while the database is read-only.
private struct LibraryCommands: Commands {
    @ObservedObject var workbench: Workbench

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建 Profile") { workbench.request(.new) }
                .keyboardShortcut("n")
                .disabled(!workbench.canWrite)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Passkey Box 账号…") { workbench.showingPasskeyBox = true }
                .keyboardShortcut(",")
                .disabled(workbench.store == nil)
        }
        CommandGroup(after: .newItem) {
            Button("批量新建 Profile…") { workbench.showingBatchCreate = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!workbench.canWrite)
            Button("保存 Profile") { workbench.save() }
                .keyboardShortcut("s")
                .disabled(!workbench.hasChanges || !workbench.canWrite)
            Divider()
            Button("导入 Profile…") { workbench.importProfiles() }
                .disabled(!workbench.canWrite)
            Button("导出 Profile…") { workbench.exportProfiles(includeSecrets: false) }
                .disabled(workbench.profiles.isEmpty)
            Button("导出 Profile（含密码）…") { workbench.exportProfiles(includeSecrets: true) }
                .disabled(workbench.profiles.isEmpty)
            Divider()
            Button(workbench.batchSelection.isEmpty ? "导出完整备份…" : "导出所选的完整备份…") { workbench.requestFullBackup() }
                .disabled(workbench.coordinator == nil || workbench.profiles.isEmpty)
            Button("从完整备份恢复…") { workbench.requestFullRestore() }
                .disabled(workbench.coordinator == nil || !workbench.canWrite)
            Button("资料库备份…") { workbench.library.sheet = .databaseBackups }
        }
        CommandGroup(after: .appSettings) {
            Button("自动化接口…") { workbench.showingAutomation = true }
                .disabled(workbench.automation == nil)
        }
        CommandMenu("Profile") {
            let id = workbench.saved?.id
            let running = id.map { workbench.state(for: $0).isRunning } ?? false
            let busy = id.map(workbench.isBusy) ?? true
            Button(running ? "重启" : "启动") { Task { await workbench.launch(restart: running) } }
                .keyboardShortcut("r")
                .disabled(workbench.draft == nil || busy && id != nil || workbench.runtime == nil
                          || workbench.hasChanges && !workbench.canWrite)
            Button("停止") {
                if let id { Task { await workbench.stop(id) } }
            }
            .keyboardShortcut(".")
            .disabled(!running || busy)
            Button("复制为新 Profile") { workbench.request(.clone) }
                .keyboardShortcut("d")
                .disabled(id == nil || !workbench.canWrite)
            Divider()
            Button("查找 Profile") { workbench.library.searchFocusRequest += 1 }
                .keyboardShortcut("f")
            Button("选择列表中的全部 Profile") { workbench.selectAllVisible() }
                .disabled(workbench.profiles.isEmpty)
            Button(workbench.batchSelection.isEmpty ? "平铺全部窗口" : "平铺所选窗口") {
                Task { await workbench.tileWindows(workbench.batchSelection.isEmpty ? nil : workbench.batchSelection.map(\.id)) }
            }
            .disabled(workbench.runtime == nil)
            Divider()
            Button("代理库…") { workbench.library.sheet = .proxyLibrary }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(workbench.proxyLibrary == nil)
            Button("回收站…") { workbench.library.sheet = .trash }
                .disabled(workbench.store == nil)
            Button("资料库检查…") { workbench.library.sheet = .repair }
                .disabled(workbench.store == nil)
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
