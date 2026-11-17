import ChatCore
import Foundation

/// The requests made for each reply, kept in memory for the inspector. Past `maxRequests` requests or `maxBytes`
/// of bodies, the oldest requests are dropped first. The newest request is always kept.
struct ExchangeLog {
    static let maxRequests = 40
    static let maxBytes = 24 * 1024 * 1024

    private var byMessage: [UUID: [Exchange]] = [:]
    /// Every kept request, oldest first, so the next one to drop is at the front.
    private var arrivals: [(message: UUID, exchange: UUID, bytes: Int)] = []
    private var bytes = 0
    private let maxRequests: Int
    private let maxBytes: Int

    init(maxRequests: Int = ExchangeLog.maxRequests, maxBytes: Int = ExchangeLog.maxBytes) {
        self.maxRequests = maxRequests
        self.maxBytes = maxBytes
    }

    var count: Int { arrivals.count }

    /// A message's requests in the order they started.
    func exchanges(for message: UUID) -> [Exchange] { byMessage[message] ?? [] }

    mutating func append(_ exchange: Exchange, to message: UUID) {
        var list = byMessage[message] ?? []
        list.insert(exchange, at: list.lastIndex { $0.startedAt <= exchange.startedAt }.map { $0 + 1 } ?? 0)
        byMessage[message] = list
        let size = exchange.requestBody.count + exchange.responseBody.utf8.count
        arrivals.append((message, exchange.id, size))
        bytes += size
        while arrivals.count > 1, arrivals.count > maxRequests || bytes > maxBytes {
            let oldest = arrivals.removeFirst()
            bytes -= oldest.bytes
            byMessage[oldest.message]?.removeAll { $0.id == oldest.exchange }
            if byMessage[oldest.message]?.isEmpty == true { byMessage[oldest.message] = nil }
        }
    }

    mutating func drop(_ messages: some Collection<UUID>) {
        let gone = Set(messages)
        guard !gone.isDisjoint(with: byMessage.keys) else { return }
        for message in gone { byMessage[message] = nil }
        arrivals.removeAll { gone.contains($0.message) }
        bytes = arrivals.reduce(0) { $0 + $1.bytes }
    }
}
