import Testing
@testable import ChatCore

struct SlashCommandTests {
    @Test func parsesTheCommandAndItsArgument() {
        #expect(SlashCommand.parse("/compact")?.command == .compact)
        #expect(SlashCommand.parse("  /compact  keep the code  ")?.argument == "keep the code")
        #expect(SlashCommand.parse("/COMPACT")?.command == .compact)
        #expect(SlashCommand.parse("/compact\nkeep names")?.argument == "keep names")
    }

    @Test(arguments: ["hello", "/etc/hosts is missing", "/compacted", "a /compact", "/"])
    func otherTextIsAMessage(_ text: String) {
        #expect(SlashCommand.parse(text) == nil)
    }

    @Test func suggestsWhileTheNameIsTyped() {
        #expect(SlashCommand.suggestions(for: "/") == SlashCommand.allCases)
        #expect(SlashCommand.suggestions(for: "/co") == [.compact])
        #expect(SlashCommand.suggestions(for: "/x").isEmpty)
        #expect(SlashCommand.suggestions(for: "hi /co").isEmpty)
    }

    @Test func keepsShowingTheCommandOnceItsNamed() {
        #expect(SlashCommand.suggestions(for: "/compact keep it short") == [.compact])
        #expect(SlashCommand.suggestions(for: "/nope keep it").isEmpty)
    }
}
