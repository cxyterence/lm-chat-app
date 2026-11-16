import Foundation
import Testing
@testable import ChatCore

struct StreamUsageTests {
    private let hello = [ChatMessage(role: .user, content: "hi")]
    private let refusal = (400, #"{"error":{"message":"Unrecognized request argument supplied: stream_options"}}"#)

    private func events(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func lines(_ chunks: [String]) -> String { chunks.map { "data: \($0)\n\n" }.joined() }

    @Test func chatRequestsAskForTokenCounts() async throws {
        let server = StubServer { _ in (200, sse(["Hi"])) }
        _ = try await events(server.client.stream(model: "m", messages: hello))
        let options = try #require(server.bodies.first?["stream_options"] as? [String: Any])
        #expect(options["include_usage"] as? Bool == true)
    }

    @Test func countsFollowTheFinishReasonAndAreReadAndReported() async throws {
        let text = lines([
            #"{"choices":[{"delta":{"reasoning_content":"hm"}}],"usage":null}"#,
            #"{"choices":[{"delta":{"content":"Hi"}}],"usage":null}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":null}"#,
            #"{"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18,"completion_tokens_details":{"reasoning_tokens":3}}}"#,
            "[DONE]",
        ])
        let server = StubServer { _ in (200, text) }
        let recorder = Recorder()
        let received = try await events(server.makeClient(apiKey: "", record: recorder.sink).stream(model: "m", messages: hello))

        let usage = Usage(promptTokens: 11, completionTokens: 7, reasoningTokens: 3)
        #expect(received == [.reasoning("hm"), .content("Hi"), .done(finishReason: "stop"), .usage(usage)])
        #expect(recorder.exchanges.first?.usage == usage)
    }

    @Test func aServerThatSplitsNothingOutLeavesReasoningTokensEmpty() async throws {
        let text = lines([#"{"choices":[{"delta":{"content":"Hi"}}]}"#,
                          #"{"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2}}"#, "[DONE]"])
        let server = StubServer { _ in (200, text) }
        let recorder = Recorder()
        _ = try await events(server.makeClient(apiKey: "", record: recorder.sink).stream(model: "m", messages: hello))
        #expect(recorder.exchanges.first?.usage == Usage(promptTokens: 4, completionTokens: 2, reasoningTokens: nil))
    }

    @Test func aServerThatReportsNothingLeavesUsageEmpty() async throws {
        let server = StubServer { _ in (200, sse(["Hi"])) }
        let recorder = Recorder()
        _ = try await events(server.makeClient(apiKey: "", record: recorder.sink).stream(model: "m", messages: hello))
        #expect(recorder.exchanges.first?.usage == nil)
    }

    @Test func aServerThatRefusesStreamOptionsIsAskedAgainWithoutThem() async throws {
        let server = StubServer { $0["stream_options"] == nil ? (200, sse(["Hi"])) : self.refusal }
        let recorder = Recorder()
        let received = try await events(server.makeClient(apiKey: "", record: recorder.sink).stream(model: "m", messages: hello))

        #expect(received == [.adapted(.usageNotRequested), .content("Hi"), .done(finishReason: nil)])
        #expect(server.bodies.map { $0["stream_options"] != nil } == [true, false])
        #expect(recorder.exchanges.map(\.status) == [400, 200], "both attempts are reported, the refused one as a failure")
        #expect(recorder.exchanges.first?.error?.contains("stream_options") == true)
        #expect(recorder.exchanges.allSatisfy { $0.purpose == .chat })
    }

    @Test func aTitleSurvivesTheSameRefusal() async throws {
        let server = StubServer { $0["stream_options"] == nil ? (200, sse(["A fine title"])) : self.refusal }
        #expect(try await server.client.title(model: "m", for: "hello") == "A fine title")
    }

    @Test func aHostKnownToRefuseIsNotAskedAtAll() async throws {
        let server = StubServer { _ in (200, sse(["Hi"])) }
        let received = try await events(server.client.stream(model: "m", messages: hello, includeUsage: false))
        #expect(received == [.content("Hi"), .done(finishReason: nil)])
        #expect(server.bodies.first?["stream_options"] == nil)
    }

    @Test func aRefusalForAnotherReasonIsNotRetried() async throws {
        let server = StubServer { _ in (400, #"{"error":{"message":"tools are not supported"}}"#) }
        await #expect(throws: ChatClientError.http(status: 400, message: "tools are not supported")) {
            try await events(server.client.stream(model: "m", messages: hello))
        }
        #expect(server.bodies.count == 1)
    }

    @Test func theRetryHappensOnce() async throws {
        let server = StubServer { _ in self.refusal }
        await #expect(throws: (any Error).self) { try await events(server.client.stream(model: "m", messages: hello)) }
        #expect(server.bodies.count == 2)
    }

    @Test func aValidationErrorListIsReadAsNamingTheField() async throws {
        let detail = #"{"detail":[{"loc":["body","stream_options"],"msg":"Extra inputs are not permitted"}]}"#
        let server = StubServer { $0["stream_options"] == nil ? (200, sse(["Hi"])) : (422, detail) }
        _ = try await events(server.client.stream(model: "m", messages: hello))
        #expect(server.bodies.count == 2)
    }
}
