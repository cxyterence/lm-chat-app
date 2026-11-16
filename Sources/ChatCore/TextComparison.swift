import Foundation

public struct EmbeddingResult: Equatable, Sendable {
    /// One vector per input, in the order the inputs were sent.
    public var vectors: [[Double]]
    public var promptTokens: Int?

    public init(vectors: [[Double]], promptTokens: Int? = nil) {
        self.vectors = vectors
        self.promptTokens = promptTokens
    }

    public var dimensions: Int { vectors.first?.count ?? 0 }
}

public struct RerankScore: Equatable, Sendable {
    /// Which document the score is for, by its position in the request.
    public var index: Int
    public var score: Double

    public init(index: Int, score: Double) {
        self.index = index
        self.score = score
    }
}

public struct RerankResult: Equatable, Sendable {
    /// In the order the server sent them.
    public var scores: [RerankScore]
    public var promptTokens: Int?

    public init(scores: [RerankScore], promptTokens: Int? = nil) {
        self.scores = scores
        self.promptTokens = promptTokens
    }
}

public enum Similarity {
    /// Cosine of the angle between two vectors. A zero vector, or two of different lengths, has none, which reads as 0.
    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, squaresA = 0.0, squaresB = 0.0
        for (x, y) in zip(a, b) {
            dot += x * y
            squaresA += x * x
            squaresB += y * y
        }
        let norm = squaresA.squareRoot() * squaresB.squareRoot()
        return norm > 0 ? dot / norm : 0
    }
}

