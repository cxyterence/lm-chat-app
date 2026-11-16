import Foundation
import Testing
@testable import ChatCore

struct TextComparisonTests {
    private static let key = "sk-stub-secret-123"

    private func embeddingsReply(_ vectors: [[Double]], indexes: [Int]? = nil, usage: String = #","usage":{"prompt_tokens":12,"total_tokens":12}"#) -> String {
        let items = vectors.enumerated().map { offset, vector in
            #"{"embedding":\#(vector),"index":\#(indexes?[offset] ?? offset)}"#
        }
        return #"{"data":[\#(items.joined(separator: ","))]\#(usage)}"#
    }

    private func rerankReply(_ scores: [(Int, Double)], list: String = "results", field: String = "relevance_score") -> String {
        #"{"\#(list)":[\#(scores.map { #"{"index":\#($0.0),"\#(field)":\#($0.1)}"# }.joined(separator: ","))],"usage":{"prompt_tokens":31,"total_tokens":31}}"#
    }

    private let texts = ["a kitten", "tax law", "a cat"]

    @Test func embeddingsSendTheQueryAndTheTextsInOneRequest() async throws {
        let server = StubServer { _ in (200, embeddingsReply([[1, 0], [0, 1], [1, 1], [1, 0.1]])) }

        _ = try await server.makeClient(apiKey: Self.key).compare(.embeddings, model: "bge", query: "small feline", texts: texts)

        let requests = server.requests
        #expect(requests.count == 1 && requests[0].path == "/v1/embeddings" && requests[0].method == "POST")
        #expect(requests[0].contentType == "application/json")
        let body = try #require(server.bodies.first)
        #expect(Set(body.keys) == ["model", "input"])
        #expect(body["model"] as? String == "bge")
        #expect(body["input"] as? [String] == ["small feline", "a kitten", "tax law", "a cat"])
    }

    @Test func embeddingsRankTheTextsByCosineSimilarityHighToLow() async throws {
        let server = StubServer { _ in (200, embeddingsReply([[1, 0], [1, 1], [0, 1], [1, 0.1]])) }

        let result = try await server.client.compare(.embeddings, model: "m", query: "q", texts: texts)

        #expect(result.mode == .embeddings)
        #expect(result.ranked.map(\.text) == ["a cat", "a kitten", "tax law"])
        #expect(abs(result.ranked[1].score - 0.7071) < 0.001 && result.ranked[2].score == 0)
        #expect(result.dimensions == 2 && result.tokens == 12)
        #expect(result.seconds >= 0)
    }

    @Test func embeddingsInAnyOrderAreReadByTheirIndex() async throws {
        let shuffled = embeddingsReply([[1, 0.1], [0, 1], [1, 1], [1, 0]], indexes: [3, 2, 1, 0])
        let server = StubServer { _ in (200, shuffled) }

        let result = try await server.client.compare(.embeddings, model: "m", query: "q", texts: texts)

        #expect(result.ranked.map(\.text) == ["a cat", "a kitten", "tax law"])
    }

    @Test func equalScoresKeepTheOrderTheTextsWereGiven() async throws {
        let server = StubServer { _ in (200, embeddingsReply([[1, 0], [1, 0], [1, 0], [1, 0]])) }
        let result = try await server.client.compare(.embeddings, model: "m", query: "q", texts: texts)
        #expect(result.ranked.map(\.text) == texts)
    }

