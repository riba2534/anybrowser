import AnyBrowserCore
import SwiftUI

/// The Passkey Box account this Profile signs in with.
struct IdentityCard: View {
    @Binding var draft: ProfileDraft
    @ObservedObject var workbench: Workbench

    var body: some View {
        EmptyView()
    }
}
