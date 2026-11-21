import Testing
@testable import ChatUI

struct ThemeTests {
    private static let presets = MonkeytypeColors.presets.values.map(\.colors)

    @Test func systemTabHoldsTheDeviceThemesAndPresetsHoldTheRest() {
        #expect(Theme.allCases.filter { $0.group == .system } == [.system, .light, .dark])
        #expect(Theme.allCases.filter { $0.group == .presets }
                == [.dracula, .modernInk, .dmg, .shoko, .vaporwave, .nightRunner, .miamiNights, .olivia, .akariLight, .akariDark])
        #expect(Theme.allCases.filter { $0.group == .presets }.map(\.name)
                == ["Dracula", "Modern Ink", "DMG", "Shoko", "Vaporwave", "Night Runner", "Miami Nights", "Olivia",
                    "Akari Light", "Akari Dark"])
    }

    @Test func captionsReadOnEveryPreset() {
        for colors in Self.presets {
            #expect(MonkeytypeColors.contrast(colors.secondaryText, colors.bg) >= 3)
            #expect(MonkeytypeColors.contrast(colors.accentText, colors.bg) >= 3)
        }
    }

    @Test func faintColoursOnlyMoveAsFarAsNeeded() {
        let miami = MonkeytypeColors.presets[.miamiNights]!.colors
        #expect(miami.secondaryText == miami.sub, "an already readable sub colour is kept")
        let olivia = MonkeytypeColors.presets[.olivia]!.colors
        #expect(olivia.secondaryText != olivia.sub && olivia.secondaryText != olivia.text, "a faint one blends, not replaced")
    }

    @Test func bubbleTextUsesWhicheverThemeColourReadsBetterOnTheAccent() {
        for colors in Self.presets {
            let other = colors.onAccent == colors.bg ? colors.text : colors.bg
            #expect(MonkeytypeColors.contrast(colors.onAccent, colors.main) >= MonkeytypeColors.contrast(other, colors.main))
        }
        #expect(MonkeytypeColors.presets[.nightRunner]!.colors.onAccent == 0x212121, "dark text on Night Runner's yellow")
    }

    @Test func everyAkariColourReadsWhereTheAppPutsIt() {
        for colors in [AkariColors.night, .dawn] {
            for onBackground in [colors.foreground, colors.muted, colors.accent, colors.success, colors.error, colors.link,
                                 colors.heading, colors.raw] {
                #expect(MonkeytypeColors.contrast(onBackground, colors.background) >= 3)
            }
            #expect(MonkeytypeColors.contrast(colors.onAccent, colors.accent) >= 3)
            for panel in [colors.surface, colors.raised] {
                #expect(MonkeytypeColors.contrast(colors.foreground, panel) >= 4.5)
                #expect(MonkeytypeColors.contrast(colors.muted, panel) >= 3)
            }
        }
    }

    @Test func lightAndDarkPresetsGetTheMatchingSystemScheme() {
        let dark = Theme.allCases.filter { $0.colorScheme == .dark }
        #expect(dark == [.dark, .dracula, .vaporwave, .nightRunner, .miamiNights, .olivia, .akariDark])
    }
}
