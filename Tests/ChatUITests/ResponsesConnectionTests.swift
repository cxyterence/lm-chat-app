import ChatCore
import Foundation
import Testing
@testable import ChatUI

@MainActor
struct ResponsesConnectionTests {
    /// A store whose active connection, "stub" with model "m", speaks `api`.
    private func store(_ server: StubServer, api: WireAPI = .responses, key: String = "") -> (store: ChatStore, connection: Connection, cleanup: @Sendable () -> Void) {
        let (store, cleanup) = makeStore(server: server)
        let connection = Connection(name: "responses", baseURL: server.baseURL, model: "m", api: api)
        store.saveConnection(connection, apiKey: key)
        return (store, connection, cleanup)
    }

    private nonisolated static func inputTypes(_ body: [String: Any]) -> [String] {
        (body["input"] as? [[String: Any]] ?? []).map { $0["type"] as? String ?? $0["role"] as? String ?? "" }
    }

    @Test func connectionsSavedBeforeTheChoiceExistedLoadAsChatCompletions() throws {
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }
        let id = UUID()
        let old = #"[{"id":"\#(id.uuidString)","name":"Old","baseURL":"http://box.lan:8000/v1","model":"qwen","systemPrompt":""}]"#
        defaults.set(Data(old.utf8), forKey: "connections")
        defaults.set(id.uuidString, forKey: "activeConnection")

