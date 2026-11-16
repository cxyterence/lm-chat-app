import Foundation

extension ChatClient {
    /// Where every request the client makes is sent and reported. A call site that goes through here can't
    /// forget to report, and a request that fails or is cancelled still reports what it had.
    func capture<T>(_ request: URLRequest, purpose: Exchange.Purpose,
                    _ work: (inout Exchange) async throws -> T) async -> (outcome: Result<T, Error>, exchange: Exchange) {
        var exchange = Exchange(capturing: request, purpose: purpose, startedAt: Date())
        let outcome: Result<T, Error>
        do {
            outcome = .success(try await work(&exchange))
        } catch {
            outcome = .failure(error)
            exchange.error = Exchange.describe(error)
        }
        exchange.finish(at: Date())
        record?(exchange)
        return (outcome, exchange)
    }

    func captured<T>(_ request: URLRequest, purpose: Exchange.Purpose,
                     _ work: (inout Exchange) async throws -> T) async throws -> T {
        try await capture(request, purpose: purpose, work).outcome.get()
    }

    /// A request answered in one piece. The status is the caller's to judge.
    func perform(_ request: URLRequest, purpose: Exchange.Purpose) async throws -> (Data, HTTPURLResponse) {
        try await captured(request, purpose: purpose) { exchange in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ChatClientError.invalidResponse }
            exchange.receive(http)
            exchange.store(BodyCapture(whole: data))
            return (data, http)
        }
    }

    /// Posts `rawBody` as is, for a request the user edited. The key goes only to the connection's own host.
    /// Whatever comes back, streamed or not, is read to the end as text. Failure is in the returned exchange's
    /// `error`, never thrown. Like every request, it is also passed to `record`.
    @discardableResult
    public func send(rawBody: Data, to url: URL, contentType: String) async -> Exchange {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if url.host() == config.baseURL.host() { authorize(&request) }
        request.httpBody = rawBody

        return await capture(request, purpose: .resend) { exchange in
            var body = BodyCapture()
            defer { exchange.store(body) }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ChatClientError.invalidResponse }
            exchange.receive(http)
            exchange.firstByteAt = Date()
            for try await byte in bytes { body.append(byte) }
        }.exchange
    }
}

/// Assembles bytes into lines on `\n`, so the raw text of a stream, blank separator lines included, is kept
/// as it arrived.
struct LineBuffer {
    private var bytes: [UInt8] = []

    mutating func push(_ byte: UInt8) -> String? {
        guard byte == 0x0A else {
            bytes.append(byte)
            return nil
        }
        return flush() ?? ""
    }

    mutating func flush() -> String? {
        guard !bytes.isEmpty else { return nil }
        defer { bytes.removeAll(keepingCapacity: true) }
        let line = bytes.last == 0x0D ? bytes.dropLast() : bytes[...]
        return String(decoding: line, as: UTF8.self)
    }
}
