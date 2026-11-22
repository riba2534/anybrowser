import AnyBrowserCore
import SwiftUI

/// Group, tags, account status and notes.
struct OrganizationCard: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench

    var body: some View {
        WorkbenchCard {
            CardHeading(title: "分组与备注", icon: "folder")
            LazyVGrid(columns: EditorInput.columns, alignment: .leading, spacing: 12) {
                GroupField(text: $draft.profile.group, groups: workbench.profileGroups)
                EditorPicker(title: "账号状态", identifier: "profile-account-status",
                             selection: $draft.profile.accountStatus,
                             choices: [(nil, "未设置")] + AccountStatus.allCases.map { (Optional($0), $0.title) })
            }
            TagEditor(tags: $draft.profile.tags, suggestions: suggestions)
            VStack(alignment: .leading, spacing: 6) {
                Text("备注")
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
                TextEditor(text: $draft.profile.notes)
                    .font(.system(size: 13))
                    .frame(height: 72)
                    .editorBorder()
                    .accessibilityLabel("备注")
                    .accessibilityIdentifier("profile-notes")
            }
        }
    }

    /// Tags other Profiles use, for picking instead of typing.
    private var suggestions: [String] {
        var seen: [String] = []
        for tag in workbench.profiles.flatMap(\.tags)
        where !seen.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            seen.append(tag)
        }
        return seen.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Labels for search (`tag:`) and batch actions: typed one at a time, or picked from the ones in use.
private struct TagEditor: View {
    @Binding var tags: [String]
    let suggestions: [String]
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标签")
                .font(.system(size: 12, weight: .medium))
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                TextField("标签", text: $text,
                          prompt: Text(tags.isEmpty ? "输入标签后按回车，多个用逗号分隔" : "添加标签").foregroundColor(WorkbenchPalette.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit(add)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .fieldSurface(focused: focused)
                    .accessibilityIdentifier("profile-tag-input")
                Menu {
                    ForEach(available, id: \.self) { tag in
                        Button(tag) { insert([tag]) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 34, height: 34)
                .fieldSurface()
                .disabled(available.isEmpty)
                .help("选择其他 Profile 用过的标签")
                .accessibilityLabel("选择已有标签")
                .accessibilityIdentifier("profile-tag-menu")
            }
            if !tags.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90, maximum: 220), spacing: 6, alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        chip(tag)
                    }
                }
            }
            if let error {
                ErrorLabel(error)
            }
        }
        .onChange(of: text) { _ in error = nil }
    }

    private var available: [String] {
        suggestions.filter { tag in !tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    }

    private func chip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                tags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除标签 \(tag)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(WorkbenchPalette.iconSurface, in: Capsule())
        .help(tag)
        .accessibilityIdentifier("profile-tag-\(tag)")
    }

    private func add() {
        let typed = text.split(whereSeparator: { $0 == "," || $0 == "，" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !typed.isEmpty else { return }
        if insert(typed) { text = "" }
    }

    /// Adds the tags the way saving checks them; false with the reason shown when they do not fit.
    @discardableResult
    private func insert(_ new: [String]) -> Bool {
        do {
            tags = try BrowserProfile.validatedTags(tags + new)
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
