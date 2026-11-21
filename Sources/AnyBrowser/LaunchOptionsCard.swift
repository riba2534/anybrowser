import AnyBrowserCore
import SwiftUI

/// Start pages, window placement and extra extensions.
struct LaunchOptionsCard: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench

    var body: some View {
        EmptyView()
    }
}
