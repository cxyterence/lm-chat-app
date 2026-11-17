import ChatCore
import Foundation
import Testing
@testable import ChatUI

struct ExchangeTextTests {
    private let english = Locale(identifier: "en_US")
    private let start = Date(timeIntervalSince1970: 1_000)

    private func chat(first: TimeInterval? = 0.8, finish: TimeInterval? = 29.5, tokens: Int? = 1204,
                      purpose: Exchange.Purpose = .chat, status: Int? = 200, error: String? = nil) -> Exchange {
        Exchange(purpose: purpose, url: URL(string: "http://x/v1/chat/completions")!, status: status, error: error,
                 startedAt: start, firstTokenAt: first.map { start + $0 }, finishedAt: finish.map { start + $0 },
                 usage: tokens.map { Usage(completionTokens: $0) })
    }

    @Test func theStatsLineSaysWhatTheServerReported() {
        #expect(ExchangeText.statsLine(chat(), locale: english) == "0.8 s to first token · 42 tok/s · 1,204 tokens")
    }

    @Test func piecesTheServerDidntReportAreLeftOut() {
        #expect(ExchangeText.statsLine(chat(tokens: nil), locale: english) == "0.8 s to first token")
        #expect(ExchangeText.statsLine(chat(first: nil), locale: english) == "1,204 tokens")
        #expect(ExchangeText.statsLine(chat(first: nil, finish: nil, tokens: nil), locale: english) == nil)
    }

    @Test func slowAndFastNumbersAreRoundedToReadAtAGlance() {
        #expect(ExchangeText.duration(0.84) == "0.8 s")
        #expect(ExchangeText.duration(12.4) == "12 s")
        #expect(ExchangeText.rate(8.26, locale: english) == "8.3")
        #expect(ExchangeText.rate(118.4, locale: english) == "118")
    }

    @Test func aRepliesCostComesFromItsNewestChatRequestThatWorked() {
        let refused = chat(status: 400, error: "HTTP 400: no tools")
        let worked = chat(tokens: 9)
        let resent = chat(tokens: 1, purpose: .resend)
        #expect(ExchangeText.reply(in: [refused, worked, resent])?.id == worked.id)
        #expect(ExchangeText.reply(in: [refused])?.id == refused.id, "with nothing better, the failed one")
        #expect(ExchangeText.reply(in: [resent]) == nil)
    }

    @Test func aRequestEndedInOneOfThreeWays() {
        #expect(ExchangeText.outcome(chat()) == .succeeded(status: 200))
        #expect(ExchangeText.outcome(chat(error: Exchange.cancelledMessage)) == .stopped)
        #expect(ExchangeText.outcome(chat(status: 400, error: "HTTP 400: this model does not support tools"))
                == .failed(headline: "400 Bad Request", message: "this model does not support tools"))
        #expect(ExchangeText.outcome(chat(status: nil, error: "The network connection was lost."))
                == .failed(headline: "No response", message: "The network connection was lost."))
    }

    @Test func aLongMessageIsShortenedOnOneLine() {
        #expect(ExchangeText.shortened("  two\n\nlines   here ") == "two lines here")
        let long = String(repeating: "word ", count: 100)
        let short = ExchangeText.shortened(long)
        #expect(short.count <= 161 && short.hasSuffix("…") && !short.contains("\n"))
    }
}

struct TextPreviewTests {
    @Test func aShortTextShowsWhole() {
        let preview = TextPreview("a\nb", limit: 10)
        #expect(preview.head == "a\nb" && preview.tail.isEmpty && preview.omitted == 0)
    }

    @Test func aLongTextShowsItsStartAndItsEndAndCountsWhatItLeftOut() {
        let lines = (1...1000).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        let preview = TextPreview(text, limit: 400)
        #expect(preview.head.hasPrefix("line 1\n") && preview.head.hasSuffix("\n"))
        #expect(preview.tail.hasSuffix("line 1000"), "a stream's finish reason and token counts come last")
        #expect(preview.head.count + preview.tail.count + preview.omitted == text.count)
        #expect(preview.head.count + preview.tail.count <= 400)
        #expect(preview.omitted > 0)
        #expect(!preview.tail.hasPrefix("ine"), "no line is half shown")
    }

    @Test func oneHugeLineIsStillCut() {
        let preview = TextPreview(String(repeating: "x", count: 5_000), limit: 400)
        #expect(preview.head.count + preview.tail.count == 400 && preview.omitted == 4_600)
    }
}

struct ExchangeLogTests {
    private func exchange(bytes: Int = 10, at seconds: TimeInterval = 0) -> Exchange {
        Exchange(purpose: .chat, url: URL(string: "http://x/v1")!, requestBody: Data(count: bytes),
                 startedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func keepsTheNewest40RequestsAcrossReplies() {
        var log = ExchangeLog()
        let replies = (0..<45).map { _ in UUID() }
        for (index, reply) in replies.enumerated() { log.append(exchange(at: Double(index)), to: reply) }
        #expect(log.count == 40)
        #expect(replies.prefix(5).allSatisfy { log.exchanges(for: $0).isEmpty })
        #expect(replies.dropFirst(5).allSatisfy { log.exchanges(for: $0).count == 1 })
    }

    @Test func dropsTheOldestFirstOncePast24MegabytesOfBodies() {
        var log = ExchangeLog()
        let (a, b, c) = (UUID(), UUID(), UUID())
        let ten = 10 * 1024 * 1024
        log.append(exchange(bytes: ten, at: 1), to: a)
        log.append(exchange(bytes: ten, at: 2), to: b)
        #expect(log.count == 2, "20 MB fits")
        log.append(exchange(bytes: ten, at: 3), to: c)
        #expect(log.exchanges(for: a).isEmpty && log.count == 2)
        #expect(log.exchanges(for: b).count == 1 && log.exchanges(for: c).count == 1)
    }

    @Test func responseTextCountsTowardTheLimitToo() {
        var log = ExchangeLog(maxRequests: 40, maxBytes: 100)
        let (a, b) = (UUID(), UUID())
        var big = exchange(bytes: 10, at: 1)
        big.responseBody = String(repeating: "é", count: 40)
        log.append(big, to: a)
        log.append(exchange(bytes: 30, at: 2), to: b)
        #expect(log.exchanges(for: a).isEmpty, "10 + 80 + 30 is over 100")
    }

    @Test func theNewestRequestStaysEvenWhenItAloneIsOverTheLimit() {
        var log = ExchangeLog(maxRequests: 40, maxBytes: 100)
        let reply = UUID()
        log.append(exchange(bytes: 500), to: reply)
        #expect(log.exchanges(for: reply).count == 1)
    }

    @Test func aRepliesRequestsAreInTheOrderTheyStarted() {
        var log = ExchangeLog()
        let reply = UUID()
        let late = exchange(at: 5), early = exchange(at: 1), middle = exchange(at: 3)
        for item in [late, early, middle] { log.append(item, to: reply) }
        #expect(log.exchanges(for: reply).map(\.id) == [early.id, middle.id, late.id])
    }

    @Test func droppingARepliesRequestsFreesTheirBytes() {
        var log = ExchangeLog(maxRequests: 40, maxBytes: 100)
        let (a, b, c) = (UUID(), UUID(), UUID())
        log.append(exchange(bytes: 60, at: 1), to: a)
        log.drop([a])
        log.append(exchange(bytes: 60, at: 2), to: b)
        log.append(exchange(bytes: 30, at: 3), to: c)
        #expect(log.exchanges(for: b).count == 1 && log.exchanges(for: c).count == 1, "a's 60 bytes no longer count")
        #expect(log.count == 2)
    }
}
