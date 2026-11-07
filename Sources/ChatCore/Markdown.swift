import Foundation

/// Block-level Markdown. Inline syntax (bold, code spans, links) stays in each block's text for the renderer.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([ListItem])
    case code(language: String?, text: String)
    case quote(String)
    case rule
    case table(header: [String], rows: [[String]])
}

public struct ListItem: Equatable, Sendable {
    public enum Marker: Equatable, Sendable {
        case bullet
        case number(Int)
    }

    public var marker: Marker
    public var depth: Int
    public var text: String

    public init(marker: Marker, depth: Int, text: String) {
        self.marker = marker
        self.depth = depth
        self.text = text
    }
}

public enum Markdown {
    /// Tolerates partial input, so it can re-parse a reply on every streamed chunk.
    public static func blocks(from text: String) -> [MarkdownBlock] {
        var parser = Parser(lines: text.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0.hasSuffix("\r") ? $0.dropLast() : $0)
        })
        return parser.parse()
    }
}

private struct Parser {
    let lines: [String]
    var index = 0
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []

    init(lines: [String]) { self.lines = lines }

    mutating func parse() -> [MarkdownBlock] {
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
            } else if let fence = Self.fence(trimmed) {
                flushParagraph()
                parseCode(fence: fence, info: trimmed.dropFirst(fence.count))
            } else if !paragraph.isEmpty, let level = Self.setextLevel(trimmed) {
                blocks.append(.heading(level: level, text: paragraph.joined(separator: " ")))
                paragraph = []
                index += 1
            } else if let heading = Self.heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
            } else if Self.isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                parseQuote()
            } else if Self.listItem(line) != nil {
                flushParagraph()
                parseList()
            } else if trimmed.contains("|"), index + 1 < lines.count, Self.isTableSeparator(lines[index + 1]) {
                flushParagraph()
                parseTable()
            } else {
                paragraph.append(trimmed)
                index += 1
            }
        }
        flushParagraph()
        return blocks
    }

    private mutating func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        paragraph = []
    }

    private mutating func parseCode(fence: String, info: Substring) {
        let language = info.trimmingCharacters(in: .whitespaces)
        var body: [String] = []
        index += 1
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
            body.append(line)
        }
        blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
    }

    private mutating func parseQuote() {
        var body: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var rest = trimmed.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
            body.append(String(rest))
            index += 1
        }
        blocks.append(.quote(body.joined(separator: "\n")))
    }

    private mutating func parseList() {
        var items: [ListItem] = []
        while index < lines.count {
            let line = lines[index]
            if let item = Self.listItem(line) {
                items.append(item)
                index += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                let next = lines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard let next, Self.listItem(next) != nil else { break }
                index += 1
            } else if line.first == " " || line.first == "\t", !items.isEmpty {
                items[items.count - 1].text += " " + line.trimmingCharacters(in: .whitespaces)
                index += 1
            } else {
                break
            }
        }
        blocks.append(.list(items))
    }

    private mutating func parseTable() {
        let header = Self.cells(lines[index])
        index += 2
        var rows: [[String]] = []
        while index < lines.count, lines[index].contains("|"),
              !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            var row = Self.cells(lines[index])
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            rows.append(Array(row.prefix(header.count)))
            index += 1
        }
        blocks.append(.table(header: header, rows: rows))
    }

    private static func fence(_ trimmed: String) -> String? {
        for mark in ["```", "~~~"] where trimmed.hasPrefix(mark) {
            return String(trimmed.prefix { $0 == mark.first })
        }
        return nil
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        guard let match = trimmed.wholeMatch(of: /(#{1,6})(?:\s+(.*?))?(?:\s+#+)?\s*/) else { return nil }
        return .heading(level: match.1.count, text: String(match.2 ?? ""))
    }

    private static func setextLevel(_ trimmed: String) -> Int? {
        if trimmed.wholeMatch(of: /=+/) != nil { return 1 }
        if trimmed.wholeMatch(of: /-+/) != nil { return 2 }
        return nil
    }

    private static func isRule(_ trimmed: String) -> Bool {
        trimmed.wholeMatch(of: /(?:-\s*){3,}|(?:\*\s*){3,}|(?:_\s*){3,}/) != nil
    }

    private static func listItem(_ line: String) -> ListItem? {
        guard let match = line.wholeMatch(of: /([ \t]*)([-*+]|(\d{1,9})[.)])[ \t]+(.*)/) else { return nil }
        let indent = match.1.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let marker: ListItem.Marker = match.3.flatMap { Int($0) }.map { .number($0) } ?? .bullet
        return ListItem(marker: marker, depth: indent / 2, text: String(match.4))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        line.contains("-") && line.wholeMatch(of: /\s*\|?(?:\s*:?-+:?\s*\|)*\s*:?-+:?\s*\|?\s*/) != nil
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)[...]
        if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix("|") { trimmed = trimmed.dropLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
