import Testing
@testable import ChatCore

struct ParagraphsTests {
    @Test func splitsOnBlankLines() {
        #expect(Paragraphs.split("one\ntwo\n\nthree\n\n\nfour") == ["one\ntwo", "three", "\nfour"])
    }

    @Test func cutsLongParagraphsAtSpacesWithoutLosingText() {
        let text = (1...300).map { "word\($0)" }.joined(separator: " ")
        let pieces = Paragraphs.split(text, maxLength: 100)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= 100 })
        #expect(pieces.joined(separator: " ") == text)
    }

    @Test func appendingOnlyChangesTheLastPiece() {
        let full = (1...400).map { "token\($0)" }.joined(separator: " ") + "\n\nnext paragraph here"
        var previous: [Substring] = []
        for end in stride(from: 1, through: full.count, by: 37) {
            let pieces = Paragraphs.split(String(full.prefix(end)), maxLength: 120)
            if previous.count > 1 {
                #expect(Array(pieces.prefix(previous.count - 1)) == Array(previous.dropLast()), "settled pieces never change")
            }
            previous = pieces
        }
    }

    @Test func tailIsBoundedAndStartsAtAParagraph() {
        let text = (1...200).map { "Paragraph \($0) has a few words in it." }.joined(separator: "\n\n")
        let tail = Paragraphs.tail(text, length: 500)
        #expect(tail.count <= 500)
        #expect(tail.hasPrefix("Paragraph "))
        #expect(text.hasSuffix(tail))
        #expect(Paragraphs.tail("short", length: 500) == "short")
    }
}
