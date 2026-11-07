import Testing
@testable import ChatCore

struct PartialMarkdownTests {
    @Test(arguments: [
        ("This is **bol", "This is **bol**"),
        ("a *it", "a *it*"),
        ("use `nvidia-s", "use `nvidia-s`"),
        ("~~old", "~~old~~"),
        ("***both", "***both***"),
        ("**bold** and *it", "**bold** and *it*"),
        ("code `a*b` then **x", "code `a*b` then **x**"),
        ("* item **bo", "* item **bo**"),
        ("**trailing space ", "**trailing space**"),
    ])
    func closesOpenSpans(partial: String, expected: String) {
        #expect(Markdown.completingPartial(partial) == expected)
    }

    @Test(arguments: [
        ("see [the do", "see the do"),
        ("see [the docs](https://exa", "see the docs"),
        ("see [the docs]", "see the docs"),
    ])
    func unfinishedLinksShowTheirText(partial: String, expected: String) {
        #expect(Markdown.completingPartial(partial) == expected)
    }

    @Test(arguments: [
        ("ends with **", "ends with"),
        ("ends with *", "ends with"),
        ("ends with `", "ends with"),
        ("```", ""),
    ])
    func danglingOpenersAreHidden(partial: String, expected: String) {
        #expect(Markdown.completingPartial(partial) == expected)
    }

    @Test(arguments: [
        "**done** and *done* and `done` and [link](https://x.y)",
        "5 * 3 = 15",
        "tick [x] done",
        "first line **bold\nsecond line",
        "```python\nx = 1 **",
        "",
    ])
    func leavesFinishedOrLiteralTextAlone(text: String) {
        #expect(Markdown.completingPartial(text) == text)
    }

    @Test func onlyTheLastLineIsCompleted() {
        #expect(Markdown.completingPartial("# Title\nIt is **4-bi") == "# Title\nIt is **4-bi**")
    }
}
