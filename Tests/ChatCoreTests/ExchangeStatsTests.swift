import Foundation
import Testing
@testable import ChatCore

struct ExchangeStatsTests {
    private func exchange(firstToken: Double? = 100.5, finished: Double? = 102.5, completionTokens: Int? = 84) -> Exchange {
        Exchange(purpose: .chat, url: URL(string: "http://h/v1/chat/completions")!, startedAt: date(100),
                 firstTokenAt: firstToken.map(date), finishedAt: finished.map(date),
                 usage: completionTokens.map { Usage(promptTokens: 10, completionTokens: $0) })
    }

    @Test func timesAndSpeedFromWholeData() {
        #expect(exchange().stats == Exchange.Stats(timeToFirstToken: 0.5, totalTime: 2.5, tokensPerSecond: 42))
    }

    @Test func speedCountsTokensOverTheTimeFromTheFirstTokenToTheEnd() {
        #expect(exchange(firstToken: 101.5, finished: 102.5, completionTokens: 30).stats.tokensPerSecond == 30)
    }

    @Test func withoutAFirstTokenThereIsNoFirstTokenTimeAndNoSpeed() {
        let stats = exchange(firstToken: nil).stats
        #expect(stats == Exchange.Stats(timeToFirstToken: nil, totalTime: 2.5, tokensPerSecond: nil))
    }

    @Test func withoutAnEndThereIsNoTotalAndNoSpeed() {
        let stats = exchange(finished: nil).stats
        #expect(stats == Exchange.Stats(timeToFirstToken: 0.5, totalTime: nil, tokensPerSecond: nil))
    }

    @Test func withoutTokenCountsThereIsNoSpeed() {
        #expect(exchange(completionTokens: nil).stats == Exchange.Stats(timeToFirstToken: 0.5, totalTime: 2.5, tokensPerSecond: nil))
        var promptOnly = exchange()
        promptOnly.usage = Usage(promptTokens: 10)
        #expect(promptOnly.stats.tokensPerSecond == nil)
    }

    @Test func aReplyThatEndedWithItsFirstTokenHasNoSpeed() {
        #expect(exchange(firstToken: 102.5, finished: 102.5).stats.tokensPerSecond == nil)
    }

    @Test func aRequestThatNeverStartedStreamingHasNothingButItsTotal() {
        let stats = Exchange(purpose: .models, url: URL(string: "http://h/v1/models")!, startedAt: date(100), finishedAt: date(100.25)).stats
        #expect(stats == Exchange.Stats(timeToFirstToken: nil, totalTime: 0.25, tokensPerSecond: nil))
    }
}
