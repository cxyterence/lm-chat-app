import Foundation
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
    /// Buttons and other tinted controls. Defaults to the accent; a theme whose accent is too faint to read
    /// as text (Shoko, Vaporwave) supplies a readable one.
    var tint: Color? = nil
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
    case system, light, dark
    case dracula, modernInk, dmg, shoko, vaporwave, nightRunner, miamiNights, olivia

    /// The Appearance page shows each group under its own tab.
    enum Group: String, CaseIterable, Identifiable {
        case system, presets

        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    var id: String { rawValue }
    var name: String { spec.name }
    var colorScheme: ColorScheme? { spec.colorScheme }
    var palette: Palette { spec.palette }
    var group: Group { [.system, .light, .dark].contains(self) ? .system : .presets }

    private struct Spec {
        var name: String
        var colorScheme: ColorScheme?
        var palette: Palette

        init(name: String, colorScheme: ColorScheme?, palette: Palette) {
            self.name = name
            self.colorScheme = colorScheme
            self.palette = palette
        }

        init(name: String, _ colors: MonkeytypeColors) {
            self.init(name: name, colorScheme: colors.isDark ? .dark : .light, palette: Palette(colors))
        }
    }

    private var spec: Spec {
        switch self {
        case .system:
            Spec(name: "System", colorScheme: nil, palette: .native)
        case .light:
            Spec(name: "Light", colorScheme: .light, palette: .native)
        case .dark:
            Spec(name: "Dark", colorScheme: .dark, palette: .native)
        case .modernInk, .dmg, .shoko, .vaporwave, .nightRunner, .miamiNights, .olivia:
            Spec(name: MonkeytypeColors.presets[self]!.name, MonkeytypeColors.presets[self]!.colors)
        case .dracula:
            Spec(name: "Dracula", colorScheme: .dark, palette: Palette(
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

/// A Monkeytype theme's colours, from monkeytype's frontend/src/ts/constants/themes.ts.
struct MonkeytypeColors: Equatable {
    var bg: UInt32
    var main: UInt32
    var caret: UInt32
    var sub: UInt32
    var subAlt: UInt32
    var text: UInt32
    var error: UInt32

    static let presets: [Theme: (name: String, colors: MonkeytypeColors)] = [
        .modernInk: ("Modern Ink", .init(bg: 0xFFFFFF, main: 0xFF360D, caret: 0xFF0000, sub: 0xB7B7B7, subAlt: 0xECECEC, text: 0x000000, error: 0xD70000)),
        .dmg: ("DMG", .init(bg: 0xDADBDC, main: 0xAE185E, caret: 0x384693, sub: 0x3846B1, subAlt: 0xBEC1D2, text: 0x414141, error: 0xAE185E)),
        .shoko: ("Shoko", .init(bg: 0xCED7E0, main: 0x81C4DD, caret: 0x81C4DD, sub: 0x7599B1, subAlt: 0xB7CADA, text: 0x3B4C58, error: 0xBF616A)),
        .vaporwave: ("Vaporwave", .init(bg: 0xA4A7EA, main: 0xE368DA, caret: 0x28CAFE, sub: 0x7C7FAF, subAlt: 0x989BD9, text: 0xF1EBF1, error: 0x573CA9)),
        .nightRunner: ("Night Runner", .init(bg: 0x212121, main: 0xFEFF04, caret: 0xFEFF04, sub: 0x5C4A9C, subAlt: 0x1A1A1A, text: 0xE8E8E8, error: 0xDA3333)),
        .miamiNights: ("Miami Nights", .init(bg: 0x18181A, main: 0xE4609B, caret: 0xE4609B, sub: 0x47BAC0, subAlt: 0x0F0F10, text: 0xFFFFFF, error: 0xFFF591)),
        .olivia: ("Olivia", .init(bg: 0x1C1B1D, main: 0xDEAF9D, caret: 0xDEAF9D, sub: 0x4E3E3E, subAlt: 0x262223, text: 0xF2EFED, error: 0xBF616A)),
    ]

    var isDark: Bool { Self.luminance(text) > Self.luminance(bg) }

    /// Monkeytype's sub colour is for untyped words and is often faint. Captions in the app need 3:1.
    var secondaryText: UInt32 { Self.legible(sub, on: bg, toward: text) }

    /// Whichever of the theme's own background or text reads better on the accent.
    var onAccent: UInt32 { Self.contrast(bg, main) >= Self.contrast(text, main) ? bg : text }

    /// Accent used as text (headings, links) blends toward the text colour until it reads on the background.
    var accentText: UInt32 { Self.legible(main, on: bg, toward: text) }
    var caretText: UInt32 { Self.legible(caret, on: bg, toward: text) }

    /// Blends `color` toward the theme's text until it reads on `background`. When even the text colour
    /// doesn't (Vaporwave's is 1.9:1), it blends toward black or white instead, whichever reads.
    static func legible(_ color: UInt32, on background: UInt32, toward target: UInt32, minimum: Double = 3) -> UInt32 {
        let extreme: UInt32 = contrast(0x000000, background) >= contrast(0xFFFFFF, background) ? 0x000000 : 0xFFFFFF
        for goal in [target, extreme] {
            for step in 0...10 {
                let mixed = mix(color, goal, Double(step) / 10)
                if contrast(mixed, background) >= minimum { return mixed }
            }
        }
        return extreme
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    static func luminance(_ hex: UInt32) -> Double {
        let channels = [16, 8, 0].map { Double((hex >> UInt32($0)) & 0xFF) / 255 }
            .map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    private static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        [16, 8, 0].reduce(0) { result, shift in
            let x = Double((a >> UInt32(shift)) & 0xFF), y = Double((b >> UInt32(shift)) & 0xFF)
            return result | (UInt32((x + (y - x) * t).rounded()) << UInt32(shift))
        }
    }
}

extension Palette {
    init(_ colors: MonkeytypeColors) {
        let text = Color(hex: colors.text), secondaryText = Color(hex: colors.secondaryText)
        let accentText = Color(hex: colors.accentText)
        self.init(background: Color(hex: colors.bg),
                  groupedBackground: Color(hex: colors.bg),
                  surface: Color(hex: colors.subAlt),
                  fill: Color(hex: colors.subAlt),
                  text: text,
                  secondaryText: secondaryText,
                  accent: Color(hex: colors.main),
                  onAccent: Color(hex: colors.onAccent),
                  success: accentText,
                  danger: Color(hex: colors.error),
                  markup: Markup(heading: accentText, strong: text, emphasis: text,
                                 code: Color(hex: colors.caretText), link: Color(hex: colors.caretText),
                                 quote: secondaryText, marker: accentText),
                  tint: accentText)
    }

    static let native: Palette = {
        #if os(iOS)
        // A fixed blue, not .accentColor: that resolves to the active tint, which is another theme's accent
        // when these colours are drawn on a preset's Appearance page.
        let text = Color(uiColor: .label), secondaryText = Color(uiColor: .secondaryLabel), accent = Color(uiColor: .systemBlue)
        return Palette(background: Color(uiColor: .systemBackground),
                       groupedBackground: Color(uiColor: .systemGroupedBackground),
                       surface: Color(uiColor: .secondarySystemGroupedBackground),
                       fill: Color(uiColor: .secondarySystemBackground),
                       text: text, secondaryText: secondaryText,
                       accent: accent, onAccent: .white, success: .green, danger: .red,
                       markup: .plain(text: text, secondaryText: secondaryText, link: accent))
        #else
        let text = Color(nsColor: .labelColor), secondaryText = Color(nsColor: .secondaryLabelColor), accent = Color(nsColor: .systemBlue)
        return Palette(background: Color(nsColor: .windowBackgroundColor),
                       groupedBackground: Color(nsColor: .underPageBackgroundColor),
                       surface: Color(nsColor: .controlBackgroundColor),
                       fill: Color(nsColor: .quaternaryLabelColor),
                       text: text, secondaryText: secondaryText,
                       accent: accent, onAccent: .white, success: .green, danger: .red,
                       markup: .plain(text: text, secondaryText: secondaryText, link: accent))
        #endif
    }()
}

extension Markup {
    static func plain(text: Color, secondaryText: Color, link: Color) -> Markup {
        Markup(heading: text, strong: text, emphasis: text, code: text,
               link: link, quote: secondaryText, marker: secondaryText)
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
            .tint(palette.tint ?? palette.accent)
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
