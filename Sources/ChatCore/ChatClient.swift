import Foundation

public struct ChatClient: Sendable {
    public let config: ServerConfig
    let session: URLSession

    public init(config: ServerConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func models() async throws -> [ServedModel] {
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatClientError.invalidResponse }
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
        let (bytes, fetched) = try await session.data(for: download)
        guard let status = (fetched as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw ChatClientError.invalidResponse
        }
        return bytes
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
                    // Only the user's photos go to the model. Pictures a model drew stay on screen.
                    WireMessage.expanding($0, images: $0.role == .user ? $0.images.compactMap { id in images?.data(for: id) } : [])
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
