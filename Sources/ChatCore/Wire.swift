import Foundation

struct WireMessage: Codable, Equatable {
    let role: Role
    let content: String
}

struct WireChatRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let stream: Bool
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
