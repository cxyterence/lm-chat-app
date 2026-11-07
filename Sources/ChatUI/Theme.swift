import SwiftUI

struct Palette: Sendable {
    var background: Color
    var groupedBackground: Color
    var surface: Color
    var fill: Color
    var text: Color
    var secondaryText: Color
    var accent: Color
    var onAccent: Color
    var success: Color
    var danger: Color
    var markup: Markup
}

struct Markup: Sendable {
    var heading: Color
    var strong: Color
    var emphasis: Color
    var code: Color
    var link: Color
    var quote: Color
    var marker: Color
}

enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark, dracula

    var id: String { rawValue }
    var name: String { spec.name }
    var subtitle: String { spec.subtitle }
    var colorScheme: ColorScheme? { spec.colorScheme }
    var palette: Palette { spec.palette }

    private struct Spec {
        var name: String
        var subtitle: String
        var colorScheme: ColorScheme?
        var palette: Palette
    }

    private var spec: Spec {
        switch self {
        case .system:
            Spec(name: "System", subtitle: "Follows device", colorScheme: nil, palette: .native)
        case .light:
            Spec(name: "Light", subtitle: "Light", colorScheme: .light, palette: .native)
        case .dark:
            Spec(name: "Dark", subtitle: "Dark", colorScheme: .dark, palette: .native)
        case .dracula:
            Spec(name: "Dracula", subtitle: "Dark", colorScheme: .dark, palette: Palette(
                background: Color(hex: 0x282A36),
                groupedBackground: Color(hex: 0x21222C),
                surface: Color(hex: 0x44475A),
                fill: Color(hex: 0x44475A),
                text: Color(hex: 0xF8F8F2),
                secondaryText: Color(hex: 0x6272A4),
                accent: Color(hex: 0xBD93F9),
                onAccent: Color(hex: 0x282A36),
                success: Color(hex: 0x50FA7B),
                danger: Color(hex: 0xFF5555),
                markup: Markup(
                    heading: Color(hex: 0xBD93F9),
                    strong: Color(hex: 0xFFB86C),
                    emphasis: Color(hex: 0xF1FA8C),
                    code: Color(hex: 0x50FA7B),
                    link: Color(hex: 0x8BE9FD),
                    quote: Color(hex: 0xF1FA8C),
                    marker: Color(hex: 0xFF79C6))))
        }
    }
}

extension Palette {
    static let native: Palette = {
        #if os(iOS)
        let text = Color(uiColor: .label), secondaryText = Color(uiColor: .secondaryLabel)
        return Palette(background: Color(uiColor: .systemBackground),
                       groupedBackground: Color(uiColor: .systemGroupedBackground),
                       surface: Color(uiColor: .secondarySystemGroupedBackground),
                       fill: Color(uiColor: .secondarySystemBackground),
                       text: text, secondaryText: secondaryText,
                       accent: .accentColor, onAccent: .white, success: .green, danger: .red,
                       markup: .plain(text: text, secondaryText: secondaryText))
        #else
        let text = Color(nsColor: .labelColor), secondaryText = Color(nsColor: .secondaryLabelColor)
        return Palette(background: Color(nsColor: .windowBackgroundColor),
                       groupedBackground: Color(nsColor: .underPageBackgroundColor),
                       surface: Color(nsColor: .controlBackgroundColor),
                       fill: Color(nsColor: .quaternaryLabelColor),
                       text: text, secondaryText: secondaryText,
                       accent: .accentColor, onAccent: .white, success: .green, danger: .red,
                       markup: .plain(text: text, secondaryText: secondaryText))
        #endif
    }()
}

extension Markup {
    static func plain(text: Color, secondaryText: Color) -> Markup {
        Markup(heading: text, strong: text, emphasis: text, code: text,
               link: .accentColor, quote: secondaryText, marker: secondaryText)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension EnvironmentValues {
    @Entry var palette = Palette.native
}

extension View {
    func theme(_ theme: Theme) -> some View {
        let palette = theme.palette
        return environment(\.palette, palette)
            .tint(palette.accent)
            .preferredColorScheme(theme.colorScheme)
    }

    func themedNavigationBar() -> some View { modifier(ThemedNavigationBar()) }
}

private struct ThemedNavigationBar: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbarBackground(palette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #else
        content
        #endif
    }
}
