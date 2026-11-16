import ChatCore
import Foundation
import Testing
@testable import ChatUI

@MainActor
struct CapabilityCheckTests {
    private nonisolated static let lunaRefusal = """
        {"error":{"message":"Function tools with reasoning_effort are not supported for gpt-6-luna in /v1/chat/completions. To use function tools, use /v1/responses or set reasoning_effort to 'none'."}}
        """
    private nonisolated static let noTools = #"{"error":{"message":"this model does not support tools"}}"#

    /// Takes pictures and the levels none, low and medium. `tools` answers a request that carries tools.
    private func server(tools: @escaping @Sendable ([String: Any]) -> StubServer.Reply) -> StubServer {
        let stub = StubServer { body in
            let reply = body["tools"] != nil ? tools(body) : (status: 200, body: "")
            return reply.status == 200 ? (200, sse(["ok"])) : reply
        }
        stub.probe = { body in
            if body["tools"] != nil { return tools(body) }
            let effort = body["reasoning_effort"] as? String
            return effort == nil || ["none", "low", "medium"].contains(effort!)
                ? (200, "{}") : (400, #"{"error":{"message":"Unexpected reasoning effort"}}"#)
        }
        return stub
    }

    private func key(_ rig: Rig) -> ChatStore.CapabilityKey { .init(connection: rig.connection.id, model: "m") }

    private struct NoReport: Error {}

    private func finished(_ check: ChatStore.CapabilityCheck?) throws -> CapabilityReport {
        guard case .done(let report) = check else { throw NoReport() }
        return report
    }

    private func addGetMe(to server: StubServer) {
        server.mcp = FakeMCP(tools: [.init(name: "get_me", readOnly: true, result: "octocat")])
    }

    @Test func aModelThatNeedsReasoningOffIsRememberedSoTheFirstRealRequestWorks() async throws {
        let stub = server { body in body["reasoning_effort"] as? String == "none" ? (200, "{}") : (400, Self.lunaRefusal) }
        addGetMe(to: stub)
        let rig = Rig(server: stub)
        defer { rig.cleanup() }
        addMCP(rig.store, at: stub)
        rig.store.setReasoningEffort(.medium)

        await rig.store.checkCapabilities(of: rig.connection.id)
        let report = try finished(rig.store.capabilityChecks[key(rig)])
        #expect(report.tools == .onlyWithReasoningOff && report.vision == .yes && report.efforts == [.none, .low, .medium])

        rig.store.send("hi")
        await untilIdle(rig.store)
        #expect(stub.chats.count == 1, "no refused request first")
        #expect(stub.chats.first?["reasoning_effort"] as? String == "none")
        #expect(rig.store.selectedConversation?.messages.last?.adaptations == [.reasoningOffForTools])
    }

    @Test func aModelWithoutToolsIsRememberedSoNoRequestCarriesThem() async throws {
        let stub = server { _ in (400, Self.noTools) }
        addGetMe(to: stub)
        let rig = Rig(server: stub)
        defer { rig.cleanup() }
        addMCP(rig.store, at: stub)

        await rig.store.checkCapabilities(of: rig.connection.id)
        let report = try finished(rig.store.capabilityChecks[key(rig)])
        #expect(report.tools == .no(reason: "this model does not support tools"))

        rig.store.send("hi")
        await untilIdle(rig.store)
        let sent = try #require(stub.chats.first)
        #expect(stub.chats.count == 1 && offeredTools(sent).isEmpty)
        #expect(rig.store.selectedConversation?.messages.last?.adaptations == [.toolsDropped(reason: "this model does not support tools")])
    }

    @Test func aModelThatTakesToolsChangesNothing() async throws {
        let stub = server { _ in (200, "{}") }
        addGetMe(to: stub)
        let rig = Rig(server: stub)
        defer { rig.cleanup() }
        addMCP(rig.store, at: stub)
        rig.store.setReasoningEffort(.medium)

        await rig.store.checkCapabilities(of: rig.connection.id)
        rig.store.send("hi")
        await untilIdle(rig.store)

        #expect(stub.chats.first?["reasoning_effort"] as? String == "medium")
        #expect(offeredTools(try #require(stub.chats.first)) == ["get_me"])
        #expect(rig.store.selectedConversation?.messages.last?.adaptations == [])
    }

    @Test func aReportOnAnotherConnectionSeedsNothing() async throws {
        let active = server { _ in (200, "{}") }
        addGetMe(to: active)
        let other = server { _ in (400, Self.noTools) }
        let rig = Rig(server: active)
        defer { rig.cleanup() }
        addMCP(rig.store, at: active)
        let elsewhere = Connection(name: "other", baseURL: other.baseURL, model: "m")
        rig.store.saveConnection(elsewhere, apiKey: "")
        rig.store.activate(rig.connection.id)

        await rig.store.checkCapabilities(of: elsewhere.id)
        let report = try finished(rig.store.capabilityChecks[.init(connection: elsewhere.id, model: "m")])
        #expect(report.tools == .no(reason: "this model does not support tools"))

        rig.store.send("hi")
        await untilIdle(rig.store)
        #expect(offeredTools(try #require(active.chats.first)) == ["get_me"], "the active model still gets tools")
    }

    @Test func aServerThatCantBeCheckedSaysSoAndKeepsNothingFromBefore() async throws {
        let rig = Rig(server: StubServer { _ in (200, sse(["ok"])) })
        defer { rig.cleanup() }

        await rig.store.checkCapabilities(of: rig.connection.id)

        #expect(rig.store.capabilityChecks[key(rig)] == .failed("Server returned HTTP 404."))
        #expect(rig.store.exchangeLog.count == 0, "checks are not attached to any reply")
    }

    @Test func aReportStaysForTheSessionAndAConnectionWithoutAModelHasNone() async throws {
        let stub = server { _ in (200, "{}") }
        let rig = Rig(server: stub)
        defer { rig.cleanup() }
        await rig.store.checkCapabilities(of: rig.connection.id)
        let first = rig.store.capabilityChecks[key(rig)]
        #expect(first != nil)

        rig.store.send("hi")
        await untilIdle(rig.store)
        #expect(rig.store.capabilityChecks[key(rig)] == first)
        #expect(rig.reopened().capabilityChecks.isEmpty, "not saved")

        let bare = Connection(name: "bare", baseURL: stub.baseURL)
        rig.store.saveConnection(bare, apiKey: "")
        await rig.store.checkCapabilities(of: bare.id)
        #expect(rig.store.capabilityChecks.keys.allSatisfy { $0.connection != bare.id })
    }

    @Test func theReportKeepsWhatTheModelListAndServerInfoSayAndNoSecrets() async throws {
        let stub = server { _ in (200, "{}") }
        stub.models = #"{"data":[{"id":"m","max_model_len":8192,"owned_by":"vllm"}]}"#
        stub.serverInfo = (200, #"{"version":"0.4.2","api_key":"sk-hidden","max_total_num_tokens":4096}"#)
        let rig = Rig(server: stub, key: "sk-live-key")
        defer { rig.cleanup() }

        await rig.store.checkCapabilities(of: rig.connection.id)

        let report = try finished(rig.store.capabilityChecks[key(rig)])
        #expect(report.contextLength == 8192)
        #expect(report.server.map(\.name) == ["max_model_len", "owned_by", "max_total_num_tokens", "version"])
        #expect(stub.authorizations.contains { $0.path.hasSuffix("/server_info") && $0.authorization == "Bearer sk-live-key" })
        #expect(!report.server.contains { $0.value.contains("sk-") })
    }

    @Test func deletingAConnectionForgetsItsReport() async throws {
        let rig = Rig(server: server { _ in (200, "{}") })
        defer { rig.cleanup() }
        await rig.store.checkCapabilities(of: rig.connection.id)
        rig.store.deleteConnection(rig.connection.id)
        #expect(rig.store.capabilityChecks.isEmpty)
    }
}