/// What comparing a query with some texts found, for the page and `chatcli` alike.
public struct TextComparison: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case embeddings, rerank

        public var title: String { self == .embeddings ? "Embeddings" : "Rerank" }
        var noEndpoint: String { "This server has no \(rawValue) endpoint." }
    }

    public struct Entry: Equatable, Sendable {
        public let text: String
        public let score: Double

        public init(text: String, score: Double) {
            self.text = text
            self.score = score
        }
    }

    public var mode: Mode
    /// The texts, best match first.
    public var ranked: [Entry]
    public var dimensions: Int?
    public var tokens: Int?
    public var seconds: TimeInterval

    public init(mode: Mode, ranked: [Entry], dimensions: Int? = nil, tokens: Int? = nil, seconds: TimeInterval) {
        self.mode = mode
        self.ranked = ranked
        self.dimensions = dimensions
        self.tokens = tokens
        self.seconds = seconds
    }

    /// "384 dimensions · 0.12 s · 12 tokens", leaving out what the server didn't report.
    public func summary(locale: Locale = .autoupdatingCurrent) -> String {
        [dimensions.map { "\($0.formatted(.number.locale(locale))) dimensions" },
         String(format: seconds < 10 ? "%.2f s" : "%.1f s", seconds),
         tokens.map { "\($0.formatted(.number.locale(locale))) tokens" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// A score as the server gave it, to four significant digits. Rerank scores can be negative or tiny, so never a percentage.
    public static func format(score: Double) -> String { String(format: "%.4g", score) }

    /// One text per line, as typed. Blank lines are ignored.
    public static func texts(from lines: String) -> [String] {
        lines.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The server's own words, and for a 404 one plain sentence on what it means.
    public static func failureMessage(for error: Error, mode: Mode) -> String {
        let message = error.localizedDescription
        guard case ChatClientError.http(404, _) = error else { return message }
        return message + "\n" + mode.noEndpoint
    }
}

extension ChatClient {
    /// Sends `inputs` in one request to `/embeddings`.
    public func embeddings(model: String, inputs: [String]) async throws -> EmbeddingResult {
        let data = try await post("embeddings", WireEmbeddingsRequest(model: model, input: inputs), purpose: .embedding)
        guard let reply = try? JSONDecoder().decode(WireEmbeddingsResponse.self, from: data) else {
            throw ChatClientError.invalidResponse
        }
        let ordered = try Self.inOrder(reply.data.map(\.index), reply.data, expecting: inputs.count, what: "vectors")
        let vectors = ordered.map(\.embedding)
        guard Set(vectors.map(\.count)).count <= 1 else {
            throw ChatClientError.unexpected("The server sent vectors of different lengths.")
        }
        return EmbeddingResult(vectors: vectors, promptTokens: reply.usage?.promptTokens ?? reply.usage?.totalTokens)
    }

    /// Asks `/rerank` to score each of `documents` against `query`.
    public func rerank(model: String, query: String, documents: [String]) async throws -> RerankResult {
        let data = try await post("rerank", WireRerankRequest(model: model, query: query, documents: documents), purpose: .rerank)
        guard let reply = try? JSONDecoder().decode(WireRerankResponse.self, from: data) else {
            throw ChatClientError.invalidResponse
        }
        _ = try Self.inOrder(reply.results.map(\.index), reply.results, expecting: documents.count, what: "scores")
        return RerankResult(scores: reply.results.map { RerankScore(index: $0.index, score: $0.score) },
                            promptTokens: reply.usage?.promptTokens ?? reply.usage?.totalTokens)
    }

    /// Ranks `texts` against `query`, by cosine similarity of their embeddings or by the rerank endpoint's scores.
    public func compare(_ mode: TextComparison.Mode, model: String, query: String, texts: [String]) async throws -> TextComparison {
        let start = ContinuousClock.now
        let scores: [Double]
        var dimensions: Int?
        let tokens: Int?
        switch mode {
        case .embeddings:
            let result = try await embeddings(model: model, inputs: [query] + texts)
            scores = result.vectors.dropFirst().map { Similarity.cosine(result.vectors[0], $0) }
            dimensions = result.dimensions
            tokens = result.promptTokens
        case .rerank:
            let result = try await rerank(model: model, query: query, documents: texts)
            scores = result.scores.sorted { $0.index < $1.index }.map(\.score)
            tokens = result.promptTokens
        }
        let elapsed = ContinuousClock.now - start
        let ranked = zip(texts, scores).enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .map { TextComparison.Entry(text: $0.element.0, score: $0.element.1) }
        return TextComparison(mode: mode, ranked: ranked, dimensions: dimensions, tokens: tokens,
                              seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    private func post(_ path: String, _ body: some Encodable, purpose: Exchange.Purpose) async throws -> Data {
        var request = URLRequest(url: config.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(body)
        let (data, http) = try await perform(request, purpose: purpose)
        guard (200..<300).contains(http.statusCode) else { throw Self.httpError(status: http.statusCode, body: data) }
        return data
    }

    /// `items` by their `indexes` (positions when the server gave none), which must be exactly 0..<count.
    private static func inOrder<T>(_ indexes: [Int?], _ items: [T], expecting count: Int, what: String) throws -> [T] {
        guard items.count == count else {
            throw ChatClientError.unexpected("The server sent \(items.count) \(what) for \(count) texts.")
        }
        let keyed = zip(indexes.enumerated().map { $1 ?? $0 }, items).sorted { $0.0 < $1.0 }
        guard keyed.map(\.0) == Array(0..<count) else {
            throw ChatClientError.unexpected("The server's \(what) don't match the texts sent.")
        }
        return keyed.map(\.1)
    }
}

private struct WireEmbeddingsRequest: Encodable {
    let model: String
    let input: [String]
}

private struct WireRerankRequest: Encodable {
    let model: String
    let query: String
    let documents: [String]
}

private struct WireTokenUsage: Decodable {
    let promptTokens: Int?
    let totalTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct WireEmbeddingsResponse: Decodable {
    struct Item: Decodable {
        let embedding: [Double]
        let index: Int?
    }

    let data: [Item]
    let usage: WireTokenUsage?
}

/// Jina and Cohere answer `results` with `relevance_score`. Some servers use `data` and `score`.
private struct WireRerankResponse: Decodable {
    struct Item: Decodable {
        let index: Int
        let score: Double

        private enum CodingKeys: String, CodingKey {
            case index
            case relevanceScore = "relevance_score"
            case score
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            index = try c.decode(Int.self, forKey: .index)
            score = try c.decodeIfPresent(Double.self, forKey: .relevanceScore) ?? c.decode(Double.self, forKey: .score)
        }
    }

    let results: [Item]
    let usage: WireTokenUsage?

    private enum CodingKeys: String, CodingKey { case results, data, usage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decodeIfPresent([Item].self, forKey: .results) ?? c.decode([Item].self, forKey: .data)
        usage = try c.decodeIfPresent(WireTokenUsage.self, forKey: .usage)
    }
}
