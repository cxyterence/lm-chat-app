import ChatCore
import Foundation
import Testing
@testable import ChatUI

@MainActor
struct ImageModelTests {
    private static let listing = #"{"data":[{"id":"m","task_type":"t2i","supported_task_types":["t2i"]}]}"#

    private func picture() -> String {
        #"{"data":[{"b64_json":"\#(makePNG(width: 64, height: 48).base64EncodedString())"}]}"#
    }

    private func imageStore(_ server: StubServer) async -> (store: ChatStore, cleanup: @Sendable () -> Void) {
        server.models = Self.listing
        let made = makeStore(server: server)
        await made.store.refreshModels()
        return made
    }

    @Test func aPromptToAnImageModelComesBackAsAPicture() async throws {
        let server = echoServer()
        let reply = picture()
        server.image = { _ in (200, reply) }
        let (store, cleanup) = await imageStore(server)
        defer { cleanup() }
        #expect(store.makesImages)

        store.send("a red fox in the snow")
        await untilIdle(store)

        #expect(server.drawn.map { $0["prompt"] as? String } == ["a red fox in the snow"])
        #expect(server.drawn.first?["model"] as? String == "m")
        #expect(server.chats.isEmpty, "an image model is never sent a chat request, not even for a title")
        let answer = try #require(store.selectedConversation?.messages.last)
        #expect(answer.role == .assistant)
        let id = try #require(answer.images.first)
        let saved = try #require(store.images.data(for: id).flatMap(imageInfo))
        #expect(saved.type == "public.jpeg")
        #expect(saved.width == 64 && saved.height == 48)
        #expect(store.failureMessage(for: try #require(store.selection)) == nil)
    }

    @Test func aFailureShowsTheServersReasonAndRetryDrawsAgain() async throws {
        let server = echoServer()
        let reply = picture()
        nonisolated(unsafe) var attempts = 0
        server.image = { _ in
            attempts += 1
            return attempts == 1 ? (400, #"{"error":{"message":"Rejected by the safety system."}}"#) : (200, reply)
        }
        let (store, cleanup) = await imageStore(server)
        defer { cleanup() }

        store.send("a fox")
        await untilIdle(store)
        let id = try #require(store.selection)
        #expect(store.failureMessage(for: id)?.contains("Rejected by the safety system.") == true)
        #expect(store.selectedConversation?.messages.map(\.role) == [.user], "no empty reply is left behind")

        store.retry()
        await untilIdle(store)
        #expect(store.failureMessage(for: id) == nil)
        #expect(store.selectedConversation?.messages.last?.images.count == 1)
    }

    @Test func aReplyThatIsNotAPictureIsAFailure() async throws {
        let server = echoServer()
        server.image = { _ in (200, #"{"data":[{"b64_json":"bm90IGFuIGltYWdl"}]}"#) }
        let (store, cleanup) = await imageStore(server)
        defer { cleanup() }
        store.send("a fox")
        await untilIdle(store)
        #expect(store.failureMessage(for: try #require(store.selection))?.contains("wasn't a picture") == true)
    }

    @Test func textCommandsAreUnavailable() async {
        let (store, cleanup) = await imageStore(echoServer())
        defer { cleanup() }
        store.setServiceKey(.serper, "k")
        #expect(store.unavailableReason(.webSearch) == "Not available with an image model")
        #expect(store.unavailableReason(.compact) == "Not available with an image model")
        #expect(store.effortLevels == .known([]))
    }

    @Test func aTextModelOnTheSameServerStillChats() async throws {
        let server = echoServer()
        server.models = #"{"data":[{"id":"m","task_type":"t2i"},{"id":"qwen"}]}"#
        server.image = { _ in (500, "") }
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }
        await store.refreshModels()
        store.selectModel("qwen")
        #expect(!store.makesImages)

        store.send("hello")
        await untilIdle(store)
        #expect(store.selectedConversation?.messages.last?.content == "re: hello")
        #expect(server.drawn.isEmpty)

        store.selectModel("m")
        #expect(store.makesImages)
    }

    @Test func connectionsSavedBeforeImageModelsStillLoad() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"n","baseURL":"http://h/v1","model":"m","systemPrompt":""}"#
        let connection = try JSONDecoder().decode(Connection.self, from: Data(old.utf8))
        #expect(connection.model == "m")
        #expect(!connection.makesImages)
    }
}
