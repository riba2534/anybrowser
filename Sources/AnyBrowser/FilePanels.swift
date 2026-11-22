import AppKit
import UniformTypeIdentifiers

/// Panels for picking the files Profiles, cookies and backups are exported to and imported from.
enum FilePanels {
    static func saveLocation(title: String, prompt: String? = nil, message: String? = nil, name: String,
                             types: [UTType] = [.json]) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        if let prompt { panel.prompt = prompt }
        if let message { panel.message = message }
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Today's date as exported file names carry it, e.g. 2026-01-31.
    static var today: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
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
