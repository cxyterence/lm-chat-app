import SwiftUI

struct AppearanceSettings: View {
    let store: ChatStore
    @Environment(\.palette) private var palette

    var body: some View {
        Form {
            Section("Theme") {
                ForEach(Theme.allCases) { theme in
                    Button { store.setTheme(theme) } label: {
                        ThemeRow(theme: theme, selected: theme == store.theme)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(palette.surface)

            Section("Preview") {
                VStack(spacing: 10) {
                    HStack {
                        Spacer(minLength: 48)
                        Text("How does this look?")
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(palette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .foregroundStyle(palette.onAccent)
                    }
                    MarkdownView(text: """
                        ### \(store.theme.name)
                        Looks **good**, *really*. Try `chatcli` or read [the docs](https://example.com).
                        - Pick another theme any time
                        """)
                        .foregroundStyle(palette.text)
                        .padding(.trailing, 48)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(palette.background)
        }
        .formStyle(.grouped)
        .foregroundStyle(palette.text)
        .scrollContentBackground(.hidden)
    }
}

private struct ThemeRow: View {
    let theme: Theme
    let selected: Bool
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            // Native palettes are adaptive; resolve them in the theme's own scheme, not the current one.
            ThemeSwatch(palette: theme.palette)
                .environment(\.colorScheme, theme.colorScheme ?? colorScheme)
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.name).foregroundStyle(palette.text)
                Text(theme.subtitle).font(.caption).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(palette.accent)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ThemeSwatch: View {
    let palette: Palette

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(palette.background)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.secondaryText.opacity(0.5), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Circle().fill(palette.accent).frame(width: 10, height: 10)
                    Capsule().fill(palette.text).frame(width: 26, height: 3)
                    Capsule().fill(palette.secondaryText).frame(width: 18, height: 3)
                }
                .padding(7)
            }
            .frame(width: 44, height: 36)
    }
}
