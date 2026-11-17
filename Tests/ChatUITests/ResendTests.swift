import ChatCore
import Foundation
import Testing
@testable import ChatUI

@MainActor
struct ResendTests {
    private func reply(_ store: ChatStore) throws -> ChatMessage {
        try #require(store.selectedConversation?.messages.first { $0.role == .assistant })
    }

    private func echo() -> StubServer {
        StubServer { body in (200, sse(["re: ", transcript(body).last { $0.role == "user" }?.text ?? ""])) }
    }

    @Test func anEditedRequestIsSentAndItsAnswerJoinsTheSameReplyWithoutTouchingTheChat() async throws {
        let server = echo()
        let rig = Rig(server: server, key: "chat-key")
        defer { rig.cleanup() }
        rig.store.send("hello")
        await untilIdle(rig.store)
        let message = try reply(rig.store)
        let original = try #require(rig.store.exchanges(for: message.id).first)
        let before = rig.store.selectedConversation?.messages

        let edited = original.displayBody.replacingOccurrences(of: "\"hello\"", with: "\"Reply with exactly the word PINEAPPLE.\"")
        let sent = await rig.store.resend(original, editedText: edited, for: message.id)

        #expect(sent.purpose == .resend && sent.status == 200 && sent.error == nil)
        #expect(sent.responseBody.contains("PINEAPPLE"))
        #expect(rig.store.exchanges(for: message.id).map(\.id) == [original.id, sent.id])
        #expect(rig.store.selectedConversation?.messages == before, "no message was added, changed or removed")
        #expect(server.chats.last.map(transcript)?.last?.text == "Reply with exactly the word PINEAPPLE.")
        let credentials = server.authorizations.filter { $0.path.hasSuffix("chat/completions") }
        #expect(credentials.last?.authorization == "Bearer chat-key", "the connection's own key goes with it")
        #expect(sent.requestHeader("Authorization") == "Bearer $API_KEY")
        #expect(!(sent.curl + sent.responseBody + sent.displayBody).contains("chat-key"))
    }

    @Test func aRequestThatFailsIsKeptAsAFailedRowAndTheChatIsStillUntouched() async throws {
        let server = echo()
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        rig.store.send("hello")
        await untilIdle(rig.store)
        let message = try reply(rig.store)
        let original = try #require(rig.store.exchanges(for: message.id).first)
        let before = rig.store.selectedConversation?.messages

        let sent = await rig.store.resend(original, editedText: "{ not json", for: message.id)

        #expect(sent.purpose == .resend && sent.error != nil)
        #expect(rig.store.exchanges(for: message.id).last?.id == sent.id)
        #expect(rig.store.selectedConversation?.messages == before)
    }

    @Test func aPictureRequestGoesWithTheImageConnectionsKeyAndAChatRequestWithTheChatOnes() async throws {
        let server = StubServer { body in
            if lastRole(body) == "tool" { return (200, sse(["done"])) }
            return offeredTools(body).contains("generate_image")
                ? (200, toolCallReply("generate_image", arguments: #"{"prompt":"A red fox."}"#)) : (200, sse(["no picture"]))
        }
        let picture = #"{"data":[{"b64_json":"\#(makePNG(width: 64, height: 48).base64EncodedString())"}]}"#
        server.models = #"{"data":[{"id":"img","task_type":"t2i"}]}"#
        server.image = { _ in (200, picture) }
        let rig = Rig(server: server, key: "chat-key")
        defer { rig.cleanup() }
        useImageTool(rig.store, at: server, key: "image-key")

        rig.store.send("draw a fox")
        await untilIdle(rig.store)
        let message = try reply(rig.store)
        let kept = rig.store.exchanges(for: message.id)
        let image = try #require(kept.first { $0.purpose == .image })
        let chat = try #require(kept.first { $0.purpose == .chat })

        func lastKey(_ suffix: String) -> String? { server.authorizations.last { $0.path.hasSuffix(suffix) }?.authorization }
        let drawn = await rig.store.resend(image, editedText: image.displayBody.replacingOccurrences(of: "A red fox.", with: "A blue fox."),
                                          for: message.id)
        #expect(drawn.status == 200 && server.drawn.last?["prompt"] as? String == "A blue fox.")
        #expect(lastKey("images/generations") == "Bearer image-key")

        let again = await rig.store.resend(drawn, editedText: drawn.displayBody, for: message.id)
        #expect(again.status == 200 && lastKey("images/generations") == "Bearer image-key", "resending a resent picture request too")

        _ = await rig.store.resend(chat, editedText: chat.displayBody, for: message.id)
        #expect(lastKey("chat/completions") == "Bearer chat-key")
        #expect(rig.store.exchanges(for: message.id).map(\.purpose) == [.chat, .image, .resend, .resend, .resend])
    }

    @Test func aRequestForAServerNoConnectionHasGoesWithoutAKey() async throws {
        let rig = Rig(server: echo(), key: "chat-key")
        defer { rig.cleanup() }
        rig.store.send("hello")
        await untilIdle(rig.store)
        let message = try reply(rig.store)
        let stranger = StubServer { _ in (200, sse(["hi"])) }
        let foreign = Exchange(purpose: .chat, url: stranger.baseURL.appendingPathComponent("chat/completions"),
                               requestHeaders: [.init(name: "Content-Type", value: "application/json")],
                               requestBody: Data(#"{"model":"m","stream":true,"messages":[]}"#.utf8))

        let sent = await rig.store.resend(foreign, editedText: foreign.displayBody, for: message.id)

        #expect(sent.status == 200)
        #expect(stranger.authorizations.last?.authorization == nil, "the key is for its own server only")
    }

    @Test func aRequestIsResentWithItsOwnMethod() async throws {
        let server = echo()
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        rig.store.send("hello")
        await untilIdle(rig.store)
        let message = try reply(rig.store)
        var original = try #require(rig.store.exchanges(for: message.id).first)
        original.method = "PUT"

        let sent = await rig.store.resend(original, editedText: original.displayBody, for: message.id)

        #expect(sent.method == "PUT")
        #expect(server.methods.last == "PUT")
    }

    @Test func aReplyThatIsGoneTakesNoNewRequests() async throws {
        let rig = Rig(server: echo())
        defer { rig.cleanup() }
        rig.store.send("hello")
        await untilIdle(rig.store)
        let message = try reply(rig.store)
        let original = try #require(rig.store.exchanges(for: message.id).first)
        rig.store.delete(ids: [try #require(rig.store.selection)])

        _ = await rig.store.resend(original, editedText: original.displayBody, for: message.id)

        #expect(rig.store.exchangeLog.count == 0)
    }
}
