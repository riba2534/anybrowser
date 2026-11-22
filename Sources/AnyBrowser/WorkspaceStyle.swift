import AnyBrowserCore
import AppKit
import SwiftUI

enum WorkbenchPalette {
    static let workspace = adaptive(0xf8f9fa, 0x1b1c20)
    static let sidebar = adaptive(0xecedf0, 0x17181b)
    static let panel = adaptive(0xffffff, 0x23252a)
    static let field = adaptive(0xf7f8fa, 0x1c1e22)
    static let iconSurface = adaptive(0xe5e7eb, 0x30333a)
    static let selected = adaptive(0xf7f8fa, 0x282a30)
    static let ink = adaptive(0x1f242b, 0xeff0f2)
    static let muted = adaptive(0x59636f, 0xa5afba)
    static let rule = adaptive(0xdde0e5, 0x32353c)
    static let strongRule = adaptive(0xcdd2d9, 0x474e58)
    static let green = adaptive(0x1b795b, 0x6dc6a3)
    static let amber = adaptive(0x956116, 0xe4aa60)
    static let danger = adaptive(0xaf4038, 0xf18780)
    static let mint = Color(red: 0.50, green: 0.79, blue: 0.69)

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: Double((value >> 16) & 255) / 255,
                green: Double((value >> 8) & 255) / 255,
                blue: Double(value & 255) / 255,
                alpha: 1
            )
        })
    }
}

struct WorkbenchButtonStyle: ButtonStyle {
    enum Kind {
        case primary, neutral, quiet
    }

    var kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, kind: kind)
    }

    private struct Face: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        private let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

        var body: some View {
            let pressed = configuration.isPressed
            let shouldLift = enabled && hovered && !pressed
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(kind == .primary ? .white : WorkbenchPalette.ink)
                .padding(.horizontal, 13)
                .frame(minHeight: 34)
                .background {
                    if kind == .quiet {
                        shape.fill(WorkbenchPalette.iconSurface.opacity(pressed ? 0.95 : (hovered ? 0.5 : 0.18)))
                    } else {
                        shape
                            .fill(LinearGradient(colors: faceColors(pressed, shouldLift),
                                                 startPoint: .top, endPoint: .bottom))
                            .overlay {
                                shape.strokeBorder(kind == .primary ? Color.black.opacity(0.38) : WorkbenchPalette.strongRule, lineWidth: 1)
                            }
                            .overlay {
                                shape.inset(by: 1)
                                    .strokeBorder(
                                        LinearGradient(colors: [.white.opacity(pressed ? 0.02 : 0.18), .clear, .black.opacity(0.12)],
                                                       startPoint: .top, endPoint: .bottom),
                                        lineWidth: 1
                                    )
                            }
                            .shadow(color: .black.opacity(pressed ? 0.06 : 0.12), radius: 1, y: 1)
                            .shadow(color: .black.opacity(pressed ? 0.03 : 0.09), radius: shouldLift ? 4 : 2, y: shouldLift ? 2 : 1)
                    }
                }
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.52)
                .offset(y: pressed && !reduceMotion ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
                .onHover { hovered = $0 }
        }

        private func faceColors(_ pressed: Bool, _ lifted: Bool) -> [Color] {
            let top: Color
            let bottom: Color
            if kind == .primary {
                top = Color(white: lifted ? 0.31 : 0.27)
                bottom = Color(white: 0.18)
            } else {
                top = WorkbenchPalette.panel
                bottom = lifted ? WorkbenchPalette.selected : WorkbenchPalette.field
            }
            return pressed ? [bottom, top] : [top, bottom]
        }
    }
}

struct WorkbenchCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(WorkbenchPalette.panel)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(WorkbenchPalette.rule, lineWidth: 1)
                }
        }
    }
}

extension BrowserRunState {
    var statusTitle: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .stopping: return "停止中"
        case .running: return "运行中"
        case .failed: return "启动异常"
        }
    }

    var indicator: Color {
        switch self {
        case .stopped: return WorkbenchPalette.muted.opacity(0.65)
        case .starting, .stopping: return WorkbenchPalette.amber
        case .running: return WorkbenchPalette.green
        case .failed: return WorkbenchPalette.danger
        }
    }
}

extension View {
    /// The rounded surface and border every input field uses.
    func fieldSurface(focused: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return background(WorkbenchPalette.field, in: shape)
            .overlay { shape.strokeBorder(focused ? Color.accentColor : WorkbenchPalette.rule, lineWidth: 1) }
    }

    /// The rounded, bordered panel the lists in sheets sit in.
    func listPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return background(WorkbenchPalette.panel, in: shape)
            .overlay { shape.strokeBorder(WorkbenchPalette.rule, lineWidth: 1) }
    }

    /// The rounded border of a multi-line text editor.
    func editorBorder() -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return clipShape(shape).overlay { shape.strokeBorder(WorkbenchPalette.rule, lineWidth: 1) }
    }
}

extension Binding where Value == Bool {
    /// Whether `item` holds a value, for an alert or popover; dismissing it clears the value.
    init<Item>(showing item: Binding<Item?>) {
        self.init(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// An error shown inline in a form or sheet.
struct ErrorLabel: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.system(size: 12))
            .foregroundColor(WorkbenchPalette.danger)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// A settings sheet with a title and a caption above its content.
struct WorkbenchSheet<Content: View>: View {
    let title: String
    let caption: String
    let width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundColor(WorkbenchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(24)
        .frame(width: width)
        .background(WorkbenchPalette.workspace)
        .foregroundColor(WorkbenchPalette.ink)
    }
}
