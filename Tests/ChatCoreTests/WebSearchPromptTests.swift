import Testing
@testable import ChatCore

struct WebSearchPromptTests {
    @Test func noResultsSaysSo() {
        #expect(WebSearch(query: "x", results: []).prompt.contains("found nothing"))
    }

    @Test func commandParses() {
        #expect(SlashCommand.parse("/web-search swift 6")?.command == .webSearch)
        #expect(SlashCommand.parse("/web-search swift 6")?.argument == "swift 6")
        #expect(SlashCommand.suggestions(for: "/w") == [.webSearch])
        #expect(SlashCommand.webSearch.needsArgument && !SlashCommand.compact.needsArgument)
    }

    @Test func toolArgumentsNeedANonBlankQuery() {
        #expect(WebSearch.query(in: #"{"query": "  swift 6 "}"#) == "swift 6")
        #expect(WebSearch.query(in: #"{"query": "  "}"#) == nil)
        #expect(WebSearch.query(in: #"{"q": "swift"}"#) == nil)
        #expect(WebSearch.query(in: "not json") == nil)
        #expect(WebSearch.toolResult([]) == "The search found nothing.")
    }
}
