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
}
