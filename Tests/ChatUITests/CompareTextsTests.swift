import ChatCore
import Foundation
import Testing
@testable import ChatUI

@MainActor
struct CompareTextsTests {
    private static let key = "sk-live-key-123"
    private let texts = ["a kitten", "tax law", "a cat"]

    private nonisolated static func embeddings(_ vectors: [[Double]]) -> String {
        let items = vectors.enumerated().map { #"{"embedding":\#($1),"index":\#($0)}"# }
        return #"{"data":[\#(items.joined(separator: ","))],"usage":{"prompt_tokens":9,"total_tokens":9}}"#
    }

    private nonisolated static let fourVectors = embeddings([[1, 0], [1, 1], [0, 1], [1, 0.1]])
    private nonisolated static let threeScores = #"{"results":[{"index":0,"relevance_score":0.2},{"index":1,"relevance_score":-5.5},{"index":2,"relevance_score":3.5}]}"#

    private func rig(key: String = "") -> Rig {
        let server = StubServer { _ in (200, "") }
        server.embeddings = { _ in (200, Self.fourVectors) }
        server.rerank = { _ in (200, Self.threeScores) }
        return Rig(server: server, key: key)
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func result(_ rig: Rig) throws -> TextComparison {
        guard case .done(let result) = rig.store.comparisons[rig.connection.id] else {
            throw StateError(state: "\(String(describing: rig.store.comparisons[rig.connection.id]))")
        }
        return result
    }

    private struct StateError: Error { let state: String }

    @Test func anEmbeddingsRunRanksTheTextsAndKeepsTheRequest() async throws {
        let rig = rig()
        defer { rig.cleanup() }
        #expect(rig.store.comparisons[rig.connection.id] == nil, "idle until a run")

        await rig.store.compare(.embeddings, on: rig.connection.id, model: "bge", query: "small feline", texts: texts)

        let comparison = try result(rig)
        #expect(comparison.ranked.map(\.text) == ["a cat", "a kitten", "tax law"])
        #expect(comparison.dimensions == 2 && comparison.tokens == 9)
        let sent = try #require(rig.server.comparisons.first)
        #expect(rig.server.comparisons.count == 1 && sent.path == "/v1/embeddings")
        #expect(sent.body["model"] as? String == "bge" && sent.body["input"] as? [String] == ["small feline"] + texts)
        let exchange = try #require(rig.store.comparisonExchange(of: rig.connection.id))
        #expect(exchange.purpose == .embedding && exchange.status == 200 && exchange.error == nil)
        #expect(rig.store.conversations.isEmpty && !rig.store.isBusy, "no chat is touched")
    }

    @Test func aRerankRunScoresAsTheServerGaveThem() async throws {
        let rig = rig()
        defer { rig.cleanup() }

        await rig.store.compare(.rerank, on: rig.connection.id, model: "jina", query: "small feline", texts: texts)

        let comparison = try result(rig)
        #expect(comparison.ranked == [.init(text: "a cat", score: 3.5), .init(text: "a kitten", score: 0.2), .init(text: "tax law", score: -5.5)])
        #expect(comparison.dimensions == nil)
        let sent = try #require(rig.server.comparisons.first)
        #expect(sent.path == "/v1/rerank" && sent.body["query"] as? String == "small feline" && sent.body["documents"] as? [String] == texts)
        #expect(rig.store.comparisonExchange(of: rig.connection.id)?.purpose == .rerank)
    }

    @Test func theConnectionsKeyGoesOnTheWireAndIsNeverKeptInTheExchange() async throws {
        let rig = rig(key: Self.key)
        defer { rig.cleanup() }

        await rig.store.compare(.embeddings, on: rig.connection.id, model: "m", query: "q", texts: texts)

        #expect(rig.server.authorizations.contains { $0.path == "/v1/embeddings" && $0.authorization == "Bearer \(Self.key)" })
        let exchange = try #require(rig.store.comparisonExchange(of: rig.connection.id))
        #expect(exchange.requestHeader("Authorization") == "Bearer $API_KEY")
        let everything = "\(exchange)" + String(decoding: exchange.requestBody, as: UTF8.self) + exchange.curl + exchange.displayBody
        #expect(!everything.contains(Self.key))
    }

    @Test func aRunShowsRunningUntilTheServerAnswersThenItsResult() async throws {
        let gate = DispatchSemaphore(value: 0)
        let server = StubServer { _ in (200, "") }
        server.embeddings = { _ in
            gate.wait()
            return (200, Self.fourVectors)
        }
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        let id = rig.connection.id

        let run = Task { await rig.store.compare(.embeddings, on: id, model: "m", query: "q", texts: texts) }
        await until { rig.store.comparisons[id] == .running }
        #expect(rig.store.comparisons[id] == .running)
        await until { !server.comparisons.isEmpty }

        await rig.store.compare(.embeddings, on: id, model: "m", query: "q", texts: texts)
        #expect(server.comparisons.count == 1, "a second run waits for the first")

        gate.signal()
        await run.value
        #expect(try result(rig).ranked.count == 3)
    }

    @Test func leavingThePageCancelsTheRunAndLeavesItIdle() async throws {
        let release = DispatchSemaphore(value: 0)
        let server = StubServer { _ in (200, "") }
        server.embeddings = { _ in
            release.wait()
            return (200, Self.fourVectors)
        }
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        let id = rig.connection.id

        let run = Task { await rig.store.compare(.embeddings, on: id, model: "m", query: "q", texts: texts) }
        await until { server.comparisons.count == 1 }
        run.cancel()
        await run.value
        release.signal()

        #expect(rig.store.comparisons[id] == .idle)
        #expect(rig.store.comparisonExchange(of: id)?.error == Exchange.cancelledMessage, "the request that was stopped is still inspectable")
    }

    @Test func leavingMidRunPutsTheLastResultAndItsRequestBack() async throws {
        let release = DispatchSemaphore(value: 0)
        let rig = rig()
        defer { rig.cleanup() }
        let id = rig.connection.id
        await rig.store.compare(.embeddings, on: id, model: "m", query: "first", texts: texts)
        let kept = try result(rig)
        let keptExchange = try #require(rig.store.comparisonExchange(of: id))

        rig.server.embeddings = { _ in
            release.wait()
            return (200, Self.fourVectors)
        }
        let run = Task { await rig.store.compare(.embeddings, on: id, model: "m", query: "second", texts: texts) }
        await until { rig.server.comparisons.count == 2 }
        #expect(rig.store.comparisons[id] == .running)
        run.cancel()
        await run.value
        release.signal()

        #expect(rig.store.comparisons[id] == .done(kept), "the page shows what it showed before")
        #expect(rig.store.comparisonExchange(of: id) == keptExchange, "and Inspect still opens that result's request")
        #expect(rig.store.exchanges(for: id).count == 1)
    }

    @Test func aFailureOrAnotherResultReplacesTheLastRequestAsBefore() async throws {
        let rig = rig()
        defer { rig.cleanup() }
        let id = rig.connection.id
        await rig.store.compare(.embeddings, on: id, model: "m", query: "first", texts: texts)
        let first = try #require(rig.store.comparisonExchange(of: id))
        rig.server.embeddings = { _ in (500, #"{"error":{"message":"boom"}}"#) }

        await rig.store.compare(.embeddings, on: id, model: "m", query: "second", texts: texts)

        guard case .failed = rig.store.comparisons[id] else { throw StateError(state: "\(String(describing: rig.store.comparisons[id]))") }
        #expect(rig.store.comparisonExchange(of: id)?.id != first.id && rig.store.exchanges(for: id).count == 1)
    }

    @Test func theFieldsOfTheComparePageAreKeptPerConnectionAndForgottenWithIt() async throws {
        let rig = rig()
        defer { rig.cleanup() }
        let id = rig.connection.id

        var draft = rig.store.comparisonDraft(for: id)
        #expect(draft == ChatStore.ComparisonDraft(model: rig.connection.model), "a first visit starts from the connection's model")
        #expect(draft.mode == .embeddings && draft.query == "a small cat" && draft.texts.split(separator: "\n").count == 3)

        draft.mode = .rerank
        draft.model = "jina"
        draft.query = "dogs"
        draft.texts = "a\nb"
        rig.store.setComparisonDraft(draft, for: id)
        #expect(rig.store.comparisonDraft(for: id) == draft, "coming back finds the page as it was left")

        let other = Connection(name: "other", baseURL: rig.server.baseURL, model: "x")
        rig.store.saveConnection(other, apiKey: "")
        #expect(rig.store.comparisonDraft(for: other.id) == ChatStore.ComparisonDraft(model: "x"))

        rig.store.deleteConnection(id)
        #expect(rig.store.comparisonDraft(for: id) == ChatStore.ComparisonDraft(model: ""))
    }

    @Test func aMissingModelIsSaidInOneLineOnThePage() {
        #expect(TextComparisonPage.modelPrompt(model: "", hasChoices: true) == "Pick a model to run.")
        #expect(TextComparisonPage.modelPrompt(model: "  ", hasChoices: false) == "Type the name of a model to run.")
        #expect(TextComparisonPage.modelPrompt(model: "bge", hasChoices: false) == nil)
        #expect(TextComparisonPage.modelPrompt(model: "bge", hasChoices: true) == nil)
    }

    @Test func aServerWithNoEndpointFailsWithItsOwnWordsAndOneSentenceAndStaysInspectable() async throws {
        let server = StubServer { _ in (200, "") }
        server.embeddings = { _ in (404, #"{"detail":"Not Found"}"#) }
        let rig = Rig(server: server)
        defer { rig.cleanup() }

        await rig.store.compare(.embeddings, on: rig.connection.id, model: "m", query: "q", texts: texts)
        #expect(rig.store.comparisons[rig.connection.id] == .failed("HTTP 404: Not Found\nThis server has no embeddings endpoint."))
        let exchange = try #require(rig.store.comparisonExchange(of: rig.connection.id))
        #expect(exchange.status == 404 && exchange.error == "HTTP 404: Not Found")

        await rig.store.compare(.rerank, on: rig.connection.id, model: "m", query: "q", texts: texts)
        #expect(rig.store.comparisons[rig.connection.id] == .failed("Server returned HTTP 404.\nThis server has no rerank endpoint."))
    }

    @Test func aRefusalAndAnOddReplyReachThePageAsPlainMessages() async throws {
        let server = StubServer { _ in (200, "") }
        server.rerank = { _ in (501, #"{"error":{"code":501,"message":"This server does not support reranking."}}"#) }
        server.embeddings = { _ in (200, Self.embeddings([[1, 0]])) }
        let rig = Rig(server: server)
        defer { rig.cleanup() }
        let id = rig.connection.id

        await rig.store.compare(.rerank, on: id, model: "m", query: "q", texts: texts)
        #expect(rig.store.comparisons[id] == .failed("HTTP 501: This server does not support reranking."))

        await rig.store.compare(.embeddings, on: id, model: "m", query: "q", texts: texts)
        #expect(rig.store.comparisons[id] == .failed("The server sent 1 vectors for 4 texts."))
        #expect(rig.store.exchanges(for: id).count == 1, "only the last run's request is kept")
    }

    @Test func theRequestCanBeEditedAndResentOnTheConnectionAndJoinsTheSameRun() async throws {
        let rig = rig(key: Self.key)
        defer { rig.cleanup() }
        let id = rig.connection.id
        await rig.store.compare(.embeddings, on: id, model: "m", query: "small feline", texts: texts)
        let exchange = try #require(rig.store.comparisonExchange(of: id))
        #expect(exchange.isEditable)
        #expect(exchange.curl.contains("/v1/embeddings") && exchange.curl.contains("$API_KEY"))

        let edited = exchange.displayBody.replacingOccurrences(of: "tax law", with: "parking fines")
        #expect(edited != exchange.displayBody)
        let sent = await rig.store.resend(exchange, editedText: edited, for: id)

        #expect(sent.purpose == .resend && sent.status == 200 && sent.error == nil)
        let second = try #require(rig.server.comparisons.last)
        #expect(rig.server.comparisons.count == 2 && (second.body["input"] as? [String])?.contains("parking fines") == true)
        #expect(rig.server.authorizations.last?.authorization == "Bearer \(Self.key)")
        #expect(rig.store.exchanges(for: id).map(\.purpose) == [.embedding, .resend])
        #expect(sent.requestHeader("Authorization") == "Bearer $API_KEY")
    }

    @Test func aConnectionThatIsNotActiveUsesItsOwnKeyAndServer() async throws {
        let active = rig(key: "active-key")
        defer { active.cleanup() }
        let other = StubServer { _ in (200, "") }
        other.embeddings = { _ in (200, Self.fourVectors) }
        let elsewhere = Connection(name: "other", baseURL: other.baseURL, model: "m")
        active.store.saveConnection(elsewhere, apiKey: "other-key")
        active.store.activate(active.connection.id)

        await active.store.compare(.embeddings, on: elsewhere.id, model: "m", query: "q", texts: texts)

        #expect(other.authorizations.first { $0.path == "/v1/embeddings" }?.authorization == "Bearer other-key")
        #expect(active.server.comparisons.isEmpty)
        let exchange = try #require(active.store.comparisonExchange(of: elsewhere.id))
        let sent = await active.store.resend(exchange, editedText: exchange.displayBody, for: elsewhere.id)
        #expect(sent.status == 200 && other.authorizations.last?.authorization == "Bearer other-key", "the resend uses that connection too")
    }

    @Test func aNewRunReplacesTheLastOneAndDeletingTheConnectionForgetsIt() async throws {
        let rig = rig()
        defer { rig.cleanup() }
        let id = rig.connection.id
        await rig.store.compare(.embeddings, on: id, model: "m", query: "q", texts: texts)
        let first = try #require(rig.store.comparisonExchange(of: id))

        await rig.store.compare(.rerank, on: id, model: "m", query: "q", texts: texts)
        #expect(rig.store.comparisonExchange(of: id)?.id != first.id)
        #expect(rig.store.exchanges(for: id).map(\.purpose) == [.rerank])
        #expect(rig.reopened().comparisons.isEmpty, "not saved")

        rig.store.deleteConnection(id)
        #expect(rig.store.comparisons.isEmpty && rig.store.exchanges(for: id).isEmpty)
    }

    @Test func theConnectionsModelsAreListedWithItsOwnKey() async throws {
        let server = StubServer { _ in (200, "") }
        server.models = #"{"data":[{"id":"bge-small"},{"id":"jina-rerank"}]}"#
        let rig = Rig(server: server, key: Self.key)
        defer { rig.cleanup() }

        let models = try await rig.store.servedModels(of: rig.connection.id)

        #expect(models.map(\.id) == ["bge-small", "jina-rerank"])
        #expect(server.authorizations.first { $0.path.hasSuffix("/models") }?.authorization == "Bearer \(Self.key)")
    }
}
