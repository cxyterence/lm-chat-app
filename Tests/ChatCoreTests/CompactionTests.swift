import Testing
@testable import ChatCore

struct CompactionTests {
    private func pairs(_ messages: [ChatMessage]) -> [String] { messages.map { "\($0.role.rawValue): \($0.content)" } }

    private let history = [
        ChatMessage(role: .user, content: "one"),
        ChatMessage(role: .assistant, content: "re one"),
        ChatMessage(role: .summary, content: "S1"),
        ChatMessage(role: .user, content: "two"),
        ChatMessage(role: .assistant, content: "re two"),
    ]

    @Test func withoutASummaryTheModelSeesEverything() {
        let plain = Array(history.prefix(2))
        #expect(pairs(Compaction.context(of: plain, systemPrompt: "")) == ["user: one", "assistant: re one"])
        #expect(pairs(Compaction.context(of: plain, systemPrompt: "Be brief.")) == ["system: Be brief.", "user: one", "assistant: re one"])
    }

    @Test func theSummaryStandsInForEverythingBeforeIt() {
        let context = Compaction.context(of: history, systemPrompt: "Be brief.")
        #expect(pairs(context) == [
            "system: Be brief.\n\nSummary of the conversation so far:\n\nS1",
            "user: two", "assistant: re two",
        ])
    }

    @Test func onlyTheNewestSummaryCounts() {
        let twice = history + [ChatMessage(role: .summary, content: "S2"), ChatMessage(role: .user, content: "three")]
        #expect(pairs(Compaction.context(of: twice, systemPrompt: "")) == [
            "system: Summary of the conversation so far:\n\nS2", "user: three",
        ])
    }

    @Test func theRequestCarriesThePreviousSummaryAndTheFocus() {
        let request = Compaction.request(for: history, focus: "the numbers")
        #expect(request.count == 4)
        #expect(request[0].role == .system)
        #expect(request[0].content.hasPrefix(Compaction.instructions))
        #expect(request[0].content.hasSuffix("S1"), "a second compaction folds in the first")
        #expect(pairs(Array(request[1...2])) == ["user: two", "assistant: re two"])
        #expect(request[3].role == .user && request[3].content.hasSuffix("Make sure it keeps: the numbers"))
        #expect(!request.contains { $0.role == .summary }, "summaries never reach the wire")
    }

    @Test func nothingNewMeansNothingToCompact() {
        #expect(!Compaction.hasNewMessages([]))
        #expect(Compaction.hasNewMessages(history))
        #expect(!Compaction.hasNewMessages(Array(history.prefix(3))))
    }
}
