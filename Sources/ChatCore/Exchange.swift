import Foundation

/// What a server reports about the tokens a request used.
public struct Usage: Equatable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    /// Part of `completionTokens`, when the server splits it out.
    public var reasoningTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
    }
}

/// One HTTP request the client made and what came back. The real API key is never stored: `Authorization`
/// reads `Bearer $API_KEY`.
public struct Exchange: Identifiable, Sendable, Equatable {
    public enum Purpose: String, Sendable {
        case chat, image, title, models, probe, resend, fetch, embedding, rerank
    }

    public struct Header: Equatable, Sendable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public struct Stats: Equatable, Sendable {
        /// From the start of the request to the first content, reasoning or tool call delta.
        public var timeToFirstToken: TimeInterval?
        public var totalTime: TimeInterval?
        /// Completion tokens over the time from the first token to the end.
        public var tokensPerSecond: Double?
    }

    /// The most response text kept. A longer response is cut and `responseTruncated` is set.
    public static let bodyLimit = 256 * 1024
    /// `error` of a request that was stopped.
    public static let cancelledMessage = "Cancelled"
    static let redactedAuthorization = "Bearer $API_KEY"
    static let redactedCookie = "<redacted>"

    public var id: UUID
    public var purpose: Purpose
    public var method: String
    public var url: URL
    public var requestHeaders: [Header]
    /// Exactly what was sent.
    public var requestBody: Data
    /// Nil when the request never got an answer.
    public var status: Int?
    public var responseHeaders: [Header]
    /// The text as received. A stream is its raw server-sent event lines.
    public var responseBody: String
    public var responseTruncated: Bool
    /// A transport or HTTP error message, or `cancelledMessage`.
    public var error: String?
    public var startedAt: Date
    /// When the response headers arrived. Only streamed requests record it.
    public var firstByteAt: Date?
    public var firstTokenAt: Date?
    public var finishedAt: Date?
    public var usage: Usage?

    public init(
        id: UUID = UUID(),
        purpose: Purpose,
        method: String = "POST",
        url: URL,
        requestHeaders: [Header] = [],
        requestBody: Data = Data(),
        status: Int? = nil,
        responseHeaders: [Header] = [],
        responseBody: String = "",
        responseTruncated: Bool = false,
        error: String? = nil,
        startedAt: Date = Date(),
        firstByteAt: Date? = nil,
        firstTokenAt: Date? = nil,
        finishedAt: Date? = nil,
        usage: Usage? = nil
    ) {
        self.id = id
        self.purpose = purpose
        self.method = method
        self.url = url
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.status = status
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.responseTruncated = responseTruncated
        self.error = error
        self.startedAt = startedAt
        self.firstByteAt = firstByteAt
        self.firstTokenAt = firstTokenAt
        self.finishedAt = finishedAt
        self.usage = usage
    }

    /// A request with nothing in its body, such as a GET, has nothing to edit and resend.
    public var isEditable: Bool { !requestBody.isEmpty }

    public func requestHeader(_ name: String) -> String? {
        requestHeaders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var stats: Stats {
        var rate: Double?
        if let tokens = usage?.completionTokens, let firstTokenAt, let finishedAt {
            let seconds = finishedAt.timeIntervalSince(firstTokenAt)
            if seconds > 0 { rate = Double(tokens) / seconds }
        }
        return Stats(
            timeToFirstToken: firstTokenAt.map { $0.timeIntervalSince(startedAt) },
            totalTime: finishedAt.map { $0.timeIntervalSince(startedAt) },
            tokensPerSecond: rate
        )
    }
}

extension Exchange {
    /// The request as it will be sent, with the key already swapped for `$API_KEY`.
    init(capturing request: URLRequest, purpose: Purpose, startedAt: Date) {
        let headers = (request.allHTTPHeaderFields ?? [:]).map { name, value in
            Header(name: name, value: name.caseInsensitiveCompare("Authorization") == .orderedSame
                   ? Self.redactedAuthorization : value)
        }
        self.init(purpose: purpose, method: request.httpMethod ?? "GET", url: request.url!,
                  requestHeaders: Self.sorted(headers), requestBody: request.httpBody ?? Data(), startedAt: startedAt)
    }

    mutating func receive(_ response: HTTPURLResponse) {
        status = response.statusCode
        responseHeaders = Self.sorted(response.allHeaderFields.map { field in
            let name = "\(field.key)"
            return Header(name: name, value: name.caseInsensitiveCompare("Set-Cookie") == .orderedSame ? Self.redactedCookie : "\(field.value)")
        })
    }

    mutating func store(_ body: BodyCapture) {
        responseTruncated = body.total > body.data.count
        responseBody = body.text
    }

    /// An HTTP failure is also an error, so a request that was answered with one reads as failed.
    mutating func finish(at date: Date) {
        finishedAt = date
        if error == nil, let status, !(200..<300).contains(status) {
            error = ChatClient.httpError(status: status, body: Data(responseBody.utf8)).errorDescription
        }
    }

    static func describe(_ error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return cancelledMessage }
        return error.localizedDescription
    }

    private static func sorted(_ headers: [Header]) -> [Header] {
        headers.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

/// The start of a response, up to `Exchange.bodyLimit`, and how long the whole response was.
struct BodyCapture {
    private(set) var data = Data()
    private(set) var total = 0

    init() {}

    init(whole data: Data) {
        self.data = data.prefix(Exchange.bodyLimit)
        total = data.count
    }

    mutating func append(_ byte: UInt8) {
        total += 1
        if data.count < Exchange.bodyLimit { data.append(byte) }
    }

    /// A cut can land inside a multi-byte character, so up to three bytes are given back to find a boundary.
    var text: String {
        var bytes = data
        for _ in 0...(total > data.count ? 3 : 0) {
            if let text = String(data: bytes, encoding: .utf8) { return text }
            bytes = bytes.dropLast()
        }
        return "<binary data, \(Self.sizeLabel(total))>"
    }

    static func sizeLabel(_ bytes: Int) -> String { "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB" }
}
