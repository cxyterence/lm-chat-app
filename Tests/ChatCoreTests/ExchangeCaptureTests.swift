import Foundation
import Testing
@testable import ChatCore

struct ExchangeCaptureTests {
    private static let key = "sk-stub-secret-123"

    /// Every field of the exchange as one string, to search for what must not be there.
    private func everything(_ exchange: Exchange) -> String {
        "\(exchange)" + String(decoding: exchange.requestBody, as: UTF8.self)
    }

    private func consume(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private let hello = [ChatMessage(role: .user, content: "hi")]

    @Test func everyKindOfRequestIsReportedWithItsPurposeAndNeverTheKey() async throws {
        let server = StubServer(route: { path, body in
            if path.hasSuffix("/models") { return (200, #"{"data":[{"id":"m"}]}"#) }
            if path.hasSuffix("/images/generations") || path.hasSuffix("/images/edits") {
                return (200, #"{"data":[{"url":"/v1/images/x/content"}]}"#)
            }
            if path.hasSuffix("/content") { return (200, "picture") }
            if body["stream"] as? Bool == true { return (200, sse(["Hi"])) }
            return (200, #"{"choices":[{"message":{"content":"H"}}]}"#)
        })
        let recorder = Recorder()
        let client = server.makeClient(apiKey: Self.key, record: recorder.sink)

        _ = try await client.models()
        _ = try await consume(client.stream(model: "m", messages: hello))
        _ = try await client.title(model: "m", for: "hello")
        _ = try await client.reasoningEfforts(model: "m")
        _ = try await client.image(model: "flux", prompt: "a fox")
        _ = try await client.image(model: "flux", prompt: "a fox", sources: [bytes("jpeg")], size: "512x512")

        let exchanges = recorder.exchanges
        func count(_ purpose: Exchange.Purpose) -> Int { exchanges.filter { $0.purpose == purpose }.count }
        let counts: [Int] = [count(.models), count(.chat), count(.title), count(.probe), count(.image)]
        #expect(counts == [1, 1, 1, 8, 4], "the model list, a reply, a title, eight probes, and two pictures with a download each")
        #expect(exchanges.allSatisfy { $0.status == 200 })
        #expect(exchanges.compactMap(\.error).isEmpty)
        #expect(exchanges.compactMap(\.finishedAt).count == exchanges.count)
        #expect(exchanges.allSatisfy { $0.requestHeader("Authorization") == "Bearer $API_KEY" })
        #expect(exchanges.allSatisfy { !everything($0).contains(Self.key) }, "the key is in no field of any exchange")

        let chat = try #require(exchanges.first { $0.purpose == .chat })
        let sent = try #require(server.requests.first { $0.path.hasSuffix("/chat/completions") && $0.body == chat.requestBody })
        #expect(sent.contentType == "application/json")
        #expect(chat.method == "POST" && chat.url.path == "/v1/chat/completions")
        #expect(chat.requestHeader("Accept") == "text/event-stream")
        #expect(chat.responseHeaders.contains(.init(name: "Content-Type", value: "text/event-stream")))

        let edit = try #require(exchanges.first { $0.url.path == "/v1/images/edits" })
        #expect(edit.requestHeader("Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(edit.requestBody == server.requests.first { $0.path == "/v1/images/edits" }?.body)
    }

    @Test func aStreamKeepsItsRawTextAndWhenTheFirstTokenCame() async throws {
        let text = sse(["Hel", "lo"])
        let server = StubServer { _ in (200, text) }
        let recorder = Recorder()
        _ = try await consume(server.makeClient(apiKey: "", record: recorder.sink).stream(model: "m", messages: hello))

        let exchange = try #require(recorder.exchanges.first)
        #expect(exchange.responseBody.trimmingCharacters(in: .newlines) == text.trimmingCharacters(in: .newlines))
        let (start, byte, token, end) = (exchange.startedAt, try #require(exchange.firstByteAt),
                                         try #require(exchange.firstTokenAt), try #require(exchange.finishedAt))
        #expect(start <= byte && byte <= token && token <= end)
        #expect(exchange.requestHeader("Authorization") == nil, "a connection without a key sends no header")
    }

    @Test(arguments: [
        #"data: {"choices":[{"delta":{"reasoning_content":"hm"}}]}"#,
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"f","arguments":""}}]}}]}"#,
    ])
    func reasoningAndToolCallsCountAsTheFirstToken(line: String) async throws {
        let server = StubServer { _ in (200, line + "\n\ndata: [DONE]\n\n") }
        let recorder = Recorder()
        _ = try await consume(server.makeClient(apiKey: "", record: recorder.sink).stream(model: "m", messages: hello))
        #expect(recorder.exchanges.first?.firstTokenAt != nil)
    }

    @Test func aFailedRequestStillReportsWhatTheServerSaid() async throws {
        let server = StubServer { _ in (400, #"{"error":{"message":"bad model"}}"#) }
        let recorder = Recorder()
        await #expect(throws: ChatClientError.http(status: 400, message: "bad model")) {
            try await consume(server.makeClient(apiKey: "", record: recorder.sink).stream(model: "m", messages: hello))
        }
        let exchange = try #require(recorder.exchanges.first)
        #expect(exchange.status == 400)
        #expect(exchange.error == "HTTP 400: bad model")
        #expect(exchange.responseBody == #"{"error":{"message":"bad model"}}"#)
        #expect(exchange.finishedAt != nil && exchange.firstTokenAt == nil)
    }

    @Test func anHTTPFailureOfARequestAnsweredInOnePieceReadsAsAnError() async throws {
        let server = StubServer { _ in (401, #"{"error":{"message":"bad key"}}"#) }
        let recorder = Recorder()
        _ = try? await server.makeClient(apiKey: Self.key, record: recorder.sink).models()
        let exchange = try #require(recorder.exchanges.first)
        #expect(exchange.status == 401 && exchange.error == "HTTP 401: bad key")
    }

    @Test func aRequestThatNeverGotAnAnswerHasNoStatus() async throws {
        let server = StubServer { _ in (0, "") }
        let recorder = Recorder()
        await #expect(throws: (any Error).self) { try await server.makeClient(apiKey: "", record: recorder.sink).models() }
        let exchange = try #require(recorder.exchanges.first)
        #expect(exchange.status == nil && exchange.responseBody.isEmpty)
        #expect(exchange.error?.isEmpty == false && exchange.finishedAt != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStoppedReplyReportsWhatArrivedBeforeTheStop() async throws {
        let partial = #"data: {"choices":[{"delta":{"content":"Hel"}}]}"# + "\n\n"
        let server = StubServer(holdsOpen: true) { _ in (200, partial) }
        let recorder = Recorder()
        let client = server.makeClient(apiKey: Self.key, record: recorder.sink)
        let (arrived, signal) = AsyncStream.makeStream(of: Void.self)
        let reply = Task {
            do { for try await _ in client.stream(model: "m", messages: hello) { signal.yield() } } catch {}
        }
        for await _ in arrived { break }
        reply.cancel()

        let exchange = try #require(await recorder.wait(for: 1).first)
        #expect(exchange.error == Exchange.cancelledMessage)
        #expect(exchange.status == 200)
        #expect(exchange.responseBody == partial)
        #expect(exchange.firstTokenAt != nil && exchange.finishedAt != nil && exchange.usage == nil)
        #expect(!everything(exchange).contains(Self.key))
    }

    @Test func aLongResponseIsCutAndSaysSo() async throws {
        // 3 bytes each, so the limit falls inside a character.
        let server = StubServer { _ in (200, String(repeating: "€", count: 100_000)) }
        let recorder = Recorder()
        _ = try? await server.makeClient(apiKey: "", record: recorder.sink).models()
        let exchange = try #require(recorder.exchanges.first)
        #expect(exchange.responseTruncated)
        #expect(exchange.responseBody == String(repeating: "€", count: Exchange.bodyLimit / 3))
    }

    @Test func aResponseThatIsNotTextIsNamedNotShown() {
        let body = BodyCapture(whole: Data([0xFF, 0xFE, 0x00, 0x81]))
        var exchange = Exchange(purpose: .image, url: URL(string: "http://h/x")!)
        exchange.store(body)
        #expect(exchange.responseBody == "<binary data, 1 KB>")
        #expect(!exchange.responseTruncated)
    }
}
