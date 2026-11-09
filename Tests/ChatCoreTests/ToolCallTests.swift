import Testing
@testable import ChatCore

struct ToolCallTests {
    @Test func reassemblesArgumentsSplitAcrossChunks() {
        var calls = ToolCallAccumulator()
        calls.add(ToolCallDelta(index: 0, id: "a", name: "get_me", arguments: ""))
        calls.add(ToolCallDelta(index: 1, id: "b", name: "search", arguments: "{\"q\":"))
        calls.add(ToolCallDelta(index: 0, id: nil, name: nil, arguments: "{}"))
        calls.add(ToolCallDelta(index: 1, id: nil, name: nil, arguments: "\"swift\"}"))
        #expect(calls.calls == [ToolCall(id: "a", name: "get_me", arguments: "{}"),
                                ToolCall(id: "b", name: "search", arguments: "{\"q\":\"swift\"}")])
    }

    @Test func copesWithServersThatOmitIndexOrID() {
        var calls = ToolCallAccumulator()
        calls.add(ToolCallDelta(index: nil, id: nil, name: "one", arguments: "{\"x\""))
        calls.add(ToolCallDelta(index: nil, id: nil, name: nil, arguments: ":1}"))
        calls.add(ToolCallDelta(index: nil, id: "z", name: "two", arguments: ""))
        #expect(calls.calls.map(\.id) == ["call_0", "z"])
        #expect(calls.calls.map(\.arguments) == ["{\"x\":1}", "{}"])
    }

    @Test func decodesToolCallDeltas() throws {
        let line = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"get_me","arguments":"{}"}}]}}]}"#
        #expect(try SSEDecoder().decode(line: line) == [.toolCall(ToolCallDelta(index: 0, id: "c1", name: "get_me", arguments: "{}"))])
    }

    @Test func sendsToolsAndExpandsToolRounds() throws {
        let client = ChatClient(config: try ServerConfig.parse(baseURL: "h:1", apiKey: ""))
        let schema = JSONValue.object(["type": .string("object"), "properties": .object(["q": .object(["type": .string("string")])])])
        let round = ChatMessage(role: .assistant, content: "", toolCalls: [
            ToolCall(id: "c1", name: "search", arguments: "{\"q\":\"x\"}", result: .init(text: "found")),
            ToolCall(id: "c2", name: "search", arguments: "{}"),
        ])
        let request = try client.chatRequest(model: "m", messages: [ChatMessage(role: .user, content: "hi"), round],
                                             tools: [ToolSpec(name: "search", description: "Find", parameters: schema)])
        let body = try #require(jsonObject(request.httpBody))
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "search")
        #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "tool", "tool"])
        #expect(isJSONNull(messages[1]["content"]), "a tools-only turn has null content")
        let calls = try #require(messages[1]["tool_calls"] as? [[String: Any]])
        #expect(calls.map { $0["id"] as? String } == ["c1", "c2"])
        #expect((calls[0]["function"] as? [String: Any])?["arguments"] as? String == "{\"q\":\"x\"}")
        #expect(messages[2]["tool_call_id"] as? String == "c1")
        #expect(messages[2]["content"] as? String == "found")
        #expect(messages[3]["content"] as? String == "The tool call was cancelled.")
    }

    @Test func leavesToolsOutWhenThereAreNone() throws {
        let client = ChatClient(config: try ServerConfig.parse(baseURL: "h:1", apiKey: ""))
        let body = try #require(jsonObject(client.chatRequest(model: "m", messages: []).httpBody))
        #expect(body["tools"] == nil)
    }

    @Test func storesToolCallsWithTheMessage() throws {
        let message = ChatMessage(role: .assistant, content: "", toolCalls: [
            ToolCall(id: "c", name: "n", arguments: "{}", server: "GitHub", result: .init(text: "r", isError: true)),
        ])
        let (url, cleanup) = makeTempFileURL("c.json")
        defer { cleanup() }
        try ConversationStore.save([Conversation(messages: [message])], to: url)
        #expect(try ConversationStore.load(from: url).first?.messages.first?.toolCalls == message.toolCalls)
    }
}
