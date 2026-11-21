import AnyBrowserCore
import Combine
import SwiftUI

/// Sidebar search, grouping, sorting and multi-selection.
@MainActor
final class LibraryModel: ObservableObject {}

extension Workbench {
    func cloneSelected() {}
    func importProfiles() {}
    func exportProfiles(includeSecrets: Bool) {}
}

/// Creates several Profiles at once.
struct BatchCreateSheet: View {
    @ObservedObject var workbench: Workbench

    var body: some View {
        EmptyView()
    }
}
