import Foundation
import Testing
@testable import ChatCore

/// A server that stops talking after the finish reason must not leave the reply streaming.
struct StreamFinishTests {
    private let hello = [ChatMessage(role: .user, content: "hi")]
    private let content = #"{"choices":[{"delta":{"content":"Hi"}}]}"#
    private let finish = #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
    private let counts = #"{"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2}}"#

    private func lines(_ chunks: [String]) -> String { chunks.map { "data: \($0)\n\n" }.joined() }

    private func consume(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    /// The events, or nil when the stream was still going after `seconds`.
    private func ended(within seconds: Int, _ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> (events: [StreamEvent], took: Duration)? {
        let start = ContinuousClock.now
        return try await withThrowingTaskGroup(of: [StreamEvent]?.self) { group in
            group.addTask { try await consume(stream) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            guard let events = try await group.next() ?? nil else { return nil }
            return (events, ContinuousClock.now - start)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aConnectionLeftOpenAfterTheFinishReasonEndsTheReplyWithItsContentIntact() async throws {
        let server = StubServer(holdsOpen: true) { _ in (200, self.lines([self.content, self.finish])) }
        let recorder = Recorder()
        let result = try await ended(within: 8, server.makeClient(apiKey: "", record: recorder.sink).stream(model: "m", messages: hello))

        let (events, took) = try #require(result, "still streaming 8 s after the finish reason")
        #expect(events == [.content("Hi"), .done(finishReason: "stop")])
        #expect(took < .seconds(4))
        let exchange = try #require(await recorder.wait(for: 1).first)
        #expect(exchange.error == nil && exchange.finishedAt != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func tokenCountsEndTheReplyAtOnceEvenWhenTheConnectionStaysOpen() async throws {
        let server = StubServer(holdsOpen: true) { _ in (200, self.lines([self.content, self.finish, self.counts])) }
        let recorder = Recorder()
        let result = try await ended(within: 8, server.makeClient(apiKey: "", record: recorder.sink).stream(model: "m", messages: hello))

        let (events, took) = try #require(result, "still streaming 8 s after the token counts")
        #expect(events == [.content("Hi"), .done(finishReason: "stop"), .usage(Usage(promptTokens: 4, completionTokens: 2))])
        #expect(took < .seconds(1.5), "no waiting for the grace period")
        #expect(try #require(await recorder.wait(for: 1).first).usage == Usage(promptTokens: 4, completionTokens: 2))
    }

    @Test func aLineThatIsNotJSONAfterTheFinishReasonDoesNotFailTheReply() async throws {
        let text = lines([content, finish, "<html>gateway closing</html>", counts, "[DONE]"])
        let server = StubServer { _ in (200, text) }
        let received = try await consume(server.client.stream(model: "m", messages: hello))
        #expect(received == [.content("Hi"), .done(finishReason: "stop"), .usage(Usage(promptTokens: 4, completionTokens: 2))])
    }

    @Test func aLineThatIsNotJSONBeforeTheFinishReasonStillFails() async throws {
        let server = StubServer { _ in (200, "data: <html>oops</html>\n\n") }
        await #expect(throws: ChatClientError.invalidResponse) { try await consume(server.client.stream(model: "m", messages: hello)) }
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func aStreamIsReadWhicheverLineEndingItUses(ending: String) async throws {
        let text = [content, finish, counts, "[DONE]"].map { "data: \($0)" + ending + ending }.joined()
        let server = StubServer { _ in (200, text) }
        let received = try await consume(server.client.stream(model: "m", messages: hello))
        #expect(received == [.content("Hi"), .done(finishReason: "stop"), .usage(Usage(promptTokens: 4, completionTokens: 2))])
    }

    @Test func linesEndOnCRLFOrCRLFAndACRLFIsOneEnding() {
        var buffer = LineBuffer()
        let lines = Array("a\r\nb\rc\nd\r\n\r\ne".utf8).compactMap { buffer.push($0) } + [buffer.flush()].compactMap { $0 }
        #expect(lines == ["a", "b", "c", "d", "", "e"])
    }
}
