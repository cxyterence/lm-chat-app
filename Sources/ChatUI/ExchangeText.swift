import ChatCore
import Foundation

/// The words the stats line, the inspector's rows and its summary use for a request.
enum ExchangeText {
    /// The request that wrote a reply: its newest chat request that got an answer, else its newest chat request.
    /// A resent or failed-then-retried request doesn't change what the reply cost.
    static func reply(in exchanges: [Exchange]) -> Exchange? {
        let chats = exchanges.filter { $0.purpose == .chat }
        return chats.last { $0.error == nil } ?? chats.last
    }

    /// "0.8 s to first token · 42 tok/s · 1,204 tokens", leaving out what the server didn't report.
    static func statsLine(_ exchange: Exchange, locale: Locale = .autoupdatingCurrent) -> String? {
        let stats = exchange.stats
        let pieces = [
            stats.timeToFirstToken.map { "\(duration($0)) to first token" },
            stats.tokensPerSecond.map { "\(rate($0, locale: locale)) tok/s" },
            exchange.usage?.completionTokens.map { "\(count($0, locale: locale)) tokens" },
        ].compactMap { $0 }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        String(format: seconds < 10 ? "%.1f s" : "%.0f s", seconds)
    }

    static func rate(_ tokensPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        tokensPerSecond.formatted(.number.precision(.fractionLength(tokensPerSecond < 10 ? 1 : 0)).locale(locale))
    }

    static func count(_ number: Int, locale: Locale = .autoupdatingCurrent) -> String {
        number.formatted(.number.locale(locale))
    }

    static func title(_ purpose: Exchange.Purpose) -> String {
        switch purpose {
        case .chat: "Chat request"
        case .image: "Image request"
        case .resend: "Resent request"
        case .title: "Title request"
        case .models: "Model list"
        case .probe: "Check request"
        case .fetch: "Page request"
        case .embedding: "Embeddings request"
        case .rerank: "Rerank request"
        }
    }

    static func statusName(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 408: "Request Timeout"
        case 413: "Payload Too Large"
        case 422: "Unprocessable Entity"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        }
    }

    /// How a request ended, in words.
    enum Outcome: Equatable {
        case succeeded(status: Int)
        /// The user stopped it.
        case stopped
        /// `message` is what the server or the network said, without the status that `headline` already gives.
        case failed(headline: String, message: String)
    }

    static func outcome(_ exchange: Exchange) -> Outcome {
        if exchange.error == Exchange.cancelledMessage { return .stopped }
        guard let error = exchange.error else { return .succeeded(status: exchange.status ?? 0) }
        guard let status = exchange.status else { return .failed(headline: "No response", message: error) }
        let prefix = "HTTP \(status): "
        return .failed(headline: "\(status) \(statusName(status))",
                       message: error.hasPrefix(prefix) ? String(error.dropFirst(prefix.count)) : error)
    }

    /// The first words of a server's message, on one line, for a note that has to stay short.
    static func shortened(_ text: String, limit: Int = 160) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}

/// The part of a long text that is drawn. A text within `limit` characters shows whole. A longer one shows its
/// start and its end, since a stream's finish reason and token counts come last, and says how much it left out.
struct TextPreview: Equatable {
    static let limit = 20_000

    let head: String
    let tail: String
    let omitted: Int

    init(_ text: String, limit: Int = TextPreview.limit) {
        guard text.utf8.count > limit, text.count > limit else {
            (head, tail, omitted) = (text, "", 0)
            return
        }
        // Cut on line breaks so no line is half shown, unless a line is the whole text.
        var start = String(text.prefix(limit * 3 / 4))
        if let newline = start.lastIndex(of: "\n"), newline > start.startIndex { start = String(start[...newline]) }
        var end = String(text.suffix(limit / 4))
        if let newline = end.firstIndex(of: "\n"), end.index(after: newline) < end.endIndex { end = String(end[end.index(after: newline)...]) }
        (head, tail, omitted) = (start, end, text.count - start.count - end.count)
    }
}
