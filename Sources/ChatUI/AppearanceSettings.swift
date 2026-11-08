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

    /// Native palettes are adaptive, so each is resolved in its own scheme rather than the current one.
    /// System follows the device, so its tile shows both: light, with dark across the lower-right half.
    @ViewBuilder private var face: some View {
        let tile = TileFace(name: theme.name, palette: theme.palette, selected: selected)
        if let scheme = theme.colorScheme {
            tile.environment(\.colorScheme, scheme)
        } else {
            tile.environment(\.colorScheme, .light)
                .overlay { tile.environment(\.colorScheme, .dark).mask(LowerRightHalf()) }
        }
    }

    var body: some View {
        face
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

private struct LowerRightHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
