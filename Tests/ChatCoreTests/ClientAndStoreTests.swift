import Testing
@testable import ChatCore

struct ClientAndStoreTests {
    @Test func requestShape() throws {
        let config = try ServerConfig.parse(baseURL: "h:1", apiKey: "sk-1")
        let messages = [
            ChatMessage(role: .system, content: "be brief"),
            ChatMessage(role: .assistant, content: "yo", reasoning: "secret thoughts"),
        ]
        let request = try ChatClient(config: config).chatRequest(model: "m", messages: messages)

        #expect(request.url?.absoluteString == "http://h:1/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        let json = try #require(jsonObject(request.httpBody))
        #expect(json["stream"] as? Bool == true)
        #expect(json["model"] as? String == "m")
        let wire = try #require(json["messages"] as? [[String: Any]])
        #expect(wire.map { $0["role"] as? String } == ["system", "assistant"])
        #expect(wire.allSatisfy { Set($0.keys) == ["role", "content"] })
    }

    @Test func reasoningEffortIsOmittedUnlessSet() throws {
        let client = ChatClient(config: try ServerConfig.parse(baseURL: "h:1", apiKey: ""))
        let none = try #require(jsonObject(client.chatRequest(model: "m", messages: []).httpBody))
        #expect(none["reasoning_effort"] == nil)
        let low = try #require(jsonObject(client.chatRequest(model: "m", messages: [], reasoningEffort: .low).httpBody))
        #expect(low["reasoning_effort"] as? String == "low")
    }

    @Test func noAuthHeaderWithoutKey() throws {
        let config = try ServerConfig.parse(baseURL: "h:1", apiKey: "")
        let request = try ChatClient(config: config).chatRequest(model: "m", messages: [])
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func persistenceRoundTrip() throws {
        let (url, cleanup) = makeTempFileURL("nested/conversations.json")
        defer { cleanup() }

        #expect(try ConversationStore.load(from: url).isEmpty)

        let saved = [
            Conversation(title: "A", model: "m", messages: [
                ChatMessage(role: .user, content: "hi", createdAt: date(1_700_000_001)),
                ChatMessage(role: .assistant, content: "yo", reasoning: "r", createdAt: date(1_700_000_002)),
            ], updatedAt: date(1_700_000_000)),
            Conversation(title: "B", updatedAt: date(1_700_000_003)),
        ]
        try ConversationStore.save(saved, to: url)
        #expect(try ConversationStore.load(from: url) == saved)
    }

    @Test(arguments: [
        ("hello", "hello"),
        ("\n  first line \nsecond", "first line"),
        ("", "New Chat"),
        (String(repeating: "a", count: 60), String(repeating: "a", count: 40) + "…"),
    ])
    func titles(input: String, expected: String) {
        #expect(Conversation.title(fromFirstUserMessage: input) == expected)
    }
}
