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

    @Test func usageChunkCarriesTheCounts() throws {
        let line = #"data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18,"completion_tokens_details":{"reasoning_tokens":3}}}"#
        #expect(try decoder.decode(line: line) == [.usage(Usage(promptTokens: 11, completionTokens: 7, reasoningTokens: 3))])
    }

    @Test func nullUsageOnEveryOtherChunkSaysNothing() throws {
        #expect(try decoder.decode(line: #"data: {"choices":[{"delta":{"content":"hi"}}],"usage":null}"#) == [.content("hi")])
    }

    @Test func aUsageBlockInAnUnexpectedShapeDoesNotBreakTheReply() throws {
        let line = #"data: {"choices":[{"delta":{"content":"hi"}}],"usage":{"prompt_tokens":"many"}}"#
        #expect(try decoder.decode(line: line) == [.content("hi")])
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
