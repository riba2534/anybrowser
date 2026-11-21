import AnyBrowserCore
import SwiftUI

/// Group and notes.
struct OrganizationCard: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        WorkbenchCard {
            CardHeading(title: "分组与备注", icon: "folder")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                GroupField(text: $draft.profile.group, groups: workbench.profileGroups)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("备注")
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
                TextEditor(text: $draft.profile.notes)
                    .font(.system(size: 13))
                    .frame(height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(WorkbenchPalette.rule, lineWidth: 1)
                    }
                    .accessibilityLabel("备注")
                    .accessibilityIdentifier("profile-notes")
            }
        }
    }
}
