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

    let model: String
    let messages: [WireMessage]
    let stream: Bool
    let reasoningEffort: ReasoningEffort?
    /// nil rather than empty, since some servers reject an empty list.
    let tools: [Tool]?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools
        case reasoningEffort = "reasoning_effort"
    }
}

struct WireProbeRequest: Encodable {
    let model: String
    let messages = [WireMessage(role: .user, content: "hi")]
    let maxTokens = 1
    let stream = false
    let reasoningEffort: String

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
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

    let choices: [Choice]?
}

struct WireModelList: Decodable {
    /// SGLang's diffusion server says what each model generates, such as "t2i". Chat servers leave these out.
    struct Entry: Decodable {
        let id: String
        let taskType: String?
        let supportedTaskTypes: [String]?

        enum CodingKeys: String, CodingKey {
            case id
            case taskType = "task_type"
            case supportedTaskTypes = "supported_task_types"
        }
    }
    let data: [Entry]
}

struct WireImageRequest: Encodable {
    let model: String
    let prompt: String
    let n = 1
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

/// Accepts both `{"error":{"message":...}}` and `{"error":"..."}`.
struct WireErrorEnvelope: Decodable {
    let message: String

    private enum CodingKeys: String, CodingKey { case error }
    private enum DetailKeys: String, CodingKey { case message }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? root.decode(String.self, forKey: .error) {
            message = text
        } else {
            let detail = try root.nestedContainer(keyedBy: DetailKeys.self, forKey: .error)
            message = try detail.decodeIfPresent(String.self, forKey: .message) ?? "Unknown server error"
        }
    }
}
