import Testing
@testable import ChatCore

struct ImageLabelsTests {
    private let first = ImageID(), second = ImageID(), drawn = ImageID(), last = ImageID()

    private func wireText(_ messages: [ChatMessage]) throws -> [String] {
        let client = ChatClient(config: try ServerConfig.parse(baseURL: "h:1", apiKey: ""))
        let (store, cleanup) = makeImageStore()
        defer { cleanup() }
        let request = try client.chatRequest(model: "m", messages: messages, images: store)
        let wire = try #require(jsonObject(request.httpBody)?["messages"] as? [[String: Any]])
        return wire.map { message in
            if let text = message["content"] as? String { return text }
            return (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        }
    }

    @Test func picturesAreNumberedInMessageOrderPhotosAndDrawnPicturesAlike() {
        let messages = [
            ChatMessage(role: .user, content: "", images: [first, second]),
            ChatMessage(role: .assistant, content: "", images: [drawn]),
            ChatMessage(role: .user, content: "no photos"),
            ChatMessage(role: .user, content: "", images: [last]),
        ]
        #expect(ImageLabels.order(of: messages) == [first, second, drawn, last])
    }

    @Test func aUserMessageWithPhotosEndsWithANoteNamingThem() {
        let messages = [
            ChatMessage(role: .user, content: "what is this?", images: [first, second]),
            ChatMessage(role: .assistant, content: "A fox.", images: [drawn]),
            ChatMessage(role: .user, content: "", images: [last]),
            ChatMessage(role: .user, content: "plain"),
        ]
        let noted = ImageLabels.annotated(messages, order: ImageLabels.order(of: messages))
        #expect(noted.map(\.content) == [
            "what is this?\n\n(Attached: image 1, image 2)", "A fox.", "(Attached: image 4)", "plain",
        ])
    }

    @Test func labelsKeepTheirNumbersAfterACompactionDropsTheEarlierMessages() {
        let messages = [
            ChatMessage(role: .user, content: "look", images: [first]),
            ChatMessage(role: .summary, content: "The user showed a photo."),
            ChatMessage(role: .user, content: "and this", images: [second]),
        ]
        let seen = Compaction.context(of: messages, systemPrompt: "")
        let noted = ImageLabels.annotated(seen, order: ImageLabels.order(of: messages))
        #expect(noted.last?.content == "and this\n\n(Attached: image 2)")
    }

    @Test func theNoteReachesTheWireAfterASearchQuestionsPrompt() throws {
        let messages = [ChatMessage(role: .user, content: "swift news", images: [first], search: WebSearch(query: "swift news", results: []))]
        let text = try #require(try wireText(ImageLabels.annotated(messages, order: [first])).first)
        #expect(text.contains("found nothing") && text.hasSuffix("(Attached: image 1)"))
    }
}
