import Foundation

public struct ChatClient: Sendable {
    public let config: ServerConfig
    let session: URLSession
    /// Told about every request the client makes, once, when it finishes, fails or is cancelled.
    let record: (@Sendable (Exchange) -> Void)?

    public init(config: ServerConfig, session: URLSession = .shared, record: (@Sendable (Exchange) -> Void)? = nil) {
        self.config = config
        self.session = session
        self.record = record
    }

    public func models() async throws -> [ServedModel] {
        let list = try await modelList()
        let models = if config.baseURL.host() == OpenAIModels.host {
            list.data.filter { OpenAIModels.isOffered($0.id) }
                .map { ServedModel(id: $0.id, makesImages: OpenAIModels.makesImages($0.id)) }
        } else {
            list.data.map { entry in
                let tasks = (entry.supportedTaskTypes ?? []) + [entry.taskType].compactMap { $0 }
                return ServedModel(id: entry.id, makesImages: tasks.contains { $0.lowercased().hasSuffix("2i") })
            }
        }
        return models.sorted { $0.id < $1.id }
    }

    func modelList() async throws -> WireModelList {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 15
        authorize(&request)

        let (data, http) = try await perform(request, purpose: .models)
        guard (200..<300).contains(http.statusCode) else {
            throw Self.httpError(status: http.statusCode, body: data)
        }
        guard let list = try? JSONDecoder().decode(WireModelList.self, from: data) else {
            throw ChatClientError.invalidResponse
        }
        return list
    }