    @Test func aWrongNumberOfVectorsOrUnequalOnesIsAPlainFailure() async throws {
        let few = StubServer { _ in (200, embeddingsReply([[1, 0], [1, 1]])) }
        await #expect(throws: ChatClientError.unexpected("The server sent 2 vectors for 4 texts.")) {
            try await few.client.embeddings(model: "m", inputs: ["q"] + texts)
        }
        let uneven = StubServer { _ in (200, embeddingsReply([[1, 0], [1, 1, 1], [1, 0], [0, 1]])) }
        await #expect(throws: ChatClientError.unexpected("The server sent vectors of different lengths.")) {
            try await uneven.client.embeddings(model: "m", inputs: ["q"] + texts)
        }
        let repeated = StubServer { _ in (200, embeddingsReply([[1, 0], [1, 0], [1, 0], [1, 0]], indexes: [0, 1, 1, 3])) }
        await #expect(throws: ChatClientError.unexpected("The server's vectors don't match the texts sent.")) {
            try await repeated.client.embeddings(model: "m", inputs: ["q"] + texts)
        }
        let message = ChatClientError.unexpected("The server sent 2 vectors for 4 texts.").localizedDescription
        #expect(message == "The server sent 2 vectors for 4 texts.", "no prefix: it is already plain")
    }

    @Test func aReplyThatIsNotAnEmbeddingsListCannotBeUnderstood() async throws {
        for body in ["not json", #"{"data":[{"index":0}]}"#, #"{"object":"list"}"#] {
            let server = StubServer { _ in (200, body) }
            await #expect(throws: ChatClientError.invalidResponse) { try await server.client.embeddings(model: "m", inputs: ["q"]) }
        }
    }

    @Test func rerankSendsTheQueryAndTheDocumentsAndRanksByRelevanceScore() async throws {
        let server = StubServer { _ in (200, rerankReply([(0, 4.2), (1, -9.87654), (2, 7.1)])) }

        let result = try await server.makeClient(apiKey: Self.key).compare(.rerank, model: "jina", query: "small feline", texts: texts)

        let requests = server.requests
        #expect(requests.count == 1 && requests[0].path == "/v1/rerank" && requests[0].method == "POST")
        let body = try #require(server.bodies.first)
        #expect(Set(body.keys) == ["model", "query", "documents"])
        #expect(body["model"] as? String == "jina" && body["query"] as? String == "small feline")
        #expect(body["documents"] as? [String] == texts)
        #expect(result.mode == .rerank)
        #expect(result.ranked == [.init(text: "a cat", score: 7.1), .init(text: "a kitten", score: 4.2), .init(text: "tax law", score: -9.87654)])
        #expect(result.dimensions == nil && result.tokens == 31)
    }

    @Test func rerankAlsoReadsTheListUnderDataAndTheScoreUnderScore() async throws {
        let server = StubServer { _ in (200, rerankReply([(2, 0.9), (0, 0.5), (1, 0.1)], list: "data", field: "score")) }

        let result = try await server.client.compare(.rerank, model: "m", query: "q", texts: texts)

        #expect(result.ranked.map(\.text) == ["a cat", "a kitten", "tax law"])
    }

    @Test func malformedRerankRepliesFailPlainly() async throws {
        let few = StubServer { _ in (200, rerankReply([(0, 1)])) }
        await #expect(throws: ChatClientError.unexpected("The server sent 1 scores for 3 texts.")) {
            try await few.client.rerank(model: "m", query: "q", documents: texts)
        }
        let outside = StubServer { _ in (200, rerankReply([(0, 1), (1, 1), (7, 1)])) }
        await #expect(throws: ChatClientError.unexpected("The server's scores don't match the texts sent.")) {
            try await outside.client.rerank(model: "m", query: "q", documents: texts)
        }
        for body in ["", #"{"results":[{"index":0}]}"#, #"{"results":[{"relevance_score":1}]}"#, #"{"other":[]}"#] {
            let server = StubServer { _ in (200, body) }
            await #expect(throws: ChatClientError.invalidResponse) { try await server.client.rerank(model: "m", query: "q", documents: ["a"]) }
        }
    }

    @Test func cosineSimilarityOfEdgeCases() {
        #expect(Similarity.cosine([1, 2, 3], [1, 2, 3]) > 0.999_999)
        #expect(Similarity.cosine([1, 0], [-1, 0]) == -1)
        #expect(Similarity.cosine([1, 0], [0, 1]) == 0)
        #expect(Similarity.cosine([0, 0, 0], [1, 2, 3]) == 0, "a zero vector is 0, not NaN")
        #expect(Similarity.cosine([0, 0], [0, 0]) == 0)
        #expect(Similarity.cosine([1, 2], [1, 2, 3]) == 0)
        #expect(Similarity.cosine([], []) == 0)
        #expect(Similarity.cosine([3, 4], [6, 8]) > 0.999_999)
    }

    @Test func aMissingEndpointGetsTheServersWordsAndOnePlainSentence() async throws {
        let notFound = StubServer { _ in (404, #"{"detail":"Not Found"}"#) }
        let missing = await Result { try await notFound.client.compare(.embeddings, model: "m", query: "q", texts: ["a"]) }
        guard case .failure(let error) = missing else { Issue.record("a 404 should fail"); return }
        #expect(error as? ChatClientError == .http(status: 404, message: "Not Found"))
        #expect(TextComparison.failureMessage(for: error, mode: .embeddings) == "HTTP 404: Not Found\nThis server has no embeddings endpoint.")
        #expect(TextComparison.failureMessage(for: error, mode: .rerank) == "HTTP 404: Not Found\nThis server has no rerank endpoint.")

        let unsupported = StubServer { _ in (501, #"{"error":{"code":501,"message":"This server does not support reranking. Start it with --reranking"}}"#) }
        let refused = await Result { try await unsupported.client.compare(.rerank, model: "m", query: "q", texts: ["a"]) }
        guard case .failure(let refusal) = refused else { Issue.record("a 501 should fail"); return }
        #expect(TextComparison.failureMessage(for: refusal, mode: .rerank)
                == "HTTP 501: This server does not support reranking. Start it with --reranking")
        #expect(TextComparison.failureMessage(for: ChatClientError.unexpected("odd"), mode: .rerank) == "odd")
    }

    @Test func theExchangeIsKeptWithItsPurposeAndNeverHoldsTheKey() async throws {
        let server = StubServer { path, _ in
            path.hasSuffix("/rerank") ? (200, rerankReply([(0, 1), (1, 0), (2, 2)])) : (200, embeddingsReply([[1, 0], [1, 0], [0, 1], [1, 1]]))
        }
        let recorder = Recorder()
        let client = server.makeClient(apiKey: Self.key, record: recorder.sink)

        _ = try await client.compare(.embeddings, model: "m", query: "q", texts: texts)
        _ = try await client.compare(.rerank, model: "m", query: "q", texts: texts)
        let failing = StubServer { _ in (404, "Not Found") }
        _ = try? await failing.makeClient(apiKey: Self.key, record: recorder.sink).compare(.embeddings, model: "m", query: "q", texts: texts)

        let exchanges = recorder.exchanges
        #expect(exchanges.map(\.purpose) == [.embedding, .rerank, .embedding])
        #expect(exchanges.map(\.status) == [200, 200, 404])
        #expect(exchanges.last?.error == "HTTP 404: Not Found")
        #expect(exchanges.allSatisfy { $0.requestHeader("Authorization") == "Bearer $API_KEY" })
        #expect(exchanges.allSatisfy { !("\($0)" + String(decoding: $0.requestBody, as: UTF8.self) + $0.curl).contains(Self.key) })
        #expect(exchanges[0].isEditable)
    }

    @Test func textsAreOnePerLineWithBlankLinesIgnored() {
        #expect(TextComparison.texts(from: "one\n\n  two  \r\n\t\nthree\n") == ["one", "two", "three"])
        #expect(TextComparison.texts(from: " \n ").isEmpty)
    }

    @Test func scoresAreShownAsGivenToFourSignificantDigitsNeverAsPercentages() {
        #expect(TextComparison.format(score: 0.812345) == "0.8123")
        #expect(TextComparison.format(score: -9.87654) == "-9.877")
        #expect(TextComparison.format(score: 12.5) == "12.5")
        #expect(TextComparison.format(score: 0) == "0")
        #expect(TextComparison.format(score: -0.00001234) == "-1.234e-05")
        #expect(!TextComparison.format(score: 0.5).contains("%"))
    }

    @Test func theSummaryLeavesOutWhatTheServerDidNotReport() {
        let english = Locale(identifier: "en_US")
        func summary(dimensions: Int?, tokens: Int?, seconds: TimeInterval) -> String {
            TextComparison(mode: .embeddings, ranked: [], dimensions: dimensions, tokens: tokens, seconds: seconds).summary(locale: english)
        }
        #expect(summary(dimensions: 384, tokens: 12, seconds: 0.123) == "384 dimensions · 0.12 s · 12 tokens")
        #expect(summary(dimensions: nil, tokens: 31, seconds: 0.5) == "0.50 s · 31 tokens")
        #expect(summary(dimensions: 1536, tokens: nil, seconds: 12.34) == "1,536 dimensions · 12.3 s")
        #expect(summary(dimensions: nil, tokens: nil, seconds: 0.04) == "0.04 s")
    }
}
