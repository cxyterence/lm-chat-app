import Foundation

/// A `/web-search` attached to the user message that asked for it. `results` is nil until the search runs,
/// so a failed search is retried with the reply.
public struct WebSearch: Codable, Equatable, Sendable {
    public struct Result: Codable, Equatable, Sendable {
        public var title: String
        public var link: URL
        public var snippet: String

        public init(title: String, link: URL, snippet: String) {
            self.title = title
            self.link = link
            self.snippet = snippet
        }
    }

    public var query: String
    public var results: [Result]?

    public init(query: String, results: [Result]? = nil) {
        self.query = query
        self.results = results
    }

    /// What the model is sent in place of the bare query.
    public var prompt: String {
        guard let results, !results.isEmpty else {
            return "A web search for \"\(query)\" found nothing. Say so, then answer from what you know: \(query)"
        }
        return """
            Answer using these web search results, retrieved \(Self.today). \(Self.citing) If the results don't \
            answer it, say so.

            \(Self.numbered(results))

            Question: \(query)
            """
    }

    private static let citing = "Cite sources inline as Markdown links numbered like the results, for example [1](https://example.com)."

    private static var today: String { Date().formatted(.iso8601.year().month().day()) }

    private static func numbered(_ results: [Result]) -> String {
        results.enumerated().map { index, result in
            "[\(index + 1)] \(result.title)\n\(result.link.absoluteString)\n\(result.snippet)"
        }.joined(separator: "\n\n")
    }
}

extension WebSearch {
    public static let toolName = "web_search"

    /// The tool as the model sees it. `query(in:)` reads what it sends back.
    public static let toolSpec = ToolSpec(
        name: toolName,
        description: """
            Searches Google and returns the top results, each with a title, address and snippet. Call it when the \
            answer depends on recent events, current facts, or anything you aren't sure of. Read a result's page \
            with fetch_url when the snippet isn't enough and that tool is offered.
            """,
        parameters: try! JSONDecoder().decode(JSONValue.self, from: Data("""
            {"type": "object",
             "properties": {
               "query": {"type": "string", "description": "What to search for, written as you would type it into Google."}
             },
             "required": ["query"]}
            """.utf8))
    )

    /// The non-blank `query` in a call's arguments.
    public static func query(in arguments: String) -> String? {
        let query = (try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)))?["query"]?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return query?.isEmpty == false ? query : nil
    }

    /// What the model reads back from `web_search`.
    public static func toolResult(_ results: [Result]) -> String {
        guard !results.isEmpty else { return "The search found nothing." }
        return "Results retrieved \(today). \(citing)\n\n\(numbered(results))"
    }
}

/// Google results through serper.dev.
public struct SerperClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://google.serper.dev")!

    let apiKey: String
    let baseURL: URL
    let session: URLSession

    public init(apiKey: String, baseURL: URL = SerperClient.defaultBaseURL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    /// The featured answer, when Google shows one, comes first.
    public func search(_ query: String, count: Int = 8) async throws -> [WebSearch.Result] {
        var request = URLRequest(url: baseURL.appendingPathComponent("search"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")
        request.httpBody = try JSONEncoder().encode(["q": query, "num": String(count)])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(SerperError.self, from: data))?.message
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw SearchError(status: http.statusCode, message: message)
        }
        guard let page = try? JSONDecoder().decode(SerperPage.self, from: data) else {
            throw ChatClientError.invalidResponse
        }
        let featured = page.answerBox.flatMap { box -> WebSearch.Result? in
            guard let text = box.answer ?? box.snippet, let link = box.link else { return nil }
            return WebSearch.Result(title: box.title ?? "Featured answer", link: link, snippet: text)
        }
        let organic = (page.organic ?? []).map { WebSearch.Result(title: $0.title, link: $0.link, snippet: $0.snippet ?? "") }
        return Array(([featured].compactMap { $0 } + organic).prefix(count))
    }
}

public struct SearchError: Error, Equatable, LocalizedError {
    public let status: Int
    public let message: String

    public var errorDescription: String? {
        switch status {
        case 401, 403: "Serper rejected the API key. Check it in Settings › Web Search."
        default: "Web search failed (HTTP \(status)): \(message)"
        }
    }
}

private struct SerperPage: Decodable {
    struct Organic: Decodable {
        let title: String
        let link: URL
        let snippet: String?
    }

    struct AnswerBox: Decodable {
        let title: String?
        let answer: String?
        let snippet: String?
        let link: URL?
    }

    let organic: [Organic]?
    let answerBox: AnswerBox?
}

private struct SerperError: Decodable { let message: String }