    /// Asks an image model for one picture and returns its bytes as the server encoded them.
    /// With `sources` (JPEGs) the model edits them, otherwise it draws from the prompt alone.
    public func image(model: String, prompt: String, sources: [Data] = [], size: String? = nil) async throws -> Data {
        var request = URLRequest(url: config.baseURL.appendingPathComponent(sources.isEmpty ? "images/generations" : "images/edits"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        authorize(&request)
        if sources.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(WireImageRequest(model: model, prompt: prompt, size: size))
        } else {
            var form = MultipartForm()
            form.field("model", model)
            form.field("prompt", prompt)
            form.field("n", "1")
            if let size { form.field("size", size) }
            for (index, source) in sources.enumerated() {
                form.jpeg(sources.count == 1 ? "image" : "image[]", filename: "image\(index + 1).jpg", source)
            }
            request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = form.closed
        }

        let (data, http) = try await perform(request, purpose: .image)
        guard (200..<300).contains(http.statusCode) else { throw Self.httpError(status: http.statusCode, body: data) }
        guard let image = (try? JSONDecoder().decode(WireImageResponse.self, from: data))?.data.first else {
            throw ChatClientError.invalidResponse
        }
        if let bytes = image.base64.flatMap({ Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }) { return bytes }
        // SGLang links to its own /v1/images/<id>/content with a path and no host.
        guard let url = image.url.flatMap({ URL(string: $0, relativeTo: config.baseURL)?.absoluteURL }) else {
            throw ChatClientError.invalidResponse
        }
        var download = URLRequest(url: url)
        if url.host() == config.baseURL.host() { authorize(&download) }
        let (bytes, fetched) = try await perform(download, purpose: .image)
        guard (200..<300).contains(fetched.statusCode) else { throw ChatClientError.invalidResponse }
        return bytes
    }

    /// `includeUsage` asks for a final chunk with token counts. A server that refuses the field with a 400, or a
    /// 422 as FastAPI validation gives, is asked again without it. That shows as `.adapted(.usageNotRequested)`
    /// before the retried stream. Pass false for a host that already refused.
    public func stream(
        model: String,
        messages: [ChatMessage],
        reasoningEffort: ReasoningEffort? = nil,
        images: ImageStore? = nil,
        tools: [ToolSpec] = [],
        includeUsage: Bool = true,
        purpose: Exchange.Purpose = .chat
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let client = self

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var includeUsage = includeUsage
                    while true {
                        // Built here, off the caller's thread, because it reads and encodes every photo in the chat.
                        let request = try client.chatRequest(model: model, messages: messages, reasoningEffort: reasoningEffort,
                                                             images: images, tools: tools, includeUsage: includeUsage)
                        do {
                            try await client.read(request, purpose: purpose, into: continuation)
                            break
                        } catch ChatClientError.http(let status, let message)
                            where includeUsage && [400, 422].contains(status) && Self.namesStreamOptions(message) {
                            includeUsage = false
                            continuation.yield(.adapted(.usageNotRequested))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func namesStreamOptions(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("stream_options") || text.contains("stream options")
    }

    /// Reads to the end of the stream, `[DONE]` included, since token counts follow the finish reason.
    private func read(_ request: URLRequest, purpose: Exchange.Purpose,
                      into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        try await captured(request, purpose: purpose) { exchange in
            var body = BodyCapture()
            defer { exchange.store(body) }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ChatClientError.invalidResponse }
            exchange.receive(http)
            exchange.firstByteAt = Date()
            guard (200..<300).contains(http.statusCode) else {
                var failure = Data()
                for try await byte in bytes {
                    body.append(byte)
                    failure.append(byte)
                    if failure.count >= 64 * 1024 { break }
                }
                throw Self.httpError(status: http.statusCode, body: failure)
            }

            let decoder = SSEDecoder()
            var splitter = ThinkTagSplitter()
            var lines = LineBuffer()
            var finished = false
            var ended = false

            func handle(_ line: String) throws {
                for event in try decoder.decode(line: line) {
                    switch event {
                    case .content(let text):
                        guard !finished else { continue }
                        exchange.firstTokenAt = exchange.firstTokenAt ?? Date()
                        splitter.push(text).forEach { continuation.yield($0) }
                    case .reasoning, .toolCall:
                        guard !finished else { continue }
                        exchange.firstTokenAt = exchange.firstTokenAt ?? Date()
                        continuation.yield(event)
                    case .usage(let usage):
                        exchange.usage = usage
                        continuation.yield(event)
                    case .done(let reason):
                        if !finished {
                            splitter.flush().forEach { continuation.yield($0) }
                            continuation.yield(event)
                            finished = true
                        }
                        ended = reason == nil
                    case .adapted:
                        break
                    }
                }
            }

            for try await byte in bytes {
                body.append(byte)
                guard let line = lines.push(byte) else { continue }
                try handle(line)
                if ended { break }
            }
            if !ended, let line = lines.flush() { try handle(line) }
            if !finished {
                splitter.flush().forEach { continuation.yield($0) }
                continuation.yield(.done(finishReason: nil))
            }
        }
    }

    /// A photo missing from `images` is left out rather than failing the whole request.
    func chatRequest(model: String, messages: [ChatMessage], reasoningEffort: ReasoningEffort? = nil,
                     images: ImageStore? = nil, tools: [ToolSpec] = [], includeUsage: Bool = true) throws -> URLRequest {
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
                    // Only the user's photos go to the model. Pictures a model drew stay on screen.
                    WireMessage.expanding($0, images: $0.role == .user ? $0.images.compactMap { id in images?.data(for: id) } : [])
                },
                stream: true,
                streamOptions: includeUsage ? .init() : nil,
                reasoningEffort: reasoningEffort,
                tools: tools.isEmpty ? nil : tools.map {
                    .init(function: .init(name: $0.name, description: $0.description, parameters: $0.parameters))
                }
            )
        )
        return request
    }

    /// The size to ask for. SGLang edits fail without one, so it defaults to the source's own. OpenAI's gpt-image
    /// models take only a few fixed sizes, so there it is sent only when the request names a shape or size.
    public func imageSize(for request: ImageRequest, source: Data?) -> String? {
        if config.baseURL.host() == OpenAIModels.host && request.aspect == nil && request.longEdge == nil { return nil }
        return request.size(source: source.flatMap(ImageAttachment.dimensions))
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
