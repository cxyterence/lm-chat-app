import ChatCore
import Foundation
import Testing
@testable import ChatUI

@MainActor
struct AdaptationNotesTests {
    private nonisolated static let lunaRefusal = """
        {"error":{"message":"Function tools with reasoning_effort are not supported for gpt-6-luna in /v1/chat/completions. To use function tools, use /v1/responses or set reasoning_effort to 'none'."}}
        """
    private nonisolated static let noTools = #"{"error":{"message":"this model does not support tools"}}"#

    private func replies(_ store: ChatStore) -> [ChatMessage] {
        store.selectedConversation?.messages.filter { $0.role == .assistant } ?? []
    }

    private func addGetMe(to server: StubServer) -> FakeMCP {
        let mcp = FakeMCP(tools: [.init(name: "get_me", readOnly: true, result: "octocat")])
        server.mcp = mcp
        return mcp
    }

    private func untilEffortsKnown(_ store: ChatStore) async {
        for _ in 0..<400 {
            if case .known = store.effortLevels { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A chat model that takes tools and answers a tool result.
    private func toolFriendly() -> StubServer {
        StubServer { body in
            if lastRole(body) == "tool" { return (200, sse(["done"])) }
            return offeredTools(body).contains("get_me") ? (200, toolCallReply("get_me")) : (200, sse(["plain"]))
        }
    }

    @Test func aPlainReplyCarriesNoNotes() async throws {
        let server = toolFriendly()
        _ = addGetMe(to: server)
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        addMCP(rig.store, at: server)
        rig.store.setReasoningEffort(.medium)

        rig.store.send("who am I?")
        await untilIdle(rig.store)

        #expect(replies(rig.store).count == 2, "a tool round happened")
        #expect(replies(rig.store).allSatisfy { $0.adaptations.isEmpty })
        let plain = Rig(server: echoServer())
        defer { plain.cleanup() }
        plain.store.send("hi")
        await untilIdle(plain.store)
        #expect(replies(plain.store).allSatisfy { $0.adaptations.isEmpty })
    }

    @Test func aServerThatRefusesToolsGetsNoneAndSaysWhyUnderEveryReplyThatLeavesThemOut() async throws {
        let server = StubServer { body in
            body["tools"] != nil ? (400, Self.noTools) : (200, sse(["plain"]))
        }
        _ = addGetMe(to: server)
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        addMCP(rig.store, at: server)
        let reason = "this model does not support tools"

        rig.store.send("hi")
        await untilIdle(rig.store)
        let first = try #require(replies(rig.store).first)
        #expect(first.adaptations == [.toolsDropped(reason: reason)])
        let tried = rig.store.exchanges(for: first.id)
        #expect(tried.map(\.status) == [400, 400, 200], "the refused request, its repeat without token counts and the one that worked")
        #expect(tried[0].error?.contains(reason) == true)

        rig.store.send("again")
        await untilIdle(rig.store)
        #expect(replies(rig.store).last?.adaptations == [.toolsDropped(reason: reason)])
        #expect(server.asked.map { offeredTools($0).isEmpty } == [false, true, true])

        let saved = rig.reopened().conversations.first?.messages.filter { $0.role == .assistant }
        #expect(saved?.map(\.adaptations) == [[.toolsDropped(reason: reason)], [.toolsDropped(reason: reason)]], "kept across a relaunch")
    }

    @Test func aModelThatTakesToolsOnlyWithReasoningOffIsAskedThatWayEveryRound() async throws {
        let server = StubServer { body in
            if body["tools"] != nil, body["reasoning_effort"] as? String != "none" { return (400, Self.lunaRefusal) }
            if lastRole(body) == "tool" { return (200, sse(["done"])) }
            return offeredTools(body).contains("get_me") ? (200, toolCallReply("get_me")) : (200, sse(["plain"]))
        }
        _ = addGetMe(to: server)
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        addMCP(rig.store, at: server)
        rig.store.setReasoningEffort(.medium)

        rig.store.send("who am I?")
        await untilIdle(rig.store)
        #expect(server.asked.map { $0["reasoning_effort"] as? String } == ["medium", "none", "none"], "learned from the first refusal")
        #expect(replies(rig.store).map(\.adaptations) == [[.reasoningOffForTools], [.reasoningOffForTools]], "each round says so")

        rig.store.send("again")
        await untilIdle(rig.store)
        #expect(server.asked.dropFirst(3).map { $0["reasoning_effort"] as? String } == ["none", "none"], "no failed request this time")
        #expect(replies(rig.store).suffix(2).allSatisfy { $0.adaptations == [.reasoningOffForTools] })

        let saved = rig.reopened().conversations.first?.messages.filter { $0.role == .assistant }
        #expect(saved?.allSatisfy { $0.adaptations == [.reasoningOffForTools] } == true)
    }

    @Test func aLevelTheModelDoesntTakeIsChangedAndSaidSo() async throws {
        let server = echoServer()
        server.models = #"{"data":[{"id":"m"}]}"#
        server.probe = { body in
            ["none", "low", "medium"].contains(body["reasoning_effort"] as? String ?? "none")
                ? (200, "{}") : (400, #"{"error":{"message":"Unexpected reasoning effort"}}"#)
        }
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        await untilEffortsKnown(rig.store)
        rig.store.setReasoningEffort(.high)

        rig.store.send("hi")
        await untilIdle(rig.store)

        #expect(server.chats.first?["reasoning_effort"] as? String == "low")
        #expect(replies(rig.store).first?.adaptations == [.effortChanged(from: .high, to: .low)])

        rig.store.setReasoningEffort(.medium)
        rig.store.send("again")
        await untilIdle(rig.store)
        #expect(replies(rig.store).last?.adaptations == [], "a level the model takes is sent as chosen")
        #expect(rig.reopened().conversations.first?.messages.first { $0.role == .assistant }?.adaptations
                == [.effortChanged(from: .high, to: .low)])
    }

    @Test func aModelThatTakesNoLevelGetsNoneAndSaysSo() async throws {
        let server = echoServer()
        server.models = #"{"data":[{"id":"m"}]}"#
        server.probe = { _ in (200, "{}") }
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        await untilEffortsKnown(rig.store)
        rig.store.setReasoningEffort(.high)

        rig.store.send("hi")
        await untilIdle(rig.store)

        #expect(server.chats.first?["reasoning_effort"] == nil)
        #expect(replies(rig.store).first?.adaptations == [.effortChanged(from: .high, to: nil)])
    }

    @Test func aServerThatRefusesTokenCountsIsNotAskedAgainAndTheReplySaysSo() async throws {
        let server = StubServer { body in
            body["stream_options"] != nil ? (400, #"{"error":{"message":"Unknown field: stream_options"}}"#) : (200, sse(["Hi"]))
        }
        let rig = Rig(server: server)
        defer { rig.cleanup() }

        rig.store.send("hello")
        await untilIdle(rig.store)
        let first = try #require(replies(rig.store).first)
        #expect(first.adaptations == [.usageNotRequested])
        #expect(rig.store.exchanges(for: first.id).map(\.status) == [400, 200])

        rig.store.send("again")
        await untilIdle(rig.store)
        #expect(server.chats.map { $0["stream_options"] != nil } == [true, false, false],
                "refused once, asked again without, and the second reply doesn't ask")
        #expect(replies(rig.store).last?.adaptations == [], "it wasn't adapted this time, so there is nothing to say")
        #expect(rig.reopened().conversations.first?.messages.first { $0.role == .assistant }?.adaptations == [.usageNotRequested])

        let other = StubServer { _ in (200, sse(["Hi"])) }
        let elsewhere = Connection(name: "other", baseURL: other.baseURL, model: "m")
        rig.store.saveConnection(elsewhere, apiKey: "")
        rig.store.send("hello")
        await untilIdle(rig.store)
        #expect(other.chats.first?["stream_options"] != nil, "another host is asked")
    }

    @Test func aTitleNeverAsksForTokenCounts() async throws {
        let server = echoServer()
        let rig = Rig(server: server)
        defer { rig.cleanup() }

        rig.store.send("hello")
        await untilIdle(rig.store)
        for _ in 0..<400 where server.titles.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(server.titles.count == 1)
        #expect(server.titles.allSatisfy { $0["stream_options"] == nil })
        #expect(server.chats.allSatisfy { $0["stream_options"] != nil }, "the reply itself still does")
    }

    @Test func aToolsRefusalIsNotMistakenForARefusalOfTokenCounts() async throws {
        let server = StubServer { body in
            if body["tools"] != nil, body["reasoning_effort"] as? String != "none" { return (400, Self.lunaRefusal) }
            if lastRole(body) == "tool" { return (200, sse(["done"])) }
            return offeredTools(body).contains("get_me") ? (200, toolCallReply("get_me")) : (200, sse(["plain"]))
        }
        _ = addGetMe(to: server)
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        addMCP(rig.store, at: server)
        rig.store.setReasoningEffort(.medium)

        rig.store.send("who am I?")
        await untilIdle(rig.store)
        rig.store.send("again")
        await untilIdle(rig.store)

        #expect(replies(rig.store).flatMap(\.adaptations).allSatisfy { $0 == .reasoningOffForTools }, "no note about token counts")
        #expect(replies(rig.store).map(\.adaptations) == Array(repeating: [.reasoningOffForTools], count: 4))
        #expect(server.chats.map { $0["stream_options"] != nil } == [true, false, true, true, true, true],
                "the refusal is repeated bare once, and token counts are still asked for after it")
        #expect(server.chats.dropFirst(2).allSatisfy { $0["reasoning_effort"] as? String == "none" })
    }

    @Test func aRefusalOfTokenCountsIsRememberedPerServerAddressNotPerHost() async throws {
        let server = StubServer { body in
            body["stream_options"] != nil ? (400, #"{"error":{"message":"Bad Request"}}"#) : (200, sse(["Hi"]))
        }
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        let (first, second) = (Connection(name: "a", baseURL: URL(string: "http://\(server.host):8081/v1")!, model: "m"),
                               Connection(name: "b", baseURL: URL(string: "http://\(server.host):8082/v1")!, model: "m"))
        rig.store.saveConnection(first, apiKey: "")
        rig.store.saveConnection(second, apiKey: "")

        rig.store.activate(first.id)
        rig.store.send("one")
        await untilIdle(rig.store)
        rig.store.send("two")
        await untilIdle(rig.store)
        #expect(server.chats.map { $0["stream_options"] != nil } == [true, false, false])

        rig.store.activate(second.id)
        rig.store.send("three")
        await untilIdle(rig.store)
        #expect(server.chats.map { $0["stream_options"] != nil } == [true, false, false, true, false], "the other port is asked afresh")
    }

    private func drawing(_ arguments: String) -> (server: StubServer, rig: Rig) {
        let server = StubServer { body in
            if lastRole(body) == "tool" { return (200, sse(["done"])) }
            return offeredTools(body).contains("generate_image") ? (200, toolCallReply("generate_image", arguments: arguments))
                                                                 : (200, sse(["no picture"]))
        }
        let reply = #"{"data":[{"b64_json":"\#(makePNG(width: 64, height: 48).base64EncodedString())"}]}"#
        server.models = #"{"data":[{"id":"img","task_type":"t2i"}]}"#
        server.image = { _ in (200, reply) }
        let rig = Rig(server: server)
        useImageTool(rig.store, at: server)
        return (server, rig)
    }

    @Test func aSizeTheAppChoseForAnEditIsSaidWithThePictureItFollowed() async throws {
        let (_, rig) = drawing(#"{"prompt":"The same scene at night.","source_images":[1]}"#)
        defer { rig.cleanup() }
        let photo = try rig.store.images.save(makePNG(width: 1000, height: 600))

        rig.store.send("make it night", images: [photo])
        await untilIdle(rig.store)

        #expect(replies(rig.store).first?.adaptations == [.imageSize("1008x608", fromImage: 1)])
        #expect(replies(rig.store).last?.adaptations == [])
        #expect(rig.reopened().conversations.first?.messages.first { $0.role == .assistant }?.adaptations
                == [.imageSize("1008x608", fromImage: 1)])
    }

    @Test(arguments: [#"{"prompt":"x","source_images":[1],"aspect_ratio":"1:1"}"#,
                      #"{"prompt":"x","source_images":[1],"resolution":"1k"}"#,
                      #"{"prompt":"A red fox."}"#])
    func aSizeTheModelNamedOrNoSizeAtAllIsNotACorrection(arguments: String) async throws {
        let (_, rig) = drawing(arguments)
        defer { rig.cleanup() }
        let photo = try rig.store.images.save(makePNG(width: 1000, height: 600))

        rig.store.send("draw", images: [photo])
        await untilIdle(rig.store)

        #expect(replies(rig.store).allSatisfy { $0.adaptations.isEmpty })
    }
}
