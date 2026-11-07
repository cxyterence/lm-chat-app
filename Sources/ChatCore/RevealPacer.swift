/// Turns bursty streamed text into a steady reveal. Each frame shows a share of the backlog, so a burst
/// eases out over `catchUp` seconds instead of landing at once, and a slow stream still moves at `minRate`.
public struct RevealPacer: Sendable {
    public private(set) var shown: Int
    let minRate: Double
    let catchUp: Double

    public init(shown: Int = 0, minRate: Double = 150, catchUp: Double = 0.25) {
        self.shown = shown
        self.minRate = minRate
        self.catchUp = catchUp
    }

    /// Advances toward `target` characters after `elapsed` seconds and returns the new count.
    public mutating func advance(toward target: Int, elapsed: Double) -> Int {
        guard target > shown else {
            shown = target
            return shown
        }
        let backlog = Double(target - shown)
        let rate = max(minRate, backlog / catchUp)
        shown = min(target, shown + max(1, Int(rate * elapsed)))
        return shown
    }
}