        let store = ChatStore(defaults: defaults, fileURL: file, secrets: .memory())
        #expect(store.activeConnection?.api == .chatCompletions)
        #expect(store.config?.api == .chatCompletions)
    }

    @Test func theChoiceIsSavedWithTheConnectionAndReachesEveryConfig() throws {
        let rig = Rig(server: echoServer())
        defer { rig.cleanup() }
        var connection = rig.connection
        connection.api = .responses
        rig.store.saveConnection(connection, apiKey: "")

        #expect(rig.store.config?.api == .responses)
        #expect(rig.reopened().activeConnection?.api == .responses)
        #expect(rig.reopened().config?.api == .responses)
    }

    @Test func aChatOnAResponsesConnectionRunsAToolRoundAndShowsWhatTheServerReported() async throws {
        let mcp = FakeMCP(tools: [.init(name: "get_me", readOnly: true, result: "octocat")])
        let server = StubServer { _ in (500, "chat completions was used") }
        server.mcp = mcp
        server.responses = { body in
            if Self.inputTypes(body).last == "function_call_output" {
                let output = (body["input"] as? [[String: Any]])?.last?["output"] as? String ?? ""
                return (200, responsesStream(["done: ", output], prompt: 21, completion: 5))
            }
            return (body["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == "get_me" } == true
                ? (200, responsesToolCall("get_me", arguments: "{}")) : (200, responsesStream(["no tools"]))
        }
        let (store, _, cleanup) = self.store(server)
        defer { cleanup() }
        addMCP(store, at: server)

        store.send("who am I?")
        await untilIdle(store)

        let messages = try #require(store.selectedConversation?.messages)
        #expect(messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(messages[1].toolCalls.first?.result == ToolCall.Result(text: "octocat"))
        #expect(messages[2].content == "done: octocat")
        #expect(server.chats.isEmpty, "nothing went to chat completions")

        let requests = server.responseRequests
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        #expect(first["stream_options"] == nil && first["store"] as? Bool == false && first["messages"] == nil)
        let tool = try #require((first["tools"] as? [[String: Any]])?.first)
        #expect(tool["type"] as? String == "function" && tool["name"] as? String == "get_me" && tool["function"] == nil)
        #expect(Self.inputTypes(try #require(requests.last)) == ["user", "function_call", "function_call_output"])
        let call = try #require((requests.last?["input"] as? [[String: Any]])?[1])
        #expect(call["call_id"] as? String == "call_1" && call["name"] as? String == "get_me")

        let answered = try #require(store.exchanges(for: messages[2].id).first)
        #expect(answered.url.path == "/v1/responses")
        #expect(answered.usage == Usage(promptTokens: 21, completionTokens: 5, reasoningTokens: 0))
        #expect(ExchangeText.statsLine(answered)?.hasSuffix("5 tokens") == true)
    }

    @Test func aPhotoRequestIsInspectedAndResentWithItsPhotoAndTheConnectionsKey() async throws {
        let server = StubServer { _ in (500, "") }
        server.responses = { _ in (200, responsesStream(["a grey square"])) }
        let (store, _, cleanup) = self.store(server, key: "resp-key")
        defer { cleanup() }
        let photo = try store.images.save(makePNG(width: 64, height: 48))

        store.send("what is this?", images: [photo])
        await untilIdle(store)
        let message = try #require(store.selectedConversation?.messages.last)
        let original = try #require(store.exchanges(for: message.id).first)

        #expect(original.displayBody.contains("<image 1:") && !original.displayBody.contains("base64"))
        #expect(original.curl.contains("/v1/responses") && !original.curl.contains("resp-key"))

        let edited = original.displayBody.replacingOccurrences(of: "what is this?", with: "describe it")
        let sent = await store.resend(original, editedText: edited, for: message.id)

        #expect(sent.status == 200 && sent.url.path == "/v1/responses" && sent.error == nil)
        #expect(server.authorizations.last?.authorization == "Bearer resp-key")
        let parts = try #require((server.responseRequests.last?["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["input_image", "input_text"])
        #expect((parts.first?["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(parts.last?["text"] as? String == "describe it")
    }

    @Test func changingTheAPIAppliesToTheNextMessageWithoutARestart() async throws {
        let server = StubServer { _ in (200, sse(["via chat"])) }
        server.responses = { _ in (200, responsesStream(["via responses"])) }
        let (store, connection, cleanup) = self.store(server, api: .chatCompletions)
        defer { cleanup() }

        store.send("one")
        await untilIdle(store)
        #expect(server.chats.count == 1 && server.responseRequests.isEmpty)

        var changed = connection
        changed.api = .responses
        store.saveConnection(changed, apiKey: "")
        store.send("two")
        await untilIdle(store)

        #expect(server.chats.count == 1 && server.responseRequests.count == 1)
        #expect(store.selectedConversation?.messages.last?.content == "via responses")
    }

    @Test func whatWasLearnedAboutAModelOnChatCompletionsIsForgottenOnResponses() async throws {
        let refusal = #"{"error":{"message":"Function tools with reasoning_effort are not supported for m in /v1/chat/completions. Use /v1/responses or set reasoning_effort to 'none'."}}"#
        let server = StubServer { body in
            offeredTools(body).isEmpty || body["reasoning_effort"] as? String == "none" ? (200, sse(["ok"])) : (400, refusal)
        }
        server.responses = { _ in (200, responsesStream(["ok"])) }
        server.mcp = FakeMCP(tools: [.init(name: "get_me", readOnly: true, result: "x")])
        let (store, connection, cleanup) = self.store(server, api: .chatCompletions)
        defer { cleanup() }
        addMCP(store, at: server)
        store.setReasoningEffort(.medium)

        store.send("one")
        await untilIdle(store)
        #expect(store.selectedConversation?.messages.last?.adaptations == [.reasoningOffForTools])

        var changed = connection
        changed.api = .responses
        store.saveConnection(changed, apiKey: "")
        store.send("two")
        await untilIdle(store)

        let body = try #require(server.responseRequests.last)
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "medium", "the chosen level is sent again")
        #expect((body["tools"] as? [[String: Any]])?.isEmpty == false, "and so are the tools")
        #expect(store.selectedConversation?.messages.last?.adaptations.isEmpty == true)
    }

    @Test func checkModelOnAResponsesConnectionReportsWhatAChatThereWouldGet() async throws {
        let server = StubServer { _ in (500, "") }
        server.probe = { body in
            let effort = (body["reasoning"] as? [String: Any])?["effort"] as? String
            guard effort == nil || ["none", "low"].contains(effort!) else {
                return (400, #"{"error":{"message":"1 validation error: body.reasoning.effort"}}"#)
            }
            return (200, #"{"output":[]}"#)
        }
        let (store, connection, cleanup) = self.store(server)
        defer { cleanup() }

        await store.checkCapabilities(of: connection.id)

        guard case .done(let report) = store.capabilityChecks[.init(connection: connection.id, model: "m")] else {
            Issue.record("no report")
            return
        }
        #expect(report.tools == .yes && report.vision == .yes && report.efforts == [.none, .low])
        let paths = server.authorizations.map(\.path).filter { $0.hasSuffix("/responses") || $0.hasSuffix("/chat/completions") }
        #expect(!paths.isEmpty && paths.allSatisfy { $0.hasSuffix("/responses") })
    }
}
