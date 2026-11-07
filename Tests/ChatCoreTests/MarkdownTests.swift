import Testing
@testable import ChatCore

struct MarkdownTests {
    @Test func headingsAndRulesAreBlocksNotText() {
        let reply = """
        ## NVFP4 overview

        It is a **4-bit** format.

        ---

        ### Details ###
        """
        #expect(Markdown.blocks(from: reply) == [
            .heading(level: 2, text: "NVFP4 overview"),
            .paragraph("It is a **4-bit** format."),
            .rule,
            .heading(level: 3, text: "Details"),
        ])
    }

    @Test(arguments: ["***", "* * *", "___", "- - -"])
    func ruleSpellings(rule: String) {
        #expect(Markdown.blocks(from: "a\n\n\(rule)\n\nb") == [.paragraph("a"), .rule, .paragraph("b")])
    }

    @Test func hashWithoutSpaceIsText() {
        #expect(Markdown.blocks(from: "#hashtag and C# code") == [.paragraph("#hashtag and C# code")])
    }

    @Test func dashesUnderTextMakeASetextHeading() {
        #expect(Markdown.blocks(from: "Summary\n---\nBody") == [.heading(level: 2, text: "Summary"), .paragraph("Body")])
    }

    @Test func listsKeepMarkersDepthAndContinuations() {
        let reply = """
        Steps:
        1. Quantize
           the weights
        2. Scale
           - per block
           - per tensor

        3. Done
        """
        #expect(Markdown.blocks(from: reply) == [
            .paragraph("Steps:"),
            .list([
                ListItem(marker: .number(1), depth: 0, text: "Quantize the weights"),
                ListItem(marker: .number(2), depth: 0, text: "Scale"),
                ListItem(marker: .bullet, depth: 1, text: "per block"),
                ListItem(marker: .bullet, depth: 1, text: "per tensor"),
                ListItem(marker: .number(3), depth: 0, text: "Done"),
            ]),
        ])
    }

    @Test func boldLineIsNotABullet() {
        #expect(Markdown.blocks(from: "**Note:** careful") == [.paragraph("**Note:** careful")])
    }

    @Test func fencedCodeKeepsContentVerbatim() {
        let reply = "Run:\n```sh\n## not a heading\n---\n```\nafter"
        #expect(Markdown.blocks(from: reply) == [
            .paragraph("Run:"),
            .code(language: "sh", text: "## not a heading\n---"),
            .paragraph("after"),
        ])
    }

    @Test func unterminatedFenceWhileStreamingIsStillCode() {
        #expect(Markdown.blocks(from: "```python\nprint(1)\n") == [.code(language: "python", text: "print(1)\n")])
    }

    @Test func quotesJoinConsecutiveLines() {
        #expect(Markdown.blocks(from: "> one\n>two\n\nafter") == [.quote("one\ntwo"), .paragraph("after")])
    }

    @Test func tablesSplitCellsAndPadShortRows() {
        let reply = """
        | Format | Bits |
        |:-------|-----:|
        | FP8 | 8 |
        | NVFP4 |
        """
        #expect(Markdown.blocks(from: reply) == [
            .table(header: ["Format", "Bits"], rows: [["FP8", "8"], ["NVFP4", ""]]),
        ])
    }

    @Test func pipeInProseIsNotATable() {
        #expect(Markdown.blocks(from: "a | b\nnext line") == [.paragraph("a | b\nnext line")])
    }
}
