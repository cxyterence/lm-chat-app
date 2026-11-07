import Testing
@testable import ChatCore

struct SSEDecoderTests {
    let decoder = SSEDecoder()

    @Test func content() throws {
        let events = try decoder.decode(line: #"data: {"choices":[{"delta":{"content":"hi"}}]}"#)
        #expect(events == [.content("hi")])
    }

    @Test func reasoningContent() throws {
        let events = try decoder.decode(line: #"data: {"choices":[{"delta":{"reasoning_content":"hm"}}]}"#)
        #expect(events == [.reasoning("hm")])
    }

    @Test func ollamaReasoning() throws {
        let events = try decoder.decode(line: #"data:{"choices":[{"delta":{"reasoning":"hm"}}]}"#)
        #expect(events == [.reasoning("hm")])
    }

    @Test func finishReason() throws {
        let events = try decoder.decode(line: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        #expect(events == [.done(finishReason: "stop")])
    }

    @Test func doneSentinel() throws {
        #expect(try decoder.decode(line: "data: [DONE]") == [.done(finishReason: nil)])
    }

    @Test(arguments: ["", ": keep-alive", "event: message", "id: 3"])
    func ignored(line: String) throws {
        #expect(try decoder.decode(line: line).isEmpty)
    }

    @Test func usageChunkWithoutChoices() throws {
        #expect(try decoder.decode(line: #"data: {"choices":[],"usage":{}}"#).isEmpty)
    }

    @Test(arguments: [
        #"data: {"error":{"message":"boom","type":"x"}}"#,
        #"data: {"error":"boom"}"#,
    ])
    func errorEnvelope(line: String) {
        #expect(throws: ChatClientError.server("boom")) { try decoder.decode(line: line) }
    }

    @Test func malformedJSON() {
        #expect(throws: ChatClientError.invalidResponse) { try decoder.decode(line: "data: {oops") }
    }
}
