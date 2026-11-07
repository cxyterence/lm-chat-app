import Foundation

public struct ChatClient: Sendable {
    public let config: ServerConfig
    private let session: URLSession

    public init(config: ServerConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func models() async throws -> [String] {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 15
        authorize(&request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.httpError(status: http.statusCode, body: data)
        }
        guard let list = try? JSONDecoder().decode(WireModelList.self, from: data) else {
            throw ChatClientError.invalidResponse
        }
        return list.data.map(\.id).sorted()
    }

    public func stream(
        model: String,
        messages: [ChatMessage],
        reasoningEffort: ReasoningEffort? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let request: URLRequest
        do {
            request = try chatRequest(model: model, messages: messages, reasoningEffort: reasoningEffort)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let session = session

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ChatClientError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 64 * 1024 { break }
                        }
                        throw Self.httpError(status: http.statusCode, body: body)
                    }

                    let decoder = SSEDecoder()
                    var splitter = ThinkTagSplitter()
                    var finished = false

                    lines: for try await line in bytes.lines {
                        for event in try decoder.decode(line: line) {
                            switch event {
                            case .content(let text):
                                splitter.push(text).forEach { continuation.yield($0) }
                            case .reasoning:
                                continuation.yield(event)
                            case .done:
                                splitter.flush().forEach { continuation.yield($0) }
                                continuation.yield(event)
                                finished = true
                                break lines
                            }
                        }
                    }
                    if !finished {
                        splitter.flush().forEach { continuation.yield($0) }
                        continuation.yield(.done(finishReason: nil))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func chatRequest(model: String, messages: [ChatMessage], reasoningEffort: ReasoningEffort? = nil) throws -> URLRequest {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        // Local models can spend minutes on prompt processing before the first token.
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(
            WireChatRequest(
                model: model,
                messages: messages.map { WireMessage(role: $0.role, content: $0.content) },
                stream: true,
                reasoningEffort: reasoningEffort
            )
        )
        return request
    }

    private func authorize(_ request: inout URLRequest) {
        if let key = config.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func httpError(status: Int, body: Data) -> ChatClientError {
        if let envelope = try? JSONDecoder().decode(WireErrorEnvelope.self, from: body) {
            return .http(status: status, message: envelope.message)
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .http(status: status, message: String(text.prefix(300)))
    }
}
