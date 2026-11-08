import Testing
@testable import ChatCore

struct ImageMessageTests {
    private func wireMessages(_ messages: [ChatMessage], images: ImageStore) throws -> [[String: Any]] {
        let client = ChatClient(config: try ServerConfig.parse(baseURL: "h:1", apiKey: ""))
        let json = try #require(jsonObject(client.chatRequest(model: "m", messages: messages, images: images).httpBody))
        return try #require(json["messages"] as? [[String: Any]])
    }

    @Test func imagesGoAsDataURLPartsBeforeTheText() throws {
        let (store, cleanup) = makeImageStore()
        defer { cleanup() }
        let message = ChatMessage(role: .user, content: "what is this?",
                                  images: [try store.save(bytes("one")), try store.save(bytes("two"))])
        let parts = try #require(wireMessages([message], images: store).first?["content"] as? [[String: Any]])

        #expect(parts.map { $0["type"] as? String } == ["image_url", "image_url", "text"])
        let urls = parts.compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
        #expect(urls == ["data:image/jpeg;base64,b25l", "data:image/jpeg;base64,dHdv"])
        #expect(parts.last?["text"] as? String == "what is this?")
    }

    @Test func anImageWithoutTextSendsOnlyTheImage() throws {
        let (store, cleanup) = makeImageStore()
        defer { cleanup() }
        let message = ChatMessage(role: .user, content: "", images: [try store.save(bytes("x"))])
        let parts = try #require(wireMessages([message], images: store).first?["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["image_url"])
    }

    @Test func aMissingPhotoIsLeftOutInsteadOfFailingTheRequest() throws {
        let (store, cleanup) = makeImageStore()
        defer { cleanup() }
        let gone = try store.save(bytes("gone"))
        store.remove([gone])
        let wire = try wireMessages([ChatMessage(role: .user, content: "hi", images: [gone])], images: store)
        #expect(wire.first?["content"] as? String == "hi")
    }

    @Test func textOnlyMessagesStayPlainStrings() throws {
        let (store, cleanup) = makeImageStore()
        defer { cleanup() }
        #expect(try wireMessages([ChatMessage(role: .user, content: "hi")], images: store).first?["content"] as? String == "hi")
    }

    @Test func theChatFileHoldsPhotoIDsNotPhotos() throws {
        let (url, cleanup) = makeTempFileURL("conversations.json")
        let (store, cleanStore) = makeImageStore()
        defer { cleanup(); cleanStore() }
        let photo = String(repeating: "p", count: 100_000)
        let saved = [Conversation(messages: [ChatMessage(role: .user, content: "", images: [try store.save(bytes(photo))],
                                                         createdAt: date(1))], updatedAt: date(2))]
        try ConversationStore.save(saved, to: url)

        #expect(fileSize(url) < 2_000)
        let loaded = try ConversationStore.load(from: url, images: store)
        #expect(loaded == saved)
        #expect(store.data(for: loaded[0].messages[0].images[0]) == bytes(photo))
    }

    @Test func chatsSavedBeforeImagesLoadWithNone() throws {
        let (url, cleanup) = makeTempFileURL("conversations.json")
        defer { cleanup() }
        try write(oldChat(images: nil), to: url)
        let message = try #require(ConversationStore.load(from: url).first?.messages.first)
        #expect(message.content == "hi")
        #expect(message.images.isEmpty)
    }

    @Test func photosSavedInlineMoveIntoTheStore() throws {
        let (url, cleanup) = makeTempFileURL("conversations.json")
        let (store, cleanStore) = makeImageStore()
        defer { cleanup(); cleanStore() }
        try write(oldChat(images: #"["anBlZw=="]"#), to: url)
        let id = try #require(ConversationStore.load(from: url, images: store).first?.messages.first?.images.first)
        #expect(store.data(for: id) == bytes("jpeg"))
    }

    @Test func sweepingKeepsOnlyReferencedPhotos() throws {
        let (store, cleanup) = makeImageStore()
        defer { cleanup() }
        let kept = try store.save(bytes("a")), dropped = try store.save(bytes("b"))
        store.removeAll(except: [kept])
        #expect(store.data(for: kept) != nil)
        #expect(store.data(for: dropped) == nil)
    }

    private func oldChat(images: String?) -> String {
        let field = images.map { #","images":\#($0)"# } ?? ""
        return """
            [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","messages":[{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF",\
            "role":"user","content":"hi","reasoning":"","createdAt":"2025-01-01T00:00:00Z"\(field)}],"updatedAt":"2025-01-01T00:00:00Z"}]
            """
    }
}
