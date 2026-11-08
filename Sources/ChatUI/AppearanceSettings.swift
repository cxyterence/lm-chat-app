import SwiftUI

struct AppearanceSettings: View {
    let store: ChatStore
    @Environment(\.palette) private var palette
    @State private var group: Theme.Group

    init(store: ChatStore) {
        self.store = store
        _group = State(initialValue: store.theme.group)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Theme group", selection: $group) {
                    ForEach(Theme.Group.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Theme.allCases.filter { $0.group == group }) { theme in
                        Button { store.setTheme(theme) } label: {
                            ThemeTile(theme: theme, selected: theme == store.theme)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .animation(.snappy, value: group)
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

/// A tile painted in its own theme's colours, so the grid previews every theme at once.
private struct ThemeTile: View {
    let theme: Theme
    let selected: Bool
    @Environment(\.palette) private var current
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Native palettes are adaptive. Resolve them in the theme's own scheme, not the current one.
        TileFace(name: theme.name, palette: theme.palette, selected: selected)
            .environment(\.colorScheme, theme.colorScheme ?? colorScheme)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? current.tint ?? current.accent : current.secondaryText.opacity(0.35),
                                  lineWidth: selected ? 2.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(theme.name)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct TileFace: View {
    let name: String
    let palette: Palette
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(Array([palette.accent, palette.secondaryText, palette.text].enumerated()), id: \.offset) {
                    Circle().fill($0.element).frame(width: 8, height: 8)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(palette.text)
                    .padding(8)
            }
        }
        .background(palette.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
