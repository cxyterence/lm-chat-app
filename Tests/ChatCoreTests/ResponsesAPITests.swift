import Foundation
import Testing
@testable import ChatCore

struct ResponsesAPITests {
    private let hello = [ChatMessage(role: .user, content: "hi")]
    private let decoder = ResponsesDecoder()

    private func events(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func decode(_ capture: String) throws -> [StreamEvent] {
        try capture.split(separator: "\n", omittingEmptySubsequences: false).flatMap { try decoder.decode(line: String($0)) }
    }

    private func body(_ messages: [ChatMessage], effort: ReasoningEffort? = nil, tools: [ToolSpec] = [],
                      images: ImageStore? = nil) throws -> [String: Any] {
        let client = ChatClient(config: ServerConfig(baseURL: URL(string: "http://h:1/v1")!, api: .responses))
        let request = try client.responsesRequest(model: "m", messages: messages, reasoningEffort: effort, images: images, tools: tools)
        #expect(request.url?.path == "/v1/responses" && request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        return try #require(jsonObject(request.httpBody))
    }

    private func items(_ body: [String: Any]) throws -> [[String: Any]] { try #require(body["input"] as? [[String: Any]]) }

    // MARK: Request

    @Test func aTextChatIsSentAsInputWithoutChatCompletionsFields() throws {
        let sent = try body([ChatMessage(role: .system, content: "Be brief."), ChatMessage(role: .user, content: "hi"),
                             ChatMessage(role: .assistant, content: "Hello."), ChatMessage(role: .user, content: "again")])

        #expect(sent["model"] as? String == "m" && sent["stream"] as? Bool == true)
        #expect(sent["store"] as? Bool == false)
        #expect(try items(sent).map { [$0["role"] as? String, $0["content"] as? String] } == [
            ["system", "Be brief."], ["user", "hi"], ["assistant", "Hello."], ["user", "again"],
        ])
        for absent in ["messages", "stream_options", "reasoning", "reasoning_effort", "tools"] { #expect(sent[absent] == nil, "\(absent)") }
    }

    @Test func aReasoningLevelGoesInsideReasoning() throws {
        let sent = try body(hello, effort: .high)
        #expect((sent["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect(sent["reasoning_effort"] == nil)
    }

    @Test func toolsAreFlat() throws {
        let schema = JSONValue.object(["type": .string("object"), "properties": .object([:])])
        let sent = try body(hello, tools: [ToolSpec(name: "get_me", description: "Who am I", parameters: schema)])
        let tool = try #require((sent["tools"] as? [[String: Any]])?.first)

        #expect(tool["type"] as? String == "function" && tool["name"] as? String == "get_me" && tool["description"] as? String == "Who am I")
        #expect((tool["parameters"] as? [String: Any])?["type"] as? String == "object")
        #expect(tool["function"] == nil)
    }

    @Test func photosGoAsInputImagePartsWithDetailBeforeTheText() throws {
        let (store, cleanup) = makeImageStore()
        defer { cleanup() }
        let message = ChatMessage(role: .user, content: "what is this?", images: [try store.save(bytes("one")), try store.save(bytes("two"))])
        let parts = try #require(try items(body([message], images: store)).first?["content"] as? [[String: Any]])

        #expect(parts.map { $0["type"] as? String } == ["input_image", "input_image", "input_text"])
        #expect(parts.prefix(2).map { $0["detail"] as? String } == ["auto", "auto"])
        #expect(parts.prefix(2).map { $0["image_url"] as? String } == ["data:image/jpeg;base64,b25l", "data:image/jpeg;base64,dHdv"])
        #expect(parts.last?["text"] as? String == "what is this?")
    }

    @Test func aPhotoWithoutTextSendsOnlyTheImageAndAMissingPhotoIsLeftOut() throws {
        let (store, cleanup) = makeImageStore()
        defer { cleanup() }
        let only = ChatMessage(role: .user, content: "", images: [try store.save(bytes("x"))])
        #expect(try (items(body([only], images: store)).first?["content"] as? [[String: Any]])?.map { $0["type"] as? String } == ["input_image"])

        let gone = try store.save(bytes("gone"))
        store.remove([gone])
        #expect(try items(body([ChatMessage(role: .user, content: "hi", images: [gone])], images: store)).first?["content"] as? String == "hi")
    }

    @Test func aToolRoundIsItsTextThenEachCallThenEachResult() throws {
        let round = ChatMessage(role: .assistant, content: "Let me look.", toolCalls: [
            ToolCall(id: "c1", name: "search", arguments: #"{"q":"x"}"#, result: .init(text: "found")),
            ToolCall(id: "c2", name: "search", arguments: "{}"),
        ])
        let sent = try items(body([ChatMessage(role: .user, content: "hi"), round]))

        #expect(sent.map { $0["type"] as? String ?? $0["role"] as? String } == ["user", "assistant", "function_call", "function_call", "function_call_output", "function_call_output"])
        #expect(sent[1]["content"] as? String == "Let me look.")
        #expect(sent[2]["call_id"] as? String == "c1" && sent[2]["name"] as? String == "search" && sent[2]["arguments"] as? String == #"{"q":"x"}"#)
        #expect(sent[4]["call_id"] as? String == "c1" && sent[4]["output"] as? String == "found")
        #expect(sent[5]["call_id"] as? String == "c2" && sent[5]["output"] as? String == "The tool call was cancelled.")
    }

    @Test func aToolsOnlyTurnHasNoTextMessage() throws {
        let round = ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "t", arguments: "{}", result: .init(text: "ok"))])
        #expect(try items(body([round])).map { $0["type"] as? String } == ["function_call", "function_call_output"])
    }

    // MARK: Decoding what the server sent

    @Test func aCapturedTextStreamBecomesContentThenUsageThenDone() throws {
        let received = try decode(CapturedResponses.text)
        #expect(received == [.content("Hi"), .content(" there"), .content(","), .content(" friend"), .content("!"),
                             .usage(Usage(promptTokens: 39, completionTokens: 6, reasoningTokens: 0)), .done(finishReason: "stop")])
    }

    @Test func aCapturedToolCallStreamBecomesDeltasAndFinishesWithToolCalls() throws {
        let received = try decode(CapturedResponses.tool)
        #expect(received == [
            .toolCall(ToolCallDelta(index: 0, id: "call_86c03f762b3db7e5", name: "get_weather", arguments: "")),
            .toolCall(ToolCallDelta(index: 0, id: nil, name: nil, arguments: #"{"city": ""#)),
            .toolCall(ToolCallDelta(index: 0, id: nil, name: nil, arguments: "Paris")),
            .toolCall(ToolCallDelta(index: 0, id: nil, name: nil, arguments: #""}"#)),
            .usage(Usage(promptTokens: 70, completionTokens: 15, reasoningTokens: 0)),
            .done(finishReason: "tool_calls"),
        ])
        var calls = ToolCallAccumulator()
        for case .toolCall(let delta) in received { calls.add(delta) }
        #expect(calls.calls == [ToolCall(id: "call_86c03f762b3db7e5", name: "get_weather", arguments: #"{"city": "Paris"}"#)])
    }

    /// The calls a stream of `lines` adds up to, read with a fresh decoder the way the client reads a reply.
    private func calls(_ lines: [String]) throws -> [ToolCall] {
        let fresh = ResponsesDecoder()
        var calls = ToolCallAccumulator()
        for line in lines { for case .toolCall(let delta) in try fresh.decode(line: "data: " + line) { calls.add(delta) } }
        return calls.calls
    }

    private func expect(_ lines: [String], give expected: [ToolCall], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let got = try calls(lines)
        #expect(got == expected, sourceLocation: sourceLocation)
    }

    private func added(_ index: Int, arguments: String? = nil) -> String {
        item("added", index, arguments: arguments ?? "")
    }

    private func item(_ kind: String, _ index: Int, arguments: String) -> String {
        let escaped = String(decoding: try! JSONEncoder().encode(arguments), as: UTF8.self)
        return #"{"type":"response.output_item.\#(kind)","output_index":\#(index),"item":{"type":"function_call","call_id":"call_\#(index)","name":"get_weather","arguments":\#(escaped)}}"#
    }

    private func argumentsDone(_ index: Int, arguments: String) -> String {
        let escaped = String(decoding: try! JSONEncoder().encode(arguments), as: UTF8.self)
        return #"{"type":"response.function_call_arguments.done","output_index":\#(index),"arguments":\#(escaped),"name":"get_weather"}"#
    }

    private func delta(_ index: Int, _ text: String) -> String {
        let escaped = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return #"{"type":"response.function_call_arguments.delta","output_index":\#(index),"delta":\#(escaped)}"#
    }

    @Test func argumentsThatCameWithTheCallAreNotLost() throws {
        let whole = #"{"city":"Paris"}"#
        try expect([added(0, arguments: whole), item("done", 0, arguments: whole)], give: [ToolCall(id: "call_0", name: "get_weather", arguments: whole)])
    }

    @Test func argumentsOnlyInTheArgumentsDoneEventAreUsed() throws {
        let whole = #"{"city":"Paris"}"#
        try expect([added(0), argumentsDone(0, arguments: whole), item("done", 0, arguments: whole)], give: [ToolCall(id: "call_0", name: "get_weather", arguments: whole)])
    }

    @Test func argumentsOnlyInTheItemDoneEventAreUsed() throws {
        let whole = #"{"city":"Paris"}"#
        try expect([added(0), item("done", 0, arguments: whole)], give: [ToolCall(id: "call_0", name: "get_weather", arguments: whole)])
    }

    @Test func aCallThatOnlyArrivesInItsDoneEventIsStillACall() throws {
        let whole = #"{"city":"Paris"}"#
        try expect([item("done", 0, arguments: whole)], give: [ToolCall(id: "call_0", name: "get_weather", arguments: whole)])
    }

    @Test func deltasFollowedByTheWholeArgumentsAreNotCountedTwice() throws {
        let whole = #"{"city":"Paris"}"#
        try expect([added(0), delta(0, #"{"city":"#), delta(0, #""Paris"}"#), argumentsDone(0, arguments: whole), item("done", 0, arguments: whole)], give: [ToolCall(id: "call_0", name: "get_weather", arguments: whole)])
    }

    @Test func eachCallIsJudgedOnItsOwnWhenOneStreamsAndTheOtherDoesNot() throws {
        let one = #"{"city":"Paris"}"#, two = #"{"city":"Rome"}"#
        try expect([added(0), added(1), delta(0, one), item("done", 0, arguments: one), item("done", 1, arguments: two)], give: [ToolCall(id: "call_0", name: "get_weather", arguments: one), ToolCall(id: "call_1", name: "get_weather", arguments: two)])
    }

    @Test func aCapturedReasoningStreamBecomesReasoning() throws {
        #expect(try decode(CapturedResponses.reasoning) == [
            .reasoning("*"), .reasoning("   Instruction"), .reasoning(":"), .reasoning(" \""), .reasoning("Say"),
        ])
    }

    @Test func openAIsReasoningSummaryDeltasAreReasoningToo() throws {
        let line = #"data: {"type":"response.reasoning_summary_text.delta","delta":"Thinking","item_id":"rs_1","output_index":0,"summary_index":0,"sequence_number":3}"#
        #expect(try decoder.decode(line: line) == [.reasoning("Thinking")])
    }

    @Test func reasoningTokensComeFromTheOutputTokenDetails() throws {
        let line = #"data: {"type":"response.completed","response":{"output":[],"usage":{"input_tokens":5,"output_tokens":40,"output_tokens_details":{"reasoning_tokens":31}}}}"#
        #expect(try decoder.decode(line: line) == [.usage(Usage(promptTokens: 5, completionTokens: 40, reasoningTokens: 31)), .done(finishReason: "stop")])
    }

    @Test func aCompletedResponseWithoutCountsStillFinishes() throws {
        let line = #"data: {"type":"response.completed","response":{"output":[{"type":"message"}],"usage":null}}"#
        #expect(try decoder.decode(line: line) == [.done(finishReason: "stop")])
    }

    @Test func anIncompleteResponseFinishesAsCutOff() throws {
        let line = #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"},"output":[]}}"#
        #expect(try decoder.decode(line: line) == [.done(finishReason: "length")])
    }

    @Test func anIncompleteResponseKeepsItsTokenCounts() throws {
        let line = #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"},"output":[],"usage":{"input_tokens":5,"output_tokens":40,"output_tokens_details":{"reasoning_tokens":31}}}}"#
        #expect(try decoder.decode(line: line) == [.usage(Usage(promptTokens: 5, completionTokens: 40, reasoningTokens: 31)), .done(finishReason: "length")])
    }

    @Test func aFailedResponseThrowsTheServersMessage() {
        let line = #"data: {"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"The model ran out of memory."}}}"#
        #expect(throws: ChatClientError.server("The model ran out of memory.")) { try decoder.decode(line: line) }
    }

    @Test(arguments: [
        #"data: {"type":"error","code":"rate_limit_exceeded","message":"Slow down.","param":null,"sequence_number":2}"#,
        #"data: {"type":"error","error":{"message":"Slow down."}}"#,
    ])
    func anErrorEventThrowsTheServersMessage(line: String) {
        #expect(throws: ChatClientError.server("Slow down.")) { try decoder.decode(line: line) }
    }

    @Test(arguments: [
        "", "event: response.created", ": keep-alive", "data: [DONE]",
        #"data: {"type":"response.something_new","delta":"x"}"#,
        #"data: {"type":"response.output_item.added","item":{"type":"message"},"output_index":0}"#,
        #"data: {"type":"response.output_text.done","text":"Hi"}"#,
    ])
    func whatItHasNoUseForIsIgnored(line: String) throws {
        #expect(try decoder.decode(line: line).isEmpty)
    }

    @Test func aLineThatIsNotJSONFails() {
        #expect(throws: ChatClientError.invalidResponse) { try decoder.decode(line: "data: not json") }
    }

    // MARK: Through the client

    @Test func aReplyEndsAtResponseCompletedEvenWhenTheServerHoldsTheConnectionOpen() async throws {
        let server = StubServer(holdsOpen: true) { _ in (200, CapturedResponses.text) }
        let started = ContinuousClock.now
        let received = try await events(server.makeClient(apiKey: "", api: .responses).stream(model: "m", messages: hello))

        #expect(received.last == .done(finishReason: "stop"))
        #expect(received.contains(.usage(Usage(promptTokens: 39, completionTokens: 6, reasoningTokens: 0))))
        #expect(ContinuousClock.now - started < ChatClient.finishGrace, "it did not wait out the grace period")
        let sent = try #require(server.requests.first)
        #expect(sent.path == "/v1/responses")
    }

    @Test func usageIsReportedToTheInspectorAndNoRetryWithoutStreamOptionsEverRuns() async throws {
        let server = StubServer { _ in (400, #"{"error":{"message":"1 validation error: body.stream_options"}}"#) }
        let recorder = Recorder()
        await #expect(throws: ChatClientError.http(status: 400, message: "1 validation error: body.stream_options")) {
            _ = try await events(server.makeClient(apiKey: "", api: .responses, record: recorder.sink).stream(model: "m", messages: hello))
        }
        #expect(server.requests.count == 1, "a refused Responses request is not asked again")

        let working = StubServer { _ in (200, CapturedResponses.text) }
        let reported = Recorder()
        _ = try await events(working.makeClient(apiKey: "", api: .responses, record: reported.sink).stream(model: "m", messages: hello))
        #expect(reported.exchanges.first?.usage == Usage(promptTokens: 39, completionTokens: 6, reasoningTokens: 0))
    }

    @Test func aFailureEventMidStreamEndsTheReplyWithTheMessage() async throws {
        let text = """
            data: {"type":"response.output_text.delta","delta":"Hel","output_index":0}

            data: {"type":"response.failed","response":{"error":{"message":"Out of memory."}}}

            """
        let server = StubServer { _ in (200, text) }
        var received: [StreamEvent] = []
        await #expect(throws: ChatClientError.server("Out of memory.")) {
            for try await event in server.makeClient(apiKey: "", api: .responses).stream(model: "m", messages: hello) { received.append(event) }
        }
        #expect(received == [.content("Hel")])
    }

    @Test func aTitleIsAskedForOnTheConnectionsAPI() async throws {
        let server = StubServer { body in
            #expect(body["input"] != nil && body["messages"] == nil)
            return (200, #"data: {"type":"response.output_text.delta","delta":"Weather in Paris"}"# + "\n\n"
                    + #"data: {"type":"response.completed","response":{"output":[]}}"# + "\n\n")
        }
        let title = try await server.makeClient(apiKey: "", api: .responses).title(model: "m", for: "What is the weather in Paris?")
        #expect(title == "Weather in Paris")
        #expect(server.requests.allSatisfy { $0.path == "/v1/responses" })
    }

    // MARK: Inspecting a request

    @Test func aRequestWithAPhotoReadsAndResendsLikeAChatCompletionsOne() async throws {
        let (images, cleanup) = makeImageStore()
        defer { cleanup() }
        let photo = Data(count: 3000)
        let message = ChatMessage(role: .user, content: "what is this?", images: [try images.save(photo)])
        let server = StubServer { _ in (200, CapturedResponses.text) }
        let recorder = Recorder()
        _ = try await events(server.makeClient(apiKey: "secret-key", api: .responses, record: recorder.sink)
            .stream(model: "m", messages: [message], images: images))
        let exchange = try #require(await recorder.wait(for: 1).first)

        #expect(exchange.url.path == "/v1/responses")
        #expect(exchange.displayBody.contains("<image 1: 3 KB>") && !exchange.displayBody.contains("base64"))
        #expect(try sameJSON(exchange.placeholders.restore(exchange.displayBody), exchange.requestBody))

        let curl = exchange.curl
        #expect(curl.hasPrefix("# Photos were left out."))
        #expect(curl.contains("curl -N -X POST 'http://\(server.host)/v1/responses'"))
        #expect(curl.contains(#""type": "input_image""#) && curl.contains(#""detail": "auto""#) && curl.contains("<image 1: 3 KB>"))
        #expect(!(curl + exchange.displayBody).contains("secret-key") && curl.contains("Bearer $API_KEY"))

        let edited = exchange.displayBody.replacingOccurrences(of: "what is this?", with: "describe it")
        let resent = await server.makeClient(apiKey: "secret-key", api: .responses).send(
            rawBody: exchange.placeholders.restore(edited), to: exchange.url, contentType: "application/json")
        #expect(resent.status == 200 && resent.error == nil)
        let sent = try #require(jsonObject(server.requests.last?.body))
        let parts = try #require((sent["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        #expect(parts.first?["image_url"] as? String == "data:image/jpeg;base64," + photo.base64EncodedString())
        #expect(parts.last?["text"] as? String == "describe it")
    }

    private func sameJSON(_ a: Data, _ b: Data) throws -> Bool {
        NSDictionary(dictionary: try #require(jsonObject(a))).isEqual(to: try #require(jsonObject(b)))
    }

    // MARK: Checking a model

    private static let efforts = ["none", "minimal", "low", "medium"]

    /// Takes tools, pictures and the levels above, and words a refused level the way vLLM does.
    private func responsesServer() -> StubServer {
        StubServer(route: { path, body in
            guard path.hasSuffix("/responses") else { return (404, "") }
            if let effort = (body["reasoning"] as? [String: Any])?["effort"] as? String, !Self.efforts.contains(effort) {
                return (400, #"{"error":{"message":"1 validation error:\n  {'loc': 'body.reasoning.effort', 'msg': \"Input should be 'none', 'low'\"}","code":400}}"#)
            }
            return (200, #"{"output":[],"status":"incomplete"}"#)
        })
    }

    @Test func aModelOnResponsesIsCheckedThroughResponses() async throws {
        let server = responsesServer()
        let report = try await server.makeClient(apiKey: "", api: .responses).capabilities(model: "m")

        #expect(report.tools == .yes && report.vision == .yes)
        #expect(report.efforts == [.none, .minimal, .low, .medium])
        let paths = Set(server.requests.map(\.path).filter { !$0.hasSuffix("/models") && !$0.hasSuffix("/server_info") })
        #expect(paths == ["/v1/responses"])

        let tools = try #require(server.bodies.first { $0["tools"] != nil })
        #expect(tools["max_output_tokens"] as? Int == 16 && tools["stream"] as? Bool == false && tools["store"] as? Bool == false)
        #expect((tools["tools"] as? [[String: Any]])?.first?["name"] as? String == "get_time")
        let picture = try #require(server.bodies.first { body in
            ((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first?["type"] as? String == "input_image"
        })
        let image = try #require(((picture["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first)
        #expect(image["detail"] as? String == "auto" && (image["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    @Test func aResponsesServerThatTakesToolsWithAReasoningLevelIsNotToldToTurnReasoningOff() async throws {
        let server = responsesServer()
        let report = try await server.makeClient(apiKey: "", api: .responses).capabilities(model: "m")
        #expect(report.tools == .yes)
        #expect(server.bodies.contains { $0["tools"] != nil && ($0["reasoning"] as? [String: Any])?["effort"] as? String == "minimal" },
                "a level is tried with tools, and it works")
    }

    @Test func aResponsesServerThatNamesAFeatureInARefusalHasNoSupportForIt() async throws {
        let server = StubServer(route: { path, body in
            if body["tools"] != nil { return (400, #"{"error":{"message":"this model does not support tools"}}"#) }
            return (200, "{}")
        })
        let report = try await server.makeClient(apiKey: "", api: .responses).capabilities(model: "m")
        #expect(report.tools == .no(reason: "this model does not support tools"))
    }

    // MARK: Saved settings

    @Test func aServerConfigSavedBeforeTheChoiceExistedUsesChatCompletions() throws {
        let old = Data(#"{"baseURL":"http://h:1/v1","apiKey":"k"}"#.utf8)
        let config = try JSONDecoder().decode(ServerConfig.self, from: old)
        #expect(config.api == .chatCompletions && config.apiKey == "k")

        let saved = ServerConfig(baseURL: URL(string: "http://h:1/v1")!, api: .responses)
        #expect(try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(saved)) == saved)
    }
}
