import Foundation

public struct ChatClient: Sendable {
    public let config: ServerConfig
    let session: URLSession

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
        let ids = list.data.map(\.id)
        return (config.baseURL.host() == OpenAIModels.host ? ids.filter(OpenAIModels.isOffered) : ids).sorted()
    }

    public func stream(
        model: String,
        messages: [ChatMessage],
        reasoningEffort: ReasoningEffort? = nil,
        images: ImageStore? = nil,
        tools: [ToolSpec] = []
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let client = self

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Built here, off the caller's thread, because it reads and encodes every photo in the chat.
                    let request = try client.chatRequest(model: model, messages: messages,
                                                         reasoningEffort: reasoningEffort, images: images, tools: tools)
                    let (bytes, response) = try await client.session.bytes(for: request)
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
                            case .reasoning, .toolCall:
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

    /// A photo missing from `images` is left out rather than failing the whole request.
    func chatRequest(model: String, messages: [ChatMessage], reasoningEffort: ReasoningEffort? = nil,
                     images: ImageStore? = nil, tools: [ToolSpec] = []) throws -> URLRequest {
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
                messages: messages.flatMap {
                    WireMessage.expanding($0, images: $0.images.compactMap { id in images?.data(for: id) })
                },
                stream: true,
                reasoningEffort: reasoningEffort,
                tools: tools.isEmpty ? nil : tools.map {
                    .init(function: .init(name: $0.name, description: $0.description, parameters: $0.parameters))
                }
            )
        )
        return request
    }

    func authorize(_ request: inout URLRequest) {
        if let key = config.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    static func httpError(status: Int, body: Data) -> ChatClientError {
        if let envelope = try? JSONDecoder().decode(WireErrorEnvelope.self, from: body) {
            return .http(status: status, message: envelope.message)
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .http(status: status, message: String(text.prefix(300)))
    }
}
