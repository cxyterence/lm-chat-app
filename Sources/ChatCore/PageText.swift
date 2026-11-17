import Foundation

/// The readable text of an HTML page. Not a parser: it keeps what a person would read and drops the rest, which
/// is enough for a model.
public enum PageText {
    public struct Extracted: Equatable, Sendable {
        public var title: String?
        public var text: String
    }

    private static let dropped: Set<String> = ["script", "style", "noscript", "template", "svg"]
    private static let headElements: Set<String> = ["base", "link", "meta", "title"]
    /// A title that never closes would otherwise be the rest of the page.
    private static let titleLimit = 300
    /// Tags whose start and end break the line.
    private static let blocks: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "dd", "details", "div", "dl", "dt", "fieldset", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p",
        "pre", "section", "summary", "table", "tr", "ul",
    ]
    /// The blocks that also leave a blank line.
    private static let paragraphs: Set<String> = ["blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "ol", "p", "pre", "table", "ul"]

    /// Drops `script`, `style`, `noscript` and everything in `head` but the title, comments and tags. Block ends and
    /// `<br>` become line breaks, entities are decoded, and runs of blank lines shrink to one. Spaces in `pre` stay.
    public static func extract(fromHTML html: String) -> Extracted {
        let s = Array(html.unicodeScalars)
        var out = String.UnicodeScalarView()
        var title: String?
        var inHead = false
        var preDepth = 0
        var atSpace = true
        var i = 0

        func emit(_ scalar: Unicode.Scalar) {
            if preDepth == 0, scalar.properties.isWhitespace {
                if !atSpace { out.append(" ") }
                atSpace = true
            } else {
                out.append(scalar)
                atSpace = scalar == "\n"
            }
        }
        func lineBreak(blank: Bool) {
            while out.last == " " { out.removeLast() }
            guard !out.isEmpty else { return }
            if out.last != "\n" { out.append("\n") }
            if blank, !String(out.suffix(2)).elementsEqual("\n\n") { out.append("\n") }
            atSpace = true
        }
        func lower(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
            (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }
        func matches(_ text: String, at index: Int) -> Bool {
            var j = index
            for expected in text.unicodeScalars {
                guard j < s.count, lower(s[j]) == expected else { return false }
                j += 1
            }
            return true
        }
        func find(_ text: String, from index: Int) -> Int? {
            var j = index
            while j < s.count {
                if s[j] == text.unicodeScalars.first!, matches(text, at: j) { return j }
                j += 1
            }
            return nil
        }
        func text(_ range: Range<Int>) -> String { decode(String(String.UnicodeScalarView(s[range]))) }

        while i < s.count {
            let c = s[i]
            if c == "&" {
                if let (decoded, length) = entity(in: s, at: i) {
                    if !inHead { decoded.unicodeScalars.forEach(emit) }
                    i += length
                    continue
                }
            }
            guard c == "<" else {
                if !inHead { emit(c) }
                i += 1
                continue
            }
            if matches("<!--", at: i) {
                i = find("-->", from: i + 4).map { $0 + 3 } ?? s.count
                continue
            }
            let closing = i + 1 < s.count && s[i + 1] == "/"
            let nameStart = i + (closing ? 2 : 1)
            var nameEnd = nameStart
            while nameEnd < s.count, s[nameEnd].properties.isAlphabetic || (nameEnd > nameStart && (48...57).contains(s[nameEnd].value)) { nameEnd += 1 }
            guard nameEnd > nameStart else {
                // `<!doctype>` and `<?xml?>` are skipped. Anything else, such as "a < b", is text.
                if i + 1 < s.count, s[i + 1] == "!" || s[i + 1] == "?" {
                    i = find(">", from: i).map { $0 + 1 } ?? s.count
                } else {
                    if !inHead { emit(c) }
                    i += 1
                }
                continue
            }
            let name = String(String.UnicodeScalarView(s[nameStart..<nameEnd])).lowercased()

            var end = nameEnd
            var quote: Unicode.Scalar?
            var previous: Unicode.Scalar?
            while end < s.count {
                if let open = quote { if s[end] == open { quote = nil } }
                // A quote opens a value only right after `=`. In `alt=Don't` it is part of the word.
                else if (s[end] == "\"" || s[end] == "'") && previous == "=" { quote = s[end] }
                else if s[end] == ">" { break }
                if !s[end].properties.isWhitespace { previous = s[end] }
                end += 1
            }
            guard end < s.count else { break }
            i = end + 1

            if dropped.contains(name) {
                if !closing { i = find("</" + name, from: i).flatMap { find(">", from: $0) }.map { $0 + 1 } ?? s.count }
                continue
            }
            if inHead, name != "head", !headElements.contains(name) { inHead = false }
            switch name {
            case "head": inHead = !closing
            case "body": inHead = false
            case "title" where !closing:
                let close = find("</title", from: i) ?? s.count
                if title == nil {
                    let found = text(i..<close).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(titleLimit)
                    title = found.isEmpty ? nil : String(found)
                }
                i = find(">", from: close).map { $0 + 1 } ?? s.count
            case "pre": preDepth = max(0, preDepth + (closing ? -1 : 1))
            default: break
            }
            if blocks.contains(name), !inHead { lineBreak(blank: paragraphs.contains(name)) }
        }

        var lines = String(out).split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var line = line
                while let last = line.last, last.isWhitespace { line.removeLast() }
                return String(line)
            }
        var kept: [String] = []
        for line in lines {
            if line.isEmpty, kept.last?.isEmpty != false { continue }
            kept.append(line)
        }
        lines = kept
        while lines.last?.isEmpty == true { lines.removeLast() }
        return Extracted(title: title, text: lines.joined(separator: "\n"))
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®", "trade": "™",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•",
        "middot": "·", "laquo": "«", "raquo": "»", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°",
        "times": "×", "divide": "÷", "plusmn": "±", "frac12": "½", "sect": "§", "para": "¶", "larr": "←", "rarr": "→",
    ]

    /// The entity at `index`, which is an `&`, as text and the number of scalars it takes up.
    private static func entity(in s: [Unicode.Scalar], at index: Int) -> (String, Int)? {
        guard let semicolon = (index + 2..<min(index + 12, s.count)).first(where: { s[$0] == ";" }) else { return nil }
        let body = String(String.UnicodeScalarView(s[(index + 1)..<semicolon]))
        let decoded: String?
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let hex = digits.first == "x" || digits.first == "X"
            decoded = Int(hex ? digits.dropFirst() : digits, radix: hex ? 16 : 10)
                .flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        } else {
            decoded = named[body]
        }
        return decoded.map { ($0, semicolon - index + 1) }
    }

    /// `text` with its entities replaced, for a title.
    private static func decode(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            if s[i] == "&", let (decoded, length) = entity(in: s, at: i) {
                out.append(contentsOf: decoded.unicodeScalars)
                i += length
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return String(out)
    }
}
