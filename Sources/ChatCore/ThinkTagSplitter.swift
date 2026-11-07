import Foundation

/// Splits inline `<think>…</think>` blocks out of streamed content.
/// Holds back only a trailing run that could still become a tag.
/// Drops whitespace before the first visible content, since models emit
/// blank lines after their reasoning.
struct ThinkTagSplitter {
    private static let open = "<think>"
    private static let close = "</think>"

    private var buffer = ""
    private var insideThink = false
    private var contentStarted = false

    mutating func push(_ delta: String) -> [StreamEvent] {
        buffer += delta
        var events: [StreamEvent] = []

        while true {
            let tag = insideThink ? Self.close : Self.open
            if let range = buffer.range(of: tag) {
                emit(String(buffer[..<range.lowerBound]), into: &events)
                buffer = String(buffer[range.upperBound...])
                insideThink.toggle()
                continue
            }
            let held = partialTagSuffixLength(of: tag)
            let ready = buffer.dropLast(held)
            emit(String(ready), into: &events)
            buffer = String(buffer.suffix(held))
            return events
        }
    }

    mutating func flush() -> [StreamEvent] {
        var events: [StreamEvent] = []
        emit(buffer, into: &events)
        buffer = ""
        return events
    }

    private mutating func emit(_ text: String, into events: inout [StreamEvent]) {
        if insideThink {
            if !text.isEmpty { events.append(.reasoning(text)) }
            return
        }
        let visible = contentStarted ? Substring(text) : text.drop(while: \.isWhitespace)
        guard !visible.isEmpty else { return }
        contentStarted = true
        events.append(.content(String(visible)))
    }

    private func partialTagSuffixLength(of tag: String) -> Int {
        for length in stride(from: min(tag.count - 1, buffer.count), through: 1, by: -1)
        where buffer.hasSuffix(tag.prefix(length)) {
            return length
        }
        return 0
    }
}
