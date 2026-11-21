import AnyBrowserCore
import Combine
import SwiftUI

/// The local automation API's lifecycle and settings.
@MainActor
final class AutomationController: ObservableObject {
    func attach(to workbench: Workbench) {}
}

/// Settings for the local automation API.
struct AutomationSettings: View {
    @ObservedObject var workbench: Workbench

    var body: some View {
        EmptyView()
    }
}
