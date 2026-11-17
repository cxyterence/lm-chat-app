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

    /// `includeUsage` asks for a final chunk with token counts, on chat completions only: a Responses stream always
    /// ends with them. A server that answers a request carrying it with a 400
    /// or a 422 (FastAPI's validation) is asked again without it, whatever the message says, since strict servers
    /// word the refusal in their own way. That shows as `.adapted(.usageNotRequested)` before the retried stream, and
    /// only when the retry gets through. A retry that fails too throws its own error, the one the request would have
    /// had without this feature. Pass false for a host that already refused.
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
                    var adaptation: Adaptation?
                    while true {
                        // Built here, off the caller's thread, because it reads and encodes every photo in the chat.
                        let request = switch client.config.api {
                        case .chatCompletions:
                            try client.chatRequest(model: model, messages: messages, reasoningEffort: reasoningEffort,
                                                   images: images, tools: tools, includeUsage: includeUsage)
                        case .responses:
                            try client.responsesRequest(model: model, messages: messages, reasoningEffort: reasoningEffort,
                                                        images: images, tools: tools)
                        }
                        do {
                            try await client.read(request, purpose: purpose) { event in
                                if let pending = adaptation {
                                    adaptation = nil
                                    continuation.yield(.adapted(pending))
                                }
                                continuation.yield(event)
                            }
                            break
                        } catch ChatClientError.http(let status, _)
                            where includeUsage && client.config.api == .chatCompletions && [400, 422].contains(status) {
                            includeUsage = false
                            adaptation = .usageNotRequested
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

    /// How long a stream that has finished is given to say anything more, such as its token counts, before it is
    /// taken as over. Servers that hold the connection open after the finish reason would otherwise hold the reply.
    static let finishGrace: Duration = .seconds(2)

    /// Reads a reply until `[DONE]`, the token counts that follow the finish reason, the end of the connection, or
    /// `finishGrace` after the finish reason, whichever comes first.
    private func read(_ request: URLRequest, purpose: Exchange.Purpose,
                      emit: (StreamEvent) -> Void) async throws {
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

            // The bytes pass through a stream so that the grace period can end the reading while it waits for one.
            let (relay, feed) = AsyncThrowingStream.makeStream(of: UInt8.self, throwing: Error.self)
            let pump = Task {
                do {
                    for try await byte in bytes { feed.yield(byte) }
                    feed.finish()
                } catch {
                    feed.finish(throwing: error)
                }
            }
            var grace: Task<Void, Never>?
            defer {
                pump.cancel()
                grace?.cancel()
            }

            let decodeLine = config.api == .responses ? ResponsesDecoder().decode(line:) : SSEDecoder().decode(line:)
            var splitter = ThinkTagSplitter()
            var lines = LineBuffer()
            var finished = false
            var ended = false

            func handle(_ line: String) throws {
                let events: [StreamEvent]
                do {
                    events = try decodeLine(line)
                } catch where finished {
                    return
                }
                for event in events {
                    switch event {
                    case .content(let text):
                        guard !finished else { continue }
                        exchange.firstTokenAt = exchange.firstTokenAt ?? Date()
                        splitter.push(text).forEach(emit)
                    case .reasoning, .toolCall:
                        guard !finished else { continue }
                        exchange.firstTokenAt = exchange.firstTokenAt ?? Date()
                        emit(event)
                    case .usage(let usage):
                        exchange.usage = usage
                        emit(event)
                        ended = ended || finished
                    case .done(let reason):
                        if !finished {
                            splitter.flush().forEach(emit)
                            emit(event)
                            finished = true
                            grace = Task {
                                try? await Task.sleep(for: Self.finishGrace)
                                feed.finish()
                            }
                        }
                        // A Responses stream puts its token counts before the finish, so nothing follows it.
                        ended = ended || reason == nil || config.api == .responses
                    case .adapted:
                        break
                    }
                }
            }

            for try await byte in relay {
                body.append(byte)
                guard let line = lines.push(byte) else { continue }
                try handle(line)
                if ended { break }
            }
            try Task.checkCancellation()
            if !ended, let line = lines.flush() { try handle(line) }
            if !finished {
                splitter.flush().forEach(emit)
                emit(.done(finishReason: nil))
            }
        }
    }

    /// A photo missing from `images` is left out rather than failing the whole request.
    func chatRequest(model: String, messages: [ChatMessage], reasoningEffort: ReasoningEffort? = nil,
                     images: ImageStore? = nil, tools: [ToolSpec] = [], includeUsage: Bool = true) throws -> URLRequest {
        try streamingRequest(path: "chat/completions", body:
            WireChatRequest(
                model: model,
                messages: Self.wireMessages(messages, images: images),
                stream: true,
                streamOptions: includeUsage ? .init() : nil,
                reasoningEffort: reasoningEffort,
                tools: tools.isEmpty ? nil : tools.map {
                    .init(function: .init(name: $0.name, description: $0.description, parameters: $0.parameters))
                }
            )
        )
    }

    func responsesRequest(model: String, messages: [ChatMessage], reasoningEffort: ReasoningEffort? = nil,
                          images: ImageStore? = nil, tools: [ToolSpec] = []) throws -> URLRequest {
        try streamingRequest(path: "responses", body:
            WireResponsesRequest(model: model, messages: Self.wireMessages(messages, images: images), stream: true,
                                 effort: reasoningEffort?.rawValue, tools: tools.map(WireResponsesTool.init))
        )
    }

    private static func wireMessages(_ messages: [ChatMessage], images: ImageStore?) -> [WireMessage] {
        messages.flatMap {
            // Only the user's photos go to the model. Pictures a model drew stay on screen.
            WireMessage.expanding($0, images: $0.role == .user ? $0.images.compactMap { id in images?.data(for: id) } : [])
        }
    }

    private func streamingRequest(path: String, body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: config.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        // Local models can spend minutes on prompt processing before the first token.
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(body)
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
