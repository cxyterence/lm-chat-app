import ChatCore
import Testing
@testable import ChatUI

@MainActor
struct MCPClientTests {
    private func client(_ mcp: FakeMCP, token: String = "tok") -> MCPClient {
        let server = StubServer { _ in (404, "") }
        server.mcp = mcp
        return MCPClient(url: server.root.appendingPathComponent("mcp"), token: token, session: server.session)
    }

    private let three = [FakeMCP.Tool(name: "a", readOnly: true, result: "A"),
                         FakeMCP.Tool(name: "b", readOnly: false, result: "B"),
                         FakeMCP.Tool(name: "c", readOnly: true, result: "C")]

    @Test(arguments: [false, true])
    func listsEveryPageAndCalls(sse: Bool) async throws {
        let mcp = FakeMCP(tools: three)
        mcp.sse = sse
        let client = client(mcp)
        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["a", "b", "c"])
        #expect(tools.map(\.readOnly) == [true, false, true])
        #expect(mcp.seen.prefix(2) == ["initialize", "notifications/initialized"])

        let result = try await client.callTool("b", arguments: #"{"x":1}"#)
        #expect(result == ToolCall.Result(text: "B"))
        #expect(mcp.lastArguments?["x"] as? Int == 1)
    }

    @Test func aWrongTokenSaysSo() async {
        await #expect(throws: MCPError.unauthorized) { try await client(FakeMCP(tools: three), token: "nope").listTools() }
    }

    @Test func startsANewSessionWhenTheServerForgetsIt() async throws {
        let mcp = FakeMCP(tools: three)
        let client = client(mcp)
        _ = try await client.listTools()
        mcp.forgetSession()
        #expect(try await client.callTool("a", arguments: "{}").text == "A")
        #expect(mcp.seen.filter { $0 == "initialize" }.count == 2)
    }

    @Test func badArgumentsAndUnknownToolsComeBackAsErrors() async throws {
        let client = client(FakeMCP(tools: three))
        #expect(try await client.callTool("a", arguments: "not json").isError)
        await #expect(throws: MCPError.rpc("Unknown tool zzz")) { try await client.callTool("zzz", arguments: "{}") }
    }

    @Test func longResultsAreCut() async throws {
        let client = client(FakeMCP(tools: [.init(name: "big", readOnly: true, result: String(repeating: "x", count: 40_000))]))
        let text = try await client.callTool("big", arguments: "{}").text
        #expect(text.count < MCPClient.resultLimit + 100)
        #expect(text.hasSuffix("characters.]"))
    }
}

@MainActor
struct ToolLoopTests {
    /// Calls `tool` when offered it on a fresh question, then answers with whatever the tool returned.
    private func server(calling tool: String, mcp: FakeMCP) -> StubServer {
        let server = StubServer { body in
            if lastRole(body) == "tool" {
                return (200, sse(["done: ", transcript(body).last?.text ?? ""]))
            }
            return offeredTools(body).contains(tool) ? (200, toolCallReply(tool)) : (200, sse(["no tools"]))
        }
        server.mcp = mcp
        return server
    }

    private func roles(_ store: ChatStore) -> [Role] { store.selectedConversation?.messages.map(\.role) ?? [] }

    @Test func readOnlyToolsRunAndTheModelAnswersFromThem() async throws {
        let mcp = FakeMCP(tools: [.init(name: "get_me", readOnly: true, result: "octocat")])
        let stub = server(calling: "get_me", mcp: mcp)
        let (store, cleanup) = makeStore(server: stub)
        defer { cleanup() }
        addMCP(store, at: stub)

        store.send("who am I?")
        await untilIdle(store)

        #expect(roles(store) == [.user, .assistant, .assistant])
        let round = try #require(store.selectedConversation?.messages[1].toolCalls.first)
        #expect(round.name == "get_me" && round.server == "Fake")
        #expect(round.result == ToolCall.Result(text: "octocat"))
        #expect(store.selectedConversation?.messages.last?.content == "done: octocat")
        #expect(mcp.called == ["get_me"])
        #expect(offeredTools(try #require(stub.chats.first)) == ["get_me"])
        if case .ready(let tools) = store.mcpStatus[store.mcpServers[0].id] { #expect(tools.count == 1) } else { Issue.record("not ready") }
    }

    @Test(arguments: [false, true])
    func toolsThatChangeThingsAskFirst(allow: Bool) async throws {
        let mcp = FakeMCP(tools: [.init(name: "create_issue", readOnly: false, result: "#42")])
        let stub = server(calling: "create_issue", mcp: mcp)
        let (store, cleanup) = makeStore(server: stub)
        defer { cleanup() }
        addMCP(store, at: stub)

        store.send("file it")
        while store.awaitingApproval == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.awaitingApproval == "call_1")
        #expect(mcp.called.isEmpty, "nothing runs before the user answers")
        store.resolveApproval(allow)
        await untilIdle(store)

        #expect(mcp.called == (allow ? ["create_issue"] : []))
        let result = try #require(store.selectedConversation?.messages[1].toolCalls.first?.result)
        #expect(result.isError == !allow)
        #expect(store.selectedConversation?.messages.last?.content.hasPrefix(allow ? "done: #42" : "done: The user declined") == true)
    }

