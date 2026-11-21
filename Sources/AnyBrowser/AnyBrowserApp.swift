import AnyBrowserCore
import AppKit
import Combine
import SwiftUI

@main
@MainActor
struct AnyBrowserApp: App {
    @StateObject private var workbench = Workbench()

    var body: some Scene {
        WindowGroup("AnyBrowser") {
            Workspace(workbench: workbench)
                .frame(minWidth: 880, idealWidth: 1080, minHeight: 620, idealHeight: 756)
                .task {
                    while !Task.isCancelled {
                        await workbench.refresh()
                        do {
                            try await Task.sleep(nanoseconds: 3_000_000_000)
                        } catch {
                            break
                        }
                    }
                }
        }
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
                    .disabled(workbench.store == nil)
            }
        }
    }
}
