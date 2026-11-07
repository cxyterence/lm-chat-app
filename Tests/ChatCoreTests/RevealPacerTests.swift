import Testing
@testable import ChatCore

struct RevealPacerTests {
    private let frame = 1.0 / 60

    private func frames(_ pacer: inout RevealPacer, toward target: Int, count: Int) -> [Int] {
        (0..<count).map { _ in pacer.advance(toward: target, elapsed: frame) }
    }

    @Test func aBurstIsSpreadOverManyFrames() {
        var pacer = RevealPacer()
        let shown = frames(&pacer, toward: 400, count: 60)
        let steps = zip(shown, [0] + shown).map { $0 - $1 }
        #expect(steps.first! < 400 / 5, "first frame shows only a slice of the burst")
        #expect(steps.prefix(10).allSatisfy { $0 > 0 }, "text moves on every early frame")
        #expect(shown.last == 400, "burst fully shown within a second")
    }

    @Test func neverShowsMoreThanArrived() {
        var pacer = RevealPacer()
        #expect(frames(&pacer, toward: 7, count: 120).allSatisfy { $0 <= 7 })
        #expect(pacer.shown == 7)
    }

    @Test func slowTrickleStillMoves() {
        var pacer = RevealPacer()
        _ = pacer.advance(toward: 3, elapsed: frame)
        #expect(pacer.shown >= 1)
    }

    @Test func shrinkingTextSnapsBack() {
        var pacer = RevealPacer(shown: 50)
        #expect(pacer.advance(toward: 10, elapsed: frame) == 10)
    }

    @Test func historyStartsFullyShown() {
        var pacer = RevealPacer(shown: 120)
        #expect(pacer.advance(toward: 120, elapsed: frame) == 120)
    }
}