    @Test func stoppingWhileAskingDeclinesAndEnds() async throws {
        let mcp = FakeMCP(tools: [.init(name: "create_issue", readOnly: false, result: "#42")])
        let stub = server(calling: "create_issue", mcp: mcp)
        let (store, cleanup) = makeStore(server: stub)
        defer { cleanup() }
        addMCP(store, at: stub)

        store.send("file it")
        while store.awaitingApproval == nil { try await Task.sleep(for: .milliseconds(5)) }
        store.stop()
        await untilIdle(store)
        #expect(store.awaitingApproval == nil)
        #expect(mcp.called.isEmpty)
        #expect(roles(store) == [.user, .assistant], "the unanswered call stays, with no result")
        #expect(store.selectedConversation?.messages[1].toolCalls.first?.result == nil)
    }

    @Test func aModelWithoutToolSupportIsAskedWithoutTools() async throws {
        let mcp = FakeMCP(tools: [.init(name: "get_me", readOnly: true, result: "x")])
        let stub = StubServer { body in
            offeredTools(body).isEmpty ? (200, sse(["plain answer"]))
                : (400, #"{"error":{"message":"\"auto\" tool choice requires --enable-auto-tool-choice"}}"#)
        }
        stub.mcp = mcp
        let (store, cleanup) = makeStore(server: stub)
        defer { cleanup() }
        addMCP(store, at: stub)

        store.send("hi")
        await untilIdle(store)
        #expect(store.selectedConversation?.messages.last?.content == "plain answer")
        store.send("again")
        await untilIdle(store)
        #expect(stub.chats.map { offeredTools($0).isEmpty } == [false, true, true], "remembers not to send tools")
    }

    @Test func anUnreachableServerIsLeftOut() async throws {
        let mcp = FakeMCP(token: "right", tools: [.init(name: "get_me", readOnly: true, result: "x")])
        let stub = server(calling: "get_me", mcp: mcp)
        let (store, cleanup) = makeStore(server: stub)
        defer { cleanup() }
        addMCP(store, at: stub, token: "wrong")

        store.send("who am I?")
        await untilIdle(store)
        #expect(store.selectedConversation?.messages.last?.content == "no tools")
        #expect(store.mcpStatus[store.mcpServers[0].id] == .failed("The server rejected the token."))
    }

    @Test func disabledServersAreNotOffered() async throws {
        let mcp = FakeMCP(tools: [.init(name: "get_me", readOnly: true, result: "x")])
        let stub = server(calling: "get_me", mcp: mcp)
        let (store, cleanup) = makeStore(server: stub)
        defer { cleanup() }
        addMCP(store, at: stub)
        store.setMCPServer(store.mcpServers[0].id, enabled: false)

        store.send("who am I?")
        await untilIdle(store)
        #expect(store.selectedConversation?.messages.last?.content == "no tools")
    }

    @Test func editingAToolReplyEraseItsRounds() async throws {
        let mcp = FakeMCP(tools: [.init(name: "get_me", readOnly: true, result: "octocat")])
        let stub = server(calling: "get_me", mcp: mcp)
        let (store, cleanup) = makeStore(server: stub)
        defer { cleanup() }
        addMCP(store, at: stub)
        store.send("who am I?")
        await untilIdle(store)
        store.setMCPServer(store.mcpServers[0].id, enabled: false)

        store.edit(try #require(store.selectedConversation?.messages.first).id, to: "hello")
        await untilIdle(store)
        #expect(roles(store) == [.user, .assistant])
        #expect(store.selectedConversation?.messages.last?.toolCalls.isEmpty == true)
    }

    @Test func serversAndTokensPersist() throws {
        let stub = StubServer { _ in (404, "") }
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }
        let secrets = Secrets.memory()
        let first = ChatStore(defaults: defaults, fileURL: file, secrets: secrets, session: stub.session)
        first.saveMCPServer(.github(), token: " ghp_x ")
        let second = ChatStore(defaults: defaults, fileURL: file, secrets: secrets, session: stub.session)
        #expect(second.mcpServers.map(\.name) == ["GitHub"])
        #expect(second.mcpToken(for: second.mcpServers[0].id) == "ghp_x")
        second.deleteMCPServer(second.mcpServers[0].id)
        #expect(ChatStore(defaults: defaults, fileURL: file, secrets: secrets, session: stub.session).mcpServers.isEmpty)
        #expect(secrets.get(MCPServer.github().secretAccount) == nil)
    }
}
