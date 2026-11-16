import Foundation
import Testing
@testable import ChatCore

struct RawSendTests {
    private static let key = "sk-stub-secret-123"
    private let edited = bytes(#"{"model":"edited","messages":[{"role":"user","content":"hi"}],"stream":false}"#)

    private func chatURL(_ server: StubServer) -> URL { URL(string: "http://\(server.host)/v1/chat/completions")! }

    @Test func postsTheBodyAsIsWithTheKeyAndReturnsAResendExchange() async throws {
        let server = StubServer { _ in (200, #"{"choices":[{"message":{"content":"Hello"}}]}"#) }
        let recorder = Recorder()
        let client = server.makeClient(apiKey: Self.key, record: recorder.sink)

        let exchange = await client.send(rawBody: edited, to: chatURL(server), contentType: "application/json")

        #expect(server.requests.map(\.body) == [edited])
        #expect(server.requests.first?.contentType == "application/json")
        #expect(exchange.purpose == .resend && exchange.method == "POST")
        #expect(exchange.requestBody == edited)
        #expect(exchange.requestHeader("Authorization") == "Bearer $API_KEY")
        #expect(exchange.status == 200)
        #expect(exchange.responseBody == #"{"choices":[{"message":{"content":"Hello"}}]}"#)
        #expect(exchange.error == nil && exchange.finishedAt != nil)
        #expect(!"\(exchange)".contains(Self.key))
        #expect(recorder.exchanges == [exchange], "reported to the sink as well as returned")
    }

    @Test func aStreamedAnswerIsReadToTheEndAsText() async throws {
        let text = sse(["Hel", "lo"])
        let server = StubServer { _ in (200, text) }
        let exchange = await server.client.send(rawBody: edited, to: chatURL(server), contentType: "application/json")
        #expect(exchange.responseBody == text)
        #expect(exchange.firstByteAt != nil)
    }

    @Test func aRefusalIsInTheExchangeNotThrown() async throws {
        let server = StubServer { _ in (400, #"{"error":{"message":"bad field"}}"#) }
        let exchange = await server.client.send(rawBody: edited, to: chatURL(server), contentType: "application/json")
        #expect(exchange.status == 400)
        #expect(exchange.error == "HTTP 400: bad field")
        #expect(exchange.responseBody == #"{"error":{"message":"bad field"}}"#)
    }

    @Test func aConnectionThatFailsIsInTheExchangeToo() async throws {
        let server = StubServer { _ in (0, "") }
        let exchange = await server.client.send(rawBody: edited, to: chatURL(server), contentType: "application/json")
        #expect(exchange.status == nil)
        #expect(exchange.error?.isEmpty == false)
    }

    @Test func aFormKeepsItsOwnContentType() async throws {
        let server = StubServer { _ in (200, "{}") }
        let type = "multipart/form-data; boundary=abc"
        let exchange = await server.client.send(rawBody: bytes("--abc--\r\n"), to: URL(string: "http://\(server.host)/v1/images/edits")!, contentType: type)
        #expect(server.requests.first?.contentType == type)
        #expect(exchange.requestHeader("Content-Type") == type)
    }

    @Test func theKeyGoesOnlyToTheConnectionsOwnHost() async throws {
        let mine = StubServer { _ in (200, "{}") }, other = StubServer { _ in (200, "{}") }
        let exchange = await mine.makeClient(apiKey: Self.key).send(rawBody: edited, to: chatURL(other), contentType: "application/json")
        #expect(exchange.status == 200)
        #expect(exchange.requestHeader("Authorization") == nil)
    }
}
