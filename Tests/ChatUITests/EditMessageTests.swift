import ChatCore
import Testing
@testable import ChatUI

@MainActor
struct EditMessageTests {
    private func texts(_ store: ChatStore) -> [String] { store.selectedConversation?.messages.map(\.content) ?? [] }

    @Test func editingResendsAndErasesWhatFollowed() async throws {
        let server = echoServer()
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }
        store.send("first")
        await untilIdle(store)
        store.send("second")
        await untilIdle(store)
        #expect(texts(store) == ["first", "re: first", "second", "re: second"])

        let first = try #require(store.selectedConversation?.messages.first)
        store.edit(first.id, to: "first, edited")
        await untilIdle(store)

        #expect(texts(store) == ["first, edited", "re: first, edited"])
        let last = try #require(server.chats.last)
        #expect(transcript(last).map(\.text) == ["first, edited"])
        #expect(store.selectedConversation?.messages.first?.id == first.id, "the message is edited in place")
    }

    @Test func editingAMiddleMessageKeepsEarlierOnes() async throws {
        let server = echoServer()
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }
        for prompt in ["one", "two", "three"] {
            store.send(prompt)
            await untilIdle(store)
        }
        let two = try #require(store.selectedConversation?.messages[2])
        store.edit(two.id, to: "TWO")
        await untilIdle(store)

        #expect(texts(store) == ["one", "re: one", "TWO", "re: TWO"])
        let last = try #require(server.chats.last)
        #expect(transcript(last).map(\.text) == ["one", "re: one", "TWO"])
    }

    @Test func photosNoLongerSentAreDeleted() async throws {
        let (store, cleanup) = makeStore(server: echoServer())
        defer { cleanup() }
        let kept = try store.images.save(bytes("kept")), removed = try store.images.save(bytes("removed"))
        let later = try store.images.save(bytes("later"))
        store.send("look", images: [kept, removed])
        await untilIdle(store)
        store.send("and this", images: [later])
        await untilIdle(store)

        let first = try #require(store.selectedConversation?.messages.first)
        store.edit(first.id, to: "look again", images: [kept])
        await untilIdle(store)

        #expect(store.selectedConversation?.messages.first?.images == [kept])
        #expect(store.images.data(for: kept) != nil)
        #expect(store.images.data(for: removed) == nil, "removed from the edited message")
        #expect(store.images.data(for: later) == nil, "belonged to an erased message")
    }

    @Test func anEmptyEditChangesNothing() async throws {
        let (store, cleanup) = makeStore(server: echoServer())
        defer { cleanup() }
        store.send("hello")
        await untilIdle(store)
        let first = try #require(store.selectedConversation?.messages.first)
        store.edit(first.id, to: "   ")
        #expect(texts(store) == ["hello", "re: hello"])
    }
}
