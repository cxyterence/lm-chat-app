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

    /// A chat model that calls `web_search` for "swift 6" when it is offered the tool, and answers the result by repeating it.
    private func searchingModel(serper: @escaping @Sendable (String) -> (Int, String)
                                    = { query in (200, serperPage(["about " + query])) }) -> StubServer {
        StubServer(search: serper) { body in
            if lastRole(body) == "tool" { return (200, sse(["done: ", transcript(body).last?.text ?? ""])) }
            guard offeredTools(body).contains("web_search") else { return (200, sse(["no tool"])) }
            return (200, toolCallReply("web_search", arguments: #"{"query": "swift 6"}"#))
        }
    }

    @Test func theToolIsOfferedOnlyWhileTheToggleIsOnAndAKeyIsSavedAndTheChoiceIsKept() async throws {
        let server = searchingModel()
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        #expect(rig.store.searchesWeb == false)

        rig.store.setSearchesWeb(true)
        rig.store.send("no key yet")
        await untilIdle(rig.store)
        #expect(offeredTools(try #require(server.chats.last)) == [], "nothing runs the tool without a key")

        useSerper(rig.store, at: server)
        #expect(rig.reopened().searchesWeb)
        rig.store.send("now with a key")
        await untilIdle(rig.store)
        #expect(server.chats.contains { offeredTools($0) == ["web_search"] })

        rig.store.setSearchesWeb(false)
        #expect(rig.reopened().searchesWeb == false)
        let asked = server.chats.count
        rig.store.send("off again")
        await untilIdle(rig.store)
        #expect(offeredTools(try #require(server.chats.last)) == [])
        #expect(server.chats.count == asked + 1)
    }

    @Test func theModelSearchesWithItsOwnQueryAndReadsNumberedResults() async throws {
        let server = searchingModel()
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }
        useSerper(store, at: server)
        store.setSearchesWeb(true)

        store.send("what's new in swift?")
        await untilIdle(store)

        #expect(server.searches == ["swift 6"])
        let messages = try #require(store.selectedConversation?.messages)
        #expect(messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(messages[0].search == nil, "the question itself is sent as typed")
        let call = try #require(messages[1].toolCalls.first)
        #expect(call.name == "web_search" && call.server == "swift 6", "the row shows the query")
        #expect(call.result?.isError == false)
        #expect(call.result?.text.contains("[1] about swift 6\nhttps://example.com/0\nAbout about swift 6.") == true)
        #expect(call.result?.text.contains("Cite sources inline") == true)
        #expect(messages[2].content.hasPrefix("done: Results retrieved"))
    }

    @Test func aFailedSearchIsAnErrorTheModelReads() async throws {
        let server = searchingModel(serper: { _ in (403, #"{"message":"Unauthorized."}"#) })
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }
        useSerper(store, at: server)
        store.setSearchesWeb(true)

        store.send("what's new in swift?")
        await untilIdle(store)

        let call = try #require(store.selectedConversation?.messages[1].toolCalls.first)
        #expect(call.result?.isError == true)
        #expect(call.result?.text.contains("rejected the API key") == true)
        #expect(store.selectedConversation?.messages.last?.content.contains("rejected the API key") == true)
    }
}
