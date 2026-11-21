import AnyBrowserCore
import AppKit
import SwiftUI

struct Workspace: View {
    @ObservedObject var workbench: Workbench
    @State private var removeCandidate: BrowserProfile?
    private static let brandImage = Bundle.main.url(forResource: "AnyBrowser", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 228)
            Rectangle()
                .fill(WorkbenchPalette.rule)
                .frame(width: 1)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                if let draft = Binding($workbench.draft) {
                    profileHeader(draft.wrappedValue.profile)
                    Rectangle().fill(WorkbenchPalette.rule).frame(height: 1)
                    detail(draft)
                } else {
                    emptyWorkspace
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkbenchPalette.workspace)
        }
        .foregroundColor(WorkbenchPalette.ink)
        .alert("保存当前编辑？", isPresented: showNavigationAlert, presenting: workbench.pendingDestination) { destination in
            Button("保存并继续") { workbench.resolveNavigation(destination, saveChanges: true) }
            Button("放弃修改", role: .destructive) { workbench.resolveNavigation(destination, saveChanges: false) }
            Button("取消", role: .cancel) { workbench.pendingDestination = nil }
        } message: { _ in
            Text("当前 Profile 有尚未保存的修改。")
        }
        .sheet(isPresented: $workbench.showingPasskeyBox) {
            PasskeyBoxSettings(workbench: workbench)
        }
        .alert("移除 Profile？", isPresented: showRemovalAlert, presenting: removeCandidate) { candidate in
            Button("移除", role: .destructive) { workbench.remove(candidate.id) }
            Button("取消", role: .cancel) {}
        } message: { candidate in
            Text("「\(candidate.name)」将从列表移除。浏览器资料保留在本机。")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 20)
                .padding(.top, 48)
                .padding(.bottom, 26)
            HStack {
                Text("Profiles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(WorkbenchPalette.muted)
                Spacer()
                Text(workbench.profiles.count.formatted())
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(WorkbenchPalette.muted)
                    .accessibilityLabel("Profile 数量 \(workbench.profiles.count)")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(workbench.profiles) { profile in
                        profileRow(profile)
                    }
                    if let draft = workbench.draft, workbench.saved == nil {
                        profileRow(draft.profile, isDraft: true)
                    }
                }
                .padding(.horizontal, 12)
            }
            Button {
                workbench.request(.new)
            } label: {
                Label("新建 Profile", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(WorkbenchButtonStyle(.quiet))
            .disabled(workbench.store == nil)
            .accessibilityIdentifier("new-profile")
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Rectangle().fill(WorkbenchPalette.rule).frame(height: 1)
            VStack(spacing: 12) {
                passkeyBoxFootnote
                engineFootnote
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxHeight: .infinity)
        .background(WorkbenchPalette.sidebar)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            brandMark(size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("AnyBrowser")
                    .font(.system(size: 16, weight: .semibold))
                Text("浏览器工作台")
                    .font(.system(size: 11))
                    .foregroundColor(WorkbenchPalette.muted)
            }
        }
    }

    private func brandMark(size: CGFloat) -> some View {
        Group {
            if let image = Self.brandImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundColor(WorkbenchPalette.muted)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func profileRow(_ profile: BrowserProfile, isDraft: Bool = false) -> some View {
        let isSelected = profile.id == workbench.selectedID
        let state = workbench.state(for: profile.id)
        return Button {
            workbench.request(.profile(profile.id))
        } label: {
            HStack(spacing: 9) {
                Image(systemName: platformIcon(profile.fingerprint.platform))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(WorkbenchPalette.ink)
                    .frame(width: 30, height: 30)
                    .background(WorkbenchPalette.iconSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name.isEmpty ? "未命名 Profile" : profile.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(verbatim: isDraft ? "草稿" : "127.0.0.1:\(profile.port)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(WorkbenchPalette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(state.indicator)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(WorkbenchPalette.selected)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(WorkbenchPalette.strongRule, lineWidth: 1)
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("profile-row-\(profile.id.uuidString)")
        .help(profile.name)
    }

    private var passkeyBoxFootnote: some View {
        Button {
            workbench.showingPasskeyBox = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(workbench.passkeyBoxAccount == nil ? WorkbenchPalette.amber : WorkbenchPalette.green)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text("Passkey Box")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(workbench.passkeyBoxAccount?.username ?? "未设置账号")
                    .font(.system(size: 10))
                    .foregroundColor(WorkbenchPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(workbench.store == nil)
        .help("设置各 Profile 内置 Passkey Box 使用的账号")
        .accessibilityIdentifier("passkey-box-account")
    }

    private var engineFootnote: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(workbench.engineVersion == nil ? WorkbenchPalette.amber : WorkbenchPalette.green)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text("内置引擎")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(workbench.engineVersion ?? "不可用")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(WorkbenchPalette.muted)
                .lineLimit(1)
        }
    }

    private func profileHeader(_ value: BrowserProfile) -> some View {
        let state = workbench.state(for: value.id)
        let busy = workbench.isBusy(value.id)
        return HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(workbench.saved == nil ? "新建 Profile" : "Profile 设置")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WorkbenchPalette.muted)
                Text(value.name.isEmpty ? "未命名 Profile" : value.name)
                    .font(.system(size: 32, weight: .semibold))
                    .tracking(-0.8)
                    .lineLimit(1)
                    .help(value.name)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            if state.isRunning {
                Button {
                    Task { await workbench.stop(value.id) }
                } label: {
                    Label("停止", systemImage: "stop")
                }
                .buttonStyle(WorkbenchButtonStyle(.neutral))
                .disabled(busy)
                .accessibilityIdentifier("stop-profile")
                Button {
                    Task { await workbench.launch(restart: true) }
                } label: {
                    Label(workbench.hasChanges ? "保存并重启" : "重启", systemImage: "arrow.clockwise")
                }
                .buttonStyle(WorkbenchButtonStyle(.primary))
                .disabled(busy)
                .accessibilityIdentifier("restart-profile")
            } else {
                Button {
                    Task { await workbench.launch() }
                } label: {
                    Label(workbench.hasChanges ? "保存并启动" : "启动", systemImage: "play.fill")
                }
                .buttonStyle(WorkbenchButtonStyle(.primary))
                .disabled(busy || workbench.runtime == nil)
                .accessibilityIdentifier("launch-profile")
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .frame(maxWidth: 1000)
    }

    private func detail(_ draft: Binding<ProfileDraft>) -> some View {
        let id = draft.wrappedValue.profile.id
        let state = workbench.state(for: id)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = workbench.notice, !notice.isError || state != .failed(notice.text) {
                        message(notice.text, error: notice.isError, dismissible: true)
                    }
                    if let engineError = workbench.engineError {
                        message(engineError, error: true, dismissible: false)
                    }
                    ProfileEditor(
                        draft: draft,
                        state: state,
                        pendingRestart: workbench.hasPendingRestart(id),
                        copyAddress: workbench.copyAddress,
                        randomize: workbench.randomize
                    )
                    .id(id)
                    .disabled(workbench.isBusy(id))
                }
                .padding(28)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
            Rectangle().fill(WorkbenchPalette.rule).frame(height: 1)
            footer(draft.wrappedValue.profile)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .frame(maxWidth: 1000)
        }
    }

    private func footer(_ value: BrowserProfile) -> some View {
        HStack(spacing: 12) {
            if let saved = workbench.saved {
                Button {
                    removeCandidate = saved
                } label: {
                    Label("移除 Profile", systemImage: "trash")
                }
                .buttonStyle(WorkbenchButtonStyle(.quiet))
                .disabled(workbench.isBusy(value.id) || workbench.state(for: value.id).isRunning)
                .accessibilityIdentifier("remove-profile")
            }
            Spacer()
            Button {
                workbench.save()
            } label: {
                Text("保存")
            }
            .buttonStyle(WorkbenchButtonStyle(.neutral))
            .disabled(!workbench.hasChanges || workbench.isBusy(value.id))
            .accessibilityIdentifier("save-profile")
        }
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 14) {
            if let notice = workbench.notice {
                message(notice.text, error: notice.isError, dismissible: true)
            }
            if let engineError = workbench.engineError {
                message(engineError, error: true, dismissible: false)
            }
            Spacer()
            brandMark(size: 84)
            Text("新建浏览器 Profile")
                .font(.system(size: 26, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("每个 Profile 使用独立的浏览器资料、指纹设置和调试端口。")
                .font(.system(size: 13))
                .foregroundColor(WorkbenchPalette.muted)
                .multilineTextAlignment(.center)
            Button {
                workbench.request(.new)
            } label: {
                Label("新建 Profile", systemImage: "plus")
            }
            .buttonStyle(WorkbenchButtonStyle(.primary))
            .disabled(workbench.store == nil)
            .accessibilityIdentifier("create-first-profile")
            .padding(.top, 4)
            Spacer()
            Spacer(minLength: 24)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String, error: Bool, dismissible: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: error ? "exclamationmark.circle" : "info.circle")
                .foregroundColor(error ? WorkbenchPalette.danger : WorkbenchPalette.muted)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if dismissible {
                Button {
                    workbench.notice = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
        }
        .padding(12)
        .background(WorkbenchPalette.iconSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var showNavigationAlert: Binding<Bool> {
        Binding(
            get: { workbench.pendingDestination != nil },
            set: { showing in if !showing { workbench.pendingDestination = nil } }
        )
    }

    private var showRemovalAlert: Binding<Bool> {
        Binding(
            get: { removeCandidate != nil },
            set: { showing in if !showing { removeCandidate = nil } }
        )
    }

    private func platformIcon(_ platform: BrowserPlatform?) -> String {
        switch platform {
        case .macOS: return "laptopcomputer"
        case .windows: return "macwindow"
        case .linux: return "terminal"
        case nil: return "globe"
        }
    }
}
