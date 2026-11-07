/// Splits long plain text into paragraphs, cutting any paragraph longer than `maxLength` at a space.
/// Earlier pieces depend only on the text before them, so appending text changes only the last piece and
/// a view can keep the layout of everything above it.
public enum Paragraphs {
    public static func split(_ text: String, maxLength: Int = 1000) -> [Substring] {
        text.split(separator: "\n\n", omittingEmptySubsequences: true).flatMap { chunk($0, maxLength: maxLength) }
    }

    private static func chunk(_ paragraph: Substring, maxLength: Int) -> [Substring] {
        var pieces: [Substring] = []
        var rest = paragraph
        while rest.count > maxLength {
            let window = rest.prefix(maxLength)
            guard let space = window.lastIndex(of: " ") else {
                pieces.append(window)
                rest = rest[window.endIndex...]
                continue
            }
            pieces.append(rest[..<space])
            rest = rest[rest.index(after: space)...]
        }
        if !rest.isEmpty { pieces.append(rest) }
        return pieces
    }
}

extension Paragraphs {
    /// The end of `text`, about `length` characters, starting at a paragraph break when there is one
    /// (or a space otherwise), so a live view's cost stays flat however long the text grows.
    public static func tail(_ text: String, length: Int = 3000) -> Substring {
        guard text.count > length else { return text[...] }
        let window = text.suffix(length)
        if let breakAt = window.range(of: "\n\n") { return window[breakAt.upperBound...] }
        if let space = window.firstIndex(of: " ") { return window[window.index(after: space)...] }
        return window
    }
}
