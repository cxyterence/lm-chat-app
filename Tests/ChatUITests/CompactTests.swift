import ChatCore
import Testing
@testable import ChatUI

@MainActor
struct CompactTests {
    private func roles(_ store: ChatStore) -> [Role] { store.selectedConversation?.messages.map(\.role) ?? [] }

    /// Answers a summary request with "SUMMARY" and echoes anything else.
    private func server(failSummaries: Bool = false) -> StubServer {
        StubServer { body in
            let last = transcript(body).last?.text ?? ""
            if last.hasPrefix("Summarize the conversation") {
                return failSummaries ? (500, #"{"error":{"message":"overloaded"}}"#) : (200, sse(["SUMM", "ARY"]))
            }
            return (200, sse(["re: ", last]))
        }
    }

    @Test func compactingAddsASummaryTheNextReplyIsBuiltOn() async throws {
        let stub = server()
        let (store, cleanup) = makeStore(server: stub)
        defer { cleanup() }
        #expect(store.unavailableReason(.compact) != nil, "nothing to compact in an empty chat")
        store.send("one")
        await untilIdle(store)
        #expect(store.unavailableReason(.compact) == nil)

        store.run(.compact, argument: "the number one")
        await untilIdle(store)
        #expect(roles(store) == [.user, .assistant, .summary])
        #expect(store.selectedConversation?.messages.last?.content == "SUMMARY")
        let request = try #require(stub.chats.last)
        #expect(transcript(request).last?.text.hasSuffix("Make sure it keeps: the number one") == true)
        #expect(store.unavailableReason(.compact) != nil, "nothing new since the summary")

        store.send("two")
        await untilIdle(store)
        let followUp = try #require(stub.chats.last)
        #expect(transcript(followUp).map(\.role) == ["system", "user"])
        #expect(transcript(followUp)[0].text.hasSuffix("SUMMARY"))
        #expect(store.selectedConversation?.messages.map(\.content).first == "one", "earlier messages stay on screen")
    }

    @Test func aFailedSummaryLeavesTheChatAsItWasAndRetries() async throws {
        let (store, cleanup) = makeStore(server: server(failSummaries: true))
        defer { cleanup() }
        store.send("one")
        await untilIdle(store)
        store.run(.compact, argument: "")
        await untilIdle(store)

        let id = try #require(store.selection)
        #expect(roles(store) == [.user, .assistant])
        #expect(store.failureMessage(for: id)?.contains("overloaded") == true)

        store.retry()
        await untilIdle(store)
        #expect(roles(store) == [.user, .assistant], "retry compacts again rather than re-asking the last prompt")
        #expect(store.failureMessage(for: id) != nil)
    }

    @Test func stoppingAHalfWrittenSummaryDiscardsIt() async throws {
        let (store, cleanup) = makeStore(server: StubServer { body in
            let last = transcript(body).last?.text ?? ""
            return last.hasPrefix("Summarize") ? (200, "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n")
                                               : (200, sse(["ok"]))
        })
        defer { cleanup() }
        store.send("one")
        await untilIdle(store)
        store.run(.compact, argument: "")
        store.stop()
        await untilIdle(store)
        #expect(roles(store) == [.user, .assistant])
    }

    @Test func aSummaryCutOffByTheOutputLimitIsDiscarded() async throws {
        let (store, cleanup) = makeStore(server: StubServer { body in
            guard transcript(body).last?.text.hasPrefix("Summarize") == true else { return (200, sse(["ok"])) }
            return (200, "data: {\"choices\":[{\"delta\":{\"content\":\"half a summ\"},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n")
        })
        defer { cleanup() }
        store.send("one")
        await untilIdle(store)
        store.run(.compact, argument: "")
        await untilIdle(store)
        #expect(roles(store) == [.user, .assistant])
        #expect(store.failureMessage(for: try #require(store.selection))?.contains("cut off") == true)
    }
}
