import Testing
@testable import ChatCore

struct ImageMessageTests {
    private func wireMessages(_ messages: [ChatMessage]) throws -> [[String: Any]] {
        let client = ChatClient(config: try ServerConfig.parse(baseURL: "h:1", apiKey: ""))
        let json = try #require(jsonObject(client.chatRequest(model: "m", messages: messages).httpBody))
        return try #require(json["messages"] as? [[String: Any]])
    }

    @Test func imagesGoAsDataURLPartsBeforeTheText() throws {
        let message = ChatMessage(role: .user, content: "what is this?", images: [bytes("one"), bytes("two")])
        let parts = try #require(wireMessages([message]).first?["content"] as? [[String: Any]])

        #expect(parts.map { $0["type"] as? String } == ["image_url", "image_url", "text"])
        let urls = parts.compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
        #expect(urls == ["data:image/jpeg;base64,b25l", "data:image/jpeg;base64,dHdv"])
        #expect(parts.last?["text"] as? String == "what is this?")
    }

    @Test func anImageWithoutTextSendsOnlyTheImage() throws {
        let parts = try #require(
            wireMessages([ChatMessage(role: .user, content: "", images: [bytes("x")])]).first?["content"] as? [[String: Any]]
        )
        #expect(parts.map { $0["type"] as? String } == ["image_url"])
    }

    @Test func textOnlyMessagesStayPlainStrings() throws {
        let wire = try wireMessages([ChatMessage(role: .user, content: "hi")])
        #expect(wire.first?["content"] as? String == "hi")
    }

    @Test func imagesSurviveSaveAndLoad() throws {
        let (url, cleanup) = makeTempFileURL("conversations.json")
        defer { cleanup() }
        let saved = [Conversation(messages: [ChatMessage(role: .user, content: "", images: [bytes("jpeg")], createdAt: date(1))],
                                  updatedAt: date(2))]
        try ConversationStore.save(saved, to: url)
        #expect(try ConversationStore.load(from: url) == saved)
    }

    @Test func chatsSavedBeforeImagesLoadWithNone() throws {
        let (url, cleanup) = makeTempFileURL("conversations.json")
        defer { cleanup() }
        try write("""
            [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","messages":[{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF",\
            "role":"user","content":"hi","reasoning":"","createdAt":"2025-01-01T00:00:00Z"}],"updatedAt":"2025-01-01T00:00:00Z"}]
            """, to: url)
        let message = try #require(ConversationStore.load(from: url).first?.messages.first)
        #expect(message.content == "hi")
        #expect(message.images.isEmpty)
    }
}
