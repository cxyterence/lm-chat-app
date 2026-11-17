import ChatCore
import Foundation
import Testing
@testable import ChatUI

/// Drives the real store through the calls the Compare Texts page makes, against a real embeddings server and a real
/// rerank server (two llama-server processes serve both). Skipped unless LIVE_EMBED_BASE, LIVE_EMBED_MODEL,
/// LIVE_RERANK_BASE and LIVE_RERANK_MODEL are set. Run with `scripts/live_test.sh LiveCompareTests`.
@MainActor
@Suite(.enabled(if: LiveCompareServers.current != nil, "set LIVE_EMBED_BASE, LIVE_EMBED_MODEL, LIVE_RERANK_BASE and LIVE_RERANK_MODEL to run"))
struct LiveCompareTests {
    private let query = "small feline"
    private let texts = ["a kitten", "tax law", "a cat"]

    private func store(base: String, model: String) throws -> (store: ChatStore, id: UUID, cleanup: @Sendable () -> Void) {
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        let store = ChatStore(defaults: defaults, fileURL: file, secrets: .memory())
        let connection = Connection(name: "live", baseURL: try ServerConfig.parse(baseURL: base, apiKey: "").baseURL, model: model)
        store.saveConnection(connection, apiKey: "")
        return (store, connection.id, { cleanDefaults(); cleanFile() })
    }

    /// Runs the page's comparison, then checks the request is inspectable and resends it edited through the store.
    private func run(_ mode: TextComparison.Mode, base: String, model: String) async throws -> TextComparison {
        let (store, id, cleanup) = try store(base: base, model: model)
        defer { cleanup() }

        await store.compare(mode, on: id, model: model, query: query, texts: texts)
        guard case .done(let result) = store.comparisons[id] else {
            throw LiveFailure(message: "\(mode): \(String(describing: store.comparisons[id]))")
        }
        #expect(result.ranked.last?.text == "tax law", "\(mode) ranked \(result.ranked.map(\.text))")
        #expect(result.ranked.count == texts.count)

        let exchange = try #require(store.comparisonExchange(of: id), "no request was kept")
        #expect(exchange.status == 200 && exchange.error == nil)
        #expect(exchange.purpose == (mode == .embeddings ? .embedding : .rerank))
        #expect(exchange.curl.contains(mode.rawValue))

        let edited = exchange.displayBody.replacingOccurrences(of: "a cat", with: "a lion")
        #expect(edited != exchange.displayBody)
        let sent = await store.resend(exchange, editedText: edited, for: id)
        #expect(sent.purpose == .resend && sent.status == 200 && sent.error == nil, "\(sent.error ?? "") \(sent.responseBody.prefix(200))")
        #expect(store.exchanges(for: id).map(\.purpose) == [exchange.purpose, .resend])

        let order = result.ranked.map { "\($0.text) \(TextComparison.format(score: $0.score))" }.joined(separator: ", ")
        print("live \(mode.rawValue): \(order) | \(result.summary()) | inspect \(exchange.status ?? 0), resend \(sent.status ?? 0)")
        return result
    }

    private struct LiveFailure: Error { let message: String }

    @Test func embeddingsRankTaxLawLastWith384DimensionsAndTheRequestCanBeInspectedAndResent() async throws {
        let live = try #require(LiveCompareServers.current)
        let result = try await run(.embeddings, base: live.embedBase, model: live.embedModel)
        #expect(result.dimensions == 384)
        #expect((result.tokens ?? 0) > 0)
    }

    @Test func rerankRanksTaxLawLastAndTheRequestCanBeInspectedAndResent() async throws {
        let live = try #require(LiveCompareServers.current)
        let result = try await run(.rerank, base: live.rerankBase, model: live.rerankModel)
        #expect(result.dimensions == nil)
    }

    @Test func rerankOnTheEmbeddingsServerFailsWithItsOwn501Message() async throws {
        let live = try #require(LiveCompareServers.current)
        let (store, id, cleanup) = try store(base: live.embedBase, model: live.embedModel)
        defer { cleanup() }

        await store.compare(.rerank, on: id, model: live.embedModel, query: query, texts: texts)

        guard case .failed(let message)? = store.comparisons[id] else {
            throw LiveFailure(message: "expected a failure, got \(String(describing: store.comparisons[id]))")
        }
        #expect(message.hasPrefix("HTTP 501: "), "\(message)")
        #expect(message.localizedCaseInsensitiveContains("rerank"))
        let exchange = try #require(store.comparisonExchange(of: id))
        #expect(exchange.status == 501 && exchange.purpose == .rerank)
        print("live rerank on the embeddings server: \(message.replacingOccurrences(of: "\n", with: " | "))")
    }
}

/// Two real servers, one serving embeddings and one reranking, read from the environment. Nil unless all four are set.
struct LiveCompareServers: Sendable {
    let embedBase, embedModel, rerankBase, rerankModel: String

    static let current: LiveCompareServers? = {
        let env = ProcessInfo.processInfo.environment
        let values = ["LIVE_EMBED_BASE", "LIVE_EMBED_MODEL", "LIVE_RERANK_BASE", "LIVE_RERANK_MODEL"].map { env[$0] ?? "" }
        guard !values.contains(where: \.isEmpty) else { return nil }
        return LiveCompareServers(embedBase: values[0], embedModel: values[1], rerankBase: values[2], rerankModel: values[3])
    }()
}
