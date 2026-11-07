import ChatCore
import SwiftUI

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Markdown.blocks(from: text).enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    @Environment(\.palette) private var palette

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text, palette))
                .font(level == 1 ? .title2 : level == 2 ? .title3 : .headline)
                .fontWeight(.bold)
                .foregroundStyle(palette.markup.heading)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(inline(text, palette))
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker(item)).monospacedDigit().foregroundStyle(palette.markup.marker)
                        Text(inline(item.text, palette))
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language).font(.caption).foregroundStyle(palette.secondaryText)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text).font(.system(.callout, design: .monospaced)).foregroundStyle(palette.markup.code)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .quote(let text):
            Text(inline(text, palette))
                .italic()
                .foregroundStyle(palette.markup.quote)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.markup.quote.opacity(0.6)).frame(width: 3)
                }
        case .rule:
            Rectangle().fill(palette.secondaryText.opacity(0.4)).frame(height: 1).padding(.vertical, 4)
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell, palette)).fontWeight(.semibold).foregroundStyle(palette.markup.heading)
                        }
                    }
                    Rectangle().fill(palette.secondaryText.opacity(0.4)).frame(height: 1)
                        .gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(inline(cell, palette)) }
                        }
                    }
                }
                .padding(10)
            }
            .background(palette.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func marker(_ item: ListItem) -> String {
        switch item.marker {
        case .number(let n): "\(n)."
        case .bullet: item.depth == 0 ? "•" : "◦"
        }
    }
}

private func inline(_ text: String, _ palette: Palette) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    guard var styled = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
    for run in styled.runs {
        if let intent = run.inlinePresentationIntent {
            if intent.contains(.stronglyEmphasized) { styled[run.range].foregroundColor = palette.markup.strong }
            if intent.contains(.emphasized) { styled[run.range].foregroundColor = palette.markup.emphasis }
            if intent.contains(.code) {
                styled[run.range].foregroundColor = palette.markup.code
                styled[run.range].font = .system(.body, design: .monospaced)
            }
        }
        if run.link != nil {
            styled[run.range].foregroundColor = palette.markup.link
            styled[run.range].underlineStyle = .single
        }
    }
    return styled
}
