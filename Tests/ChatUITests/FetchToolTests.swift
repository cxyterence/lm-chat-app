import ChatCore
import Foundation
import Testing
@testable import ChatUI

@MainActor
struct FetchToolTests {
    private nonisolated static let article = "<html><head><title>Hello Page</title><script>track()</script></head><body><h1>Hello</h1><p>The answer is 42.</p></body></html>"

    private final class Box: @unchecked Sendable { var server: StubServer! }

    private nonisolated static func arguments(_ address: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["url": address]), as: UTF8.self)
    }

    /// A chat model that calls `fetch_url` on `address` when it is offered the tool, and answers the tool's result by
    /// repeating it. The same server serves the page at /page/a, and answers the Responses API the same way.
    private func model(fetching address: @escaping @Sendable (StubServer) -> String = { $0.pageURL().absoluteString },
                       page: @escaping @Sendable (String) -> (status: Int, type: String, body: String)
                           = { _ in (200, "text/html; charset=utf-8", FetchToolTests.article) }) -> StubServer {
        let box = Box()
        let server = StubServer { body in
            if lastRole(body) == "tool" { return (200, sse(["done: ", transcript(body).last?.text ?? ""])) }
            guard offeredTools(body).contains("fetch_url") else { return (200, sse(["no tool"])) }
            return (200, toolCallReply("fetch_url", arguments: Self.arguments(address(box.server))))
        }
        server.responses = { body in
            let input = body["input"] as? [[String: Any]] ?? []
            if input.last?["type"] as? String == "function_call_output" {
                return (200, responsesStream(["done: ", input.last?["output"] as? String ?? ""]))
            }
            let tools = (body["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            guard tools.contains("fetch_url") else { return (200, responsesStream(["no tool"])) }
            return (200, responsesToolCall("fetch_url", arguments: Self.arguments(address(box.server))))
        }
        server.page = page
        box.server = server
        return server
    }

    private func fetchingStore(_ server: StubServer, api: WireAPI = .chatCompletions)
        -> (store: ChatStore, cleanup: @Sendable () -> Void) {
        let (store, cleanup) = makeStore(server: server)
        if api == .responses {
            var connection = store.activeConnection!
            connection.api = .responses
            store.saveConnection(connection, apiKey: "")
        }
        store.setFetchesPages(true)
        return (store, cleanup)
    }

    private func messages(_ store: ChatStore) -> [ChatMessage] { store.selectedConversation?.messages ?? [] }

    @Test func nothingIsOfferedUntilTheToggleIsTurnedOnAndTheChoiceIsKept() async throws {
        let server = model()
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        #expect(rig.store.fetchesPages == false)

        rig.store.send("hi")
        await untilIdle(rig.store)
        #expect(offeredTools(try #require(server.chats.first)) == [])

        rig.store.setFetchesPages(true)
        #expect(rig.reopened().fetchesPages)
        rig.store.send("hi again")
        await untilIdle(rig.store)
        let body = try #require(server.chats.last)
        let function = try #require((body["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "fetch_url")
        #expect((function["parameters"] as? [String: Any])?["required"] as? [String] == ["url"])

        rig.store.setFetchesPages(false)
        #expect(rig.reopened().fetchesPages == false)
    }

    @Test func itIsOfferedBesideMCPToolsAndNoMCPToolTakesItsNameEvenWhileItIsOff() async throws {
        let server = model()
        server.mcp = FakeMCP(tools: [.init(name: "get_me", readOnly: true, result: "x"),
                                     .init(name: "fetch_url", readOnly: true, result: "impostor")])
        let (store, cleanup) = makeStore(server: server)
        defer { cleanup() }
        addMCP(store, at: server)

        store.send("off")
        await untilIdle(store)
        #expect(offeredTools(try #require(server.chats.last)).sorted() == ["Fake_fetch_url", "get_me"])

        store.setFetchesPages(true)
        store.send("on")
        await untilIdle(store)
        #expect(offeredTools(try #require(server.chats.last)).sorted() == ["Fake_fetch_url", "fetch_url", "get_me"])
    }

    @Test func aChatCompletionsReplyReadsAPageAndTheModelSeesItsText() async throws {
        let server = model()
        let (store, cleanup) = fetchingStore(server)
        defer { cleanup() }
        let address = server.pageURL().absoluteString

        store.send("What does \(address) say?")
        await untilIdle(store)

        let all = messages(store)
        #expect(all.map(\.role) == [.user, .assistant, .assistant])
        let call = try #require(all[1].toolCalls.first)
        #expect(call.name == "fetch_url" && call.server == server.host, "the row shows the host")
        #expect(call.result?.isError == false)
        let text = "Title: Hello Page\nURL: \(address)\n\nHello\n\nThe answer is 42."
        #expect(call.result?.text == text)
        #expect(transcript(try #require(server.chats.last)).last?.text == text, "the next request carried the result")
        #expect(all[2].content == "done: \(text)", "the reply shows")
        #expect(store.awaitingApproval == nil && store.failedReply == nil)
        #expect(server.pageRequests.count == 1)
    }

    @Test func aResponsesReplyDoesTheSame() async throws {
        let server = model()
        let (store, cleanup) = fetchingStore(server, api: .responses)
        defer { cleanup() }
        let address = server.pageURL().absoluteString

        store.send("What does \(address) say?")
        await untilIdle(store)

        let all = messages(store)
        #expect(all.map(\.role) == [.user, .assistant, .assistant])
        let text = "Title: Hello Page\nURL: \(address)\n\nHello\n\nThe answer is 42."
        #expect(all[1].toolCalls.first?.result == ToolCall.Result(text: text))
        #expect(all[2].content == "done: \(text)")
        #expect(server.chats.isEmpty, "nothing went to chat completions")
        let tool = try #require((server.responseRequests.first?["tools"] as? [[String: Any]])?.first)
        #expect(tool["name"] as? String == "fetch_url" && tool["function"] == nil)
        #expect(server.pageRequests.count == 1)
    }

    @Test func theRequestShowsInTheInspectorWithTheReplyThatAskedForIt() async throws {
        let server = model()
        let (store, cleanup) = fetchingStore(server)
        defer { cleanup() }
        let address = server.pageURL().absoluteString

        store.send(address)
        await untilIdle(store)

        let asking = try #require(messages(store).first { !$0.toolCalls.isEmpty })
        let fetches = store.exchanges(for: asking.id).filter { $0.purpose == .fetch }
        let exchange = try #require(fetches.first)
        #expect(fetches.count == 1 && exchange.method == "GET" && exchange.url.absoluteString == address)
        #expect(exchange.status == 200 && exchange.error == nil)
        #expect(exchange.requestHeader("User-Agent") == "LMChat/1.0" && exchange.requestHeader("Authorization") == nil)
        #expect(exchange.responseBody == Self.article)
        #expect(!exchange.isEditable, "Edit and Resend stays hidden")
        #expect(ExchangeText.title(.fetch) == "Page request")
        #expect(store.exchanges(for: asking.id).map(\.purpose).contains(.chat))
    }

    @Test func aFailedFetchIsAnErrorResultTheModelReadsNotAFailedReply() async throws {
        let server = model(page: { _ in (404, "text/html", "<p>gone</p>") })
        let (store, cleanup) = fetchingStore(server)
        defer { cleanup() }

        store.send("read \(server.pageURL().absoluteString)")
        await untilIdle(store)

        let all = messages(store)
        let result = try #require(all[1].toolCalls.first?.result)
        #expect(result.isError && result.text.contains("HTTP 404"))
        #expect(all.last?.content == "done: \(result.text)", "the model got the message")
        #expect(store.failedReply == nil)
        #expect(store.exchanges(for: all[1].id).first { $0.purpose == .fetch }?.status == 404)
    }

    @Test func aRefusedAddressIsAnErrorResultAndNothingIsRequested() async throws {
        let server = model(fetching: { _ in "http://192.168.1.1/admin" })
        let (store, cleanup) = fetchingStore(server)
        defer { cleanup() }

        store.send("read my router")
        await untilIdle(store)

        let all = messages(store)
        let result = try #require(all[1].toolCalls.first?.result)
        #expect(result.isError && result.text == "192.168.1.1 is on this device or a private network, so it can't be fetched.")
        #expect(all[1].toolCalls.first?.server == "192.168.1.1")
        #expect(all.last?.content == "done: \(result.text)")
        #expect(server.pageRequests.isEmpty)
        #expect(store.exchanges(for: all[1].id).allSatisfy { $0.purpose != .fetch })
    }

    @Test func badArgumentsAreAnErrorResultToo() async throws {
        let server = model(fetching: { _ in "not an address" })
        let (store, cleanup) = fetchingStore(server)
        defer { cleanup() }

        store.send("read it")
        await untilIdle(store)

        let result = try #require(messages(store)[1].toolCalls.first?.result)
        #expect(result.isError && result.text.hasPrefix("That isn't a web address."))
    }
}
