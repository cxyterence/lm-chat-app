import ChatCore
import Foundation
import Testing
@testable import ChatUI

@MainActor
struct ExchangeRecordingTests {
    private static let key = "sk-secret-key-123"

    private func replies(_ store: ChatStore) -> [ChatMessage] {
        store.selectedConversation?.messages.filter { $0.role == .assistant } ?? []
    }

    private func untilTitled(_ store: ChatStore) async {
        for _ in 0..<400 where store.selectedConversation?.title != "Stub Title" { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func picture() -> String {
        #"{"data":[{"b64_json":"\#(makePNG(width: 64, height: 48).base64EncodedString())"}]}"#
    }

    /// A chat model that calls `generate_image` on a question containing "draw", and answers a tool result.
    private func drawingServer() -> StubServer {
        let server = StubServer { body in
            if lastRole(body) == "tool" { return (200, sse(["done"])) }
            guard offeredTools(body).contains("generate_image"), transcript(body).last?.text.contains("draw") == true
            else { return (200, sse(["no picture"])) }
            return (200, toolCallReply("generate_image", arguments: #"{"prompt":"A red fox."}"#))
        }
        server.models = #"{"data":[{"id":"img","task_type":"t2i"}]}"#
        let reply = picture()
        server.image = { _ in (200, reply) }
        return server
    }

    @Test func aReplyKeepsItsRequestUnderItsOwnMessage() async throws {
        let server = StubServer { _ in (200, sseWithUsage(["Hi"], prompt: 5, completion: 2)) }
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }

        store.send("hello")
        await untilIdle(store)
        await untilTitled(store)

        let reply = try #require(replies(store).first)
        let chat = try #require(store.exchanges(for: reply.id).first)
        #expect(store.exchanges(for: reply.id).count == 1)
        #expect(chat.purpose == .chat && chat.method == "POST" && chat.status == 200 && chat.error == nil)
        #expect(chat.url.path.hasSuffix("/chat/completions"))
        #expect(jsonObject(chat.requestBody)?["model"] as? String == "m")
        #expect(chat.responseBody.contains(#""content":"Hi""#))
        #expect(chat.usage == Usage(promptTokens: 5, completionTokens: 2))
        #expect(chat.stats.timeToFirstToken != nil && chat.stats.totalTime != nil)
        #expect(store.exchangeLog.count == 1, "the title request is not attached to the reply")
    }

    @Test func theKeyReachesTheServerAndIsNeverKept() async throws {
        let server = StubServer { _ in (200, sse(["Hi"])) }
        let rig = Rig(server: server, key: Self.key)
        defer { rig.cleanup() }

        rig.store.send("hello")
        await untilIdle(rig.store)

        #expect(server.authorizations.contains { $0.path.hasSuffix("chat/completions") && $0.authorization == "Bearer \(Self.key)" })
        let kept = try #require(replies(rig.store).first).id
        let exchange = try #require(rig.store.exchanges(for: kept).first)
        let everything = [exchange.url.absoluteString, exchange.requestHeaders.map { $0.name + $0.value }.joined(),
                          String(decoding: exchange.requestBody, as: UTF8.self), exchange.responseHeaders.map { $0.name + $0.value }.joined(),
                          exchange.responseBody, exchange.error ?? "", exchange.curl, exchange.displayBody].joined()
        #expect(!everything.contains(Self.key))
        #expect(exchange.requestHeader("Authorization") == "Bearer $API_KEY")
    }

    @Test func eachToolRoundKeepsTheRequestItMade() async throws {
        let mcp = FakeMCP(tools: [.init(name: "get_me", readOnly: true, result: "octocat")])
        let server = StubServer { body in
            lastRole(body) == "tool" ? (200, sse(["done"])) : (200, toolCallReply("get_me"))
        }
        server.mcp = mcp
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }
        addMCP(store, at: server)

        store.send("who am I?")
        await untilIdle(store)

        let rounds = replies(store)
        #expect(rounds.count == 2)
        let first = store.exchanges(for: rounds[0].id), second = store.exchanges(for: rounds[1].id)
        #expect(first.count == 1 && second.count == 1)
        #expect(jsonObject(first[0].requestBody)?["tools"] != nil)
        #expect((jsonObject(second[0].requestBody)?["messages"] as? [[String: Any]])?.last?["role"] as? String == "tool")
        #expect(first[0].id != second[0].id)
    }

    @Test func aPictureRequestAttachesToTheMessageThatCalledTheTool() async throws {
        let server = drawingServer()
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }
        useImageTool(store, at: server)

        store.send("draw a fox")
        await untilIdle(store)

        let rounds = replies(store)
        #expect(rounds.count == 2)
        let asking = store.exchanges(for: rounds[0].id)
        #expect(asking.map(\.purpose) == [.chat, .image])
        #expect(asking[1].url.path.hasSuffix("images/generations") && asking[1].status == 200)
        #expect(asking[1].requestHeader("Authorization") == "Bearer $API_KEY")
        #expect(store.exchanges(for: rounds[1].id).map(\.purpose) == [.chat], "the answer's own request")
    }

    @Test func onlyTheNewest40RequestsAreKept() async throws {
        let (store, cleanup) = makeStore(server: echoServer())
        defer { cleanup() }

        for number in 1...42 {
            store.send("n\(number)")
            await untilIdle(store)
        }

        let all = replies(store)
        #expect(store.exchangeLog.count == 40)
        #expect(store.exchanges(for: all[1].id).isEmpty && store.exchanges(for: all[2].id).count == 1)
        #expect(store.exchanges(for: try #require(all.last).id).count == 1)
    }

    @Test func deletingAChatDropsItsRequests() async throws {
        let (store, cleanup) = makeStore(server: echoServer())
        defer { cleanup() }
        store.send("hello")
        await untilIdle(store)
        #expect(store.exchangeLog.count == 1)

        store.delete(ids: [try #require(store.selection)])
        #expect(store.exchangeLog.count == 0)
    }

    @Test func editingAMessageDropsTheRequestsOfEverythingAfterIt() async throws {
        let (store, cleanup) = makeStore(server: echoServer())
        defer { cleanup() }
        store.send("one")
        await untilIdle(store)
        store.send("two")
        await untilIdle(store)
        let old = replies(store).map(\.id)
        #expect(store.exchangeLog.count == 2)

        store.edit(try #require(store.selectedConversation?.messages.first).id, to: "uno")
        await untilIdle(store)

        #expect(old.allSatisfy { store.exchanges(for: $0).isEmpty })
        #expect(store.exchangeLog.count == 1)
        #expect(store.exchanges(for: try #require(replies(store).first).id).count == 1)
    }

    @Test func retryingDropsTheRequestsOfTheReplyItRepeats() async throws {
        final class Mode: @unchecked Sendable { nonisolated(unsafe) var broken = true }
        let mode = Mode()
        let cutOff = "data: {\"choices\":[{\"delta\":{\"content\":\"part\"}}]}\n\ndata: {\"error\":{\"message\":\"cut off\"}}\n\n"
        let server = StubServer { _ in mode.broken ? (200, cutOff) : (200, sse(["whole"])) }
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }
        store.send("hello")
        await untilIdle(store)
        let partial = try #require(replies(store).first)
        #expect(partial.content == "part" && store.exchanges(for: partial.id).count == 1)

        mode.broken = false
        store.retry()
        await untilIdle(store)

        #expect(store.exchanges(for: partial.id).isEmpty)
        #expect(store.exchangeLog.count == 1)
        #expect(store.exchanges(for: try #require(replies(store).first).id).first?.responseBody.contains("whole") == true)
    }

    @Test func aReplyThatFailedWithNothingToShowKeepsItsRequestUntilDismissedOrRetried() async throws {
        final class Mode: @unchecked Sendable { nonisolated(unsafe) var broken = true }
        let mode = Mode()
        let server = StubServer { _ in
            mode.broken ? (401, #"{"error":{"message":"Incorrect API key provided"}}"#) : (200, sse(["ok"]))
        }
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }

        store.send("hello")
        await untilIdle(store)
        let conversation = try #require(store.selection)
        #expect(replies(store).isEmpty && store.failureMessage(for: conversation) != nil)
        let failed = try #require(store.failedReply)
        let exchange = try #require(store.exchanges(for: failed).first)
        #expect(exchange.status == 401 && exchange.error == "HTTP 401: Incorrect API key provided")

        store.dismissFailure()
        #expect(store.failedReply == nil && store.exchangeLog.count == 0)

        store.send("once more")
        await untilIdle(store)
        #expect(store.failedReply != nil)
        store.delete(ids: [conversation])
        #expect(store.failedReply == nil && store.exchangeLog.count == 0, "deleting the chat lets go of its failed request")

        store.send("again")
        await untilIdle(store)
        #expect(store.failedReply != nil)
        mode.broken = false
        store.retry()
        await untilIdle(store)
        #expect(store.failedReply == nil && store.exchangeLog.count == 1, "only the reply that worked is kept")
    }
}
