import ChatCore
import Testing
@testable import ChatUI

@MainActor
struct WebSearchTests {
    @Test func needsAKey() {
        let (store, cleanup) = makeStore(server: echoServer())
        defer { cleanup() }
        #expect(store.unavailableReason(.webSearch)?.contains("Serper") == true)
        store.setServiceKey(.serper, "  k  ")
        #expect(store.unavailableReason(.webSearch) == nil)
        #expect(store.serviceKey(.serper) == "k", "trimmed")
        store.setServiceKey(.serper, "")
        #expect(store.unavailableReason(.webSearch) != nil)
    }

    @Test func searchesThenAnswersFromTheResults() async throws {
        let server = StubServer(search: { _ in (200, serperPage(["Swift 6.2 released", "What's new"])) }) { body in
            (200, sse(["answer"]))
        }
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }
        useSerper(store, at: server)

        store.run(.webSearch, argument: "latest swift version")
        await untilIdle(store)

        #expect(server.searches == ["latest swift version"])
        let question = try #require(store.selectedConversation?.messages.first)
        #expect(question.content == "latest swift version")
        #expect(question.search?.results?.map(\.title) == ["Swift 6.2 released", "What's new"])
        #expect(store.selectedConversation?.messages.last?.content == "answer")

        let request = try #require(server.chats.last)
        let sent = try #require(transcript(request).last)
        #expect(sent.text.contains("[1] Swift 6.2 released\nhttps://example.com/0\nAbout Swift 6.2 released."))
        #expect(sent.text.hasSuffix("Question: latest swift version"))
    }

    @Test func aFailedSearchShowsWhyAndRetrySearchesAgain() async throws {
        let server = StubServer(search: { _ in (403, #"{"message":"Unauthorized."}"#) }) { _ in (200, sse(["x"])) }
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }
        useSerper(store, at: server)

        store.run(.webSearch, argument: "q")
        await untilIdle(store)
        let id = try #require(store.selection)
        #expect(store.failureMessage(for: id)?.contains("rejected the API key") == true)
        #expect(server.chats.isEmpty, "the model isn't asked without results")

        store.retry()
        await untilIdle(store)
        #expect(server.searches == ["q", "q"])
    }

    @Test func editingASearchSearchesForTheNewText() async throws {
        let server = StubServer(search: { query in (200, serperPage(["about " + query])) }) { _ in (200, sse(["ok"])) }
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }
        useSerper(store, at: server)
        store.run(.webSearch, argument: "cats")
        await untilIdle(store)

        let question = try #require(store.selectedConversation?.messages.first)
        store.edit(question.id, to: "dogs")
        await untilIdle(store)
        #expect(server.searches == ["cats", "dogs"])
        #expect(store.selectedConversation?.messages.first?.search?.results?.first?.title == "about dogs")
    }

    @Test func anArgumentIsRequired() {
        let server = echoServer()
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }
        useSerper(store, at: server)
        store.run(.webSearch, argument: "")
        #expect(store.selectedConversation?.messages.isEmpty != false)
    }
}
