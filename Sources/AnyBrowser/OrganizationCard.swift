import AnyBrowserCore
import SwiftUI

/// Group and notes.
struct OrganizationCard: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench

    var body: some View {
        EmptyView()
    }
}
