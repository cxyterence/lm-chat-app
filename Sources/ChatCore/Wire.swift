import Foundation

/// `content` is a plain string, or a list of image and text parts when the message carries images.
struct WireMessage: Encodable {
    let role: String
    let content: String
    var images: [Data] = []
    var toolCalls: [ToolCall] = []
    var toolCallID: String?

    init(role: Role, content: String, images: [Data] = []) {
        self.role = role.rawValue
        self.content = content
        self.images = images
    }

    private init(role: String, content: String, toolCalls: [ToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    /// An assistant turn that called tools becomes that turn followed by one `tool` message per result.
    /// A call that never finished still gets a result, since the wire requires one per call.
    static func expanding(_ message: ChatMessage, images: [Data]) -> [WireMessage] {
        guard message.role == .assistant, !message.toolCalls.isEmpty else {
            return [WireMessage(role: message.role, content: message.search?.prompt ?? message.content, images: images)]
        }
        return [WireMessage(role: "assistant", content: message.content, toolCalls: message.toolCalls)]
            + message.toolCalls.map {
                WireMessage(role: "tool", content: $0.result?.text ?? "The tool call was cancelled.", toolCallID: $0.id)
            }
    }

    private enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    private struct Call: Encodable {
        struct Function: Encodable { let name, arguments: String }
        let id: String
        let type = "function"
        let function: Function
    }

    private struct Part: Encodable {
        struct ImageURL: Encodable { let url: String }
        let type: String
        var text: String?
        var imageURL: ImageURL?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        if !toolCalls.isEmpty {
            try container.encode(toolCalls.map { Call(id: $0.id, function: .init(name: $0.name, arguments: $0.arguments)) },
                                 forKey: .toolCalls)
            return content.isEmpty ? try container.encodeNil(forKey: .content) : try container.encode(content, forKey: .content)
        }
        guard !images.isEmpty else { return try container.encode(content, forKey: .content) }
        var parts = images.map {
            Part(type: "image_url", imageURL: .init(url: "data:image/jpeg;base64," + $0.base64EncodedString()))
        }
        if !content.isEmpty { parts.append(Part(type: "text", text: content)) }
        try container.encode(parts, forKey: .content)
    }
}

struct WireChatRequest: Encodable {
    struct Tool: Encodable {
        struct Function: Encodable {
            let name, description: String
            let parameters: JSONValue
        }
        let type = "function"
        let function: Function
    }

    struct StreamOptions: Encodable {
        let includeUsage = true

        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    let model: String
    let messages: [WireMessage]
    let stream: Bool
    /// Asks for a final chunk that reports token counts. nil for servers that refuse the field.
    let streamOptions: StreamOptions?
    let reasoningEffort: ReasoningEffort?
    /// nil rather than empty, since some servers reject an empty list.
    let tools: [Tool]?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools
        case streamOptions = "stream_options"
        case reasoningEffort = "reasoning_effort"
    }
}

/// A one-token request that asks a model about a single feature.
struct WireProbeRequest: Encodable {
    let model: String
    var messages = [WireMessage(role: .user, content: "hi")]
    let maxTokens = 1
    let stream = false
    var reasoningEffort: String?
    var tools: [WireChatRequest.Tool]?

    init(model: String, messages: [WireMessage]? = nil, reasoningEffort: String? = nil, tools: [WireChatRequest.Tool]? = nil) {
        self.model = model
        if let messages { self.messages = messages }
        self.reasoningEffort = reasoningEffort
        self.tools = tools
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools
        // OpenAI's reasoning models reject max_tokens. vLLM accepts either.
        case maxTokens = "max_completion_tokens"
        case reasoningEffort = "reasoning_effort"
    }
}

struct WireChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct Call: Decodable {
                struct Function: Decodable { let name, arguments: String? }
                let index: Int?
                let id: String?
                let function: Function?
            }

            let content: String?
            let reasoningContent: String?
            let reasoning: String?
            let toolCalls: [Call]?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
                case reasoning
                case toolCalls = "tool_calls"
            }
        }

        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        struct Details: Decodable {
            let reasoningTokens: Int?

            enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
        }

        let promptTokens: Int?
        let completionTokens: Int?
        let completionTokensDetails: Details?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case completionTokensDetails = "completion_tokens_details"
        }
    }

    let choices: [Choice]?
    /// Null on every chunk but the last when the request asked for it.
    let usage: Usage?

    private enum CodingKeys: String, CodingKey { case choices, usage }

    /// A usage block a server words in its own way costs the counts, never the reply.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        choices = try container.decodeIfPresent([Choice].self, forKey: .choices)
        usage = try? container.decodeIfPresent(Usage.self, forKey: .usage)
    }
}

struct WireModelList: Decodable {
    /// SGLang's diffusion server says what each model generates, such as "t2i". Chat servers leave these out.
    /// `fields` is the whole entry, for what servers add beyond the id, such as vLLM's `max_model_len`.
    struct Entry: Decodable {
        let id: String
        let taskType: String?
        let supportedTaskTypes: [String]?
        let fields: [String: JSONValue]

        init(from decoder: Decoder) throws {
            fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
            guard let id = fields["id"]?.string else {
                throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: decoder.codingPath, debugDescription: "no id"))
            }
            self.id = id
            taskType = fields["task_type"]?.string
            supportedTaskTypes = fields["supported_task_types"]?.strings
        }

        private enum CodingKeys: String, CodingKey { case id }
    }
    let data: [Entry]
}

struct WireImageRequest: Encodable {
    let model: String
    let prompt: String
    let size: String?
    let n = 1
}

struct MultipartForm {
    let boundary = "chat-\(UUID().uuidString)"
    private(set) var body = Data()

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func jpeg(_ name: String, filename: String, _ data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    var closed: Data { body + Data("--\(boundary)--\r\n".utf8) }
}

/// Each image arrives inline as base64 or as a link to fetch, depending on the server and model.
struct WireImageResponse: Decodable {
    struct Image: Decodable {
        let base64: String?
        let url: String?

        enum CodingKeys: String, CodingKey {
            case base64 = "b64_json"
            case url
        }
    }
    let data: [Image]
}

/// Accepts `{"error":{"message":...}}`, `{"error":"..."}` and FastAPI's `{"detail":"..."}`.
struct WireErrorEnvelope: Decodable {
    let message: String

    private enum CodingKeys: String, CodingKey { case error, detail }
    private enum DetailKeys: String, CodingKey { case message }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        if let text = (try? root.decode(String.self, forKey: .error)) ?? (try? root.decode(String.self, forKey: .detail)) {
            message = text
        } else {
            let detail = try root.nestedContainer(keyedBy: DetailKeys.self, forKey: .error)
            message = try detail.decodeIfPresent(String.self, forKey: .message) ?? "Unknown server error"
        }
    }
}
