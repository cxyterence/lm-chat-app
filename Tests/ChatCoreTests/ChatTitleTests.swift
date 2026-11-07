import Testing
@testable import ChatCore

struct ChatTitleTests {
    @Test(arguments: [
        ("NVFP4 Quantization Basics", "NVFP4 Quantization Basics"),
        ("\"NVFP4 Quantization Basics.\"", "NVFP4 Quantization Basics"),
        ("Title: **NVFP4 basics**\nIt covers scales.", "NVFP4 basics"),
        ("## What is NVFP4?", "What is NVFP4?"),
        ("\n\n  “Tail calls” \n", "Tail calls"),
    ])
    func cleansDecoratedTitles(raw: String, expected: String) {
        #expect(ChatTitle.clean(raw) == expected)
    }

    @Test func blankOrPunctuationOnlyIsNoTitle() {
        #expect(ChatTitle.clean("  \n\n") == nil)
        #expect(ChatTitle.clean("\"...\"") == nil)
    }

    @Test func longTitlesAreCut() {
        #expect(ChatTitle.clean(String(repeating: "word ", count: 30)) == String(repeating: "word ", count: 12).trimmingCharacters(in: .whitespaces) + "…")
    }

    @Test func asksForLowEffortAndIgnoresThinking() async throws {
        let server = StubServer { _ in (200, sse(["<think>short plan</think>", "\"NVFP4 ", "Basics.\""])) }
        let title = try await server.client.title(model: "m", for: "what do you know about NVFP4?")
        #expect(title == "NVFP4 Basics")
        #expect(server.bodies.map { $0["reasoning_effort"] as? String } == ["low"])
        let messages = try #require(server.bodies.first?["messages"] as? [[String: Any]])
        #expect((messages.last?["content"] as? String)?.contains("what do you know about NVFP4?") == true)
    }

    @Test func retriesWithoutEffortWhenTheServerRejectsIt() async throws {
        let server = StubServer { body in
            body["reasoning_effort"] == nil
                ? (200, sse(["Quantization basics"]))
                : (400, #"{"error":{"message":"Supported types are xhigh (default), medium."}}"#)
        }
        #expect(try await server.client.title(model: "m", for: "hi") == "Quantization basics")
        #expect(server.bodies.map { $0["reasoning_effort"] as? String } == ["low", nil])
    }

    @Test func otherFailuresAreNotRetried() async {
        let server = StubServer { _ in (500, #"{"error":{"message":"boom"}}"#) }
        await #expect(throws: ChatClientError.self) { try await server.client.title(model: "m", for: "hi") }
        #expect(server.bodies.count == 1)
    }
}
