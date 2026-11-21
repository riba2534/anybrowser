import AppKit
import UniformTypeIdentifiers

/// Panels for picking the JSON files Profiles and cookies are exported to and imported from.
enum FilePanels {
    static func saveLocation(title: String, prompt: String? = nil, message: String? = nil, name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        if let prompt { panel.prompt = prompt }
        if let message { panel.message = message }
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func file(title: String, prompt: String? = nil, message: String? = nil,
                     types: [UTType] = [.json]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        if let prompt { panel.prompt = prompt }
        if let message { panel.message = message }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
