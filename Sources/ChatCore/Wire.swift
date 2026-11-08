import Foundation

/// `content` is a plain string, or a list of image and text parts when the message carries images.
struct WireMessage: Encodable {
    let role: Role
    let content: String
    var images: [Data] = []

    private enum CodingKeys: String, CodingKey { case role, content }

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
        guard !images.isEmpty else { return try container.encode(content, forKey: .content) }
        var parts = images.map {
            Part(type: "image_url", imageURL: .init(url: "data:image/jpeg;base64," + $0.base64EncodedString()))
        }
        if !content.isEmpty { parts.append(Part(type: "text", text: content)) }
        try container.encode(parts, forKey: .content)
    }
}

struct WireChatRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let stream: Bool
    let reasoningEffort: ReasoningEffort?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
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
            let content: String?
            let reasoningContent: String?
            let reasoning: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
                case reasoning
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
    struct Entry: Decodable { let id: String }
    let data: [Entry]
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
