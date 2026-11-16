import Foundation

/// One entry of a Responses request's `input`: a message, or half of a tool round.
enum WireResponsesItem: Encodable {
    struct Part: Encodable {
        let type: String
        var text: String?
        var detail: String?
        var imageURL: String?

        enum CodingKeys: String, CodingKey {
            case type, text, detail
            case imageURL = "image_url"
        }
    }

    case message(role: String, content: String)
    case parts(role: String, [Part])
    case functionCall(id: String, name: String, arguments: String)
    case functionCallOutput(id: String, output: String)

    private enum CodingKeys: String, CodingKey {
        case type, role, content, name, arguments, output
        case callID = "call_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let role, let content):
            try c.encode(role, forKey: .role)
            try c.encode(content, forKey: .content)
        case .parts(let role, let parts):
            try c.encode(role, forKey: .role)
            try c.encode(parts, forKey: .content)
        case .functionCall(let id, let name, let arguments):
            try c.encode("function_call", forKey: .type)
            try c.encode(id, forKey: .callID)
            try c.encode(name, forKey: .name)
            try c.encode(arguments, forKey: .arguments)
        case .functionCallOutput(let id, let output):
            try c.encode("function_call_output", forKey: .type)
            try c.encode(id, forKey: .callID)
            try c.encode(output, forKey: .output)
        }
    }

    /// The same turns `WireMessage` would send to chat completions, in this API's shape.
    static func items(for message: WireMessage) -> [WireResponsesItem] {
        if message.role == "tool" {
            return [.functionCallOutput(id: message.toolCallID ?? "", output: message.content)]
        }
        if !message.toolCalls.isEmpty {
            return (message.content.isEmpty ? [] : [.message(role: message.role, content: message.content)])
                + message.toolCalls.map { .functionCall(id: $0.id, name: $0.name, arguments: $0.arguments) }
        }
        guard !message.images.isEmpty else { return [.message(role: message.role, content: message.content)] }
        // vLLM answers 400 to an image part without `detail`.
        var parts = message.images.map {
            Part(type: "input_image", detail: "auto", imageURL: "data:image/jpeg;base64," + $0.base64EncodedString())
        }
        if !message.content.isEmpty { parts.append(Part(type: "input_text", text: message.content)) }
        return [.parts(role: message.role, parts)]
    }
}

struct WireResponsesTool: Encodable {
    let type = "function"
    let name, description: String
    let parameters: JSONValue

    init(_ tool: WireChatRequest.Tool) {
        name = tool.function.name
        description = tool.function.description
        parameters = tool.function.parameters
    }

    init(_ spec: ToolSpec) {
        name = spec.name
        description = spec.description
        parameters = spec.parameters
    }
}

struct WireResponsesRequest: Encodable {
    struct Reasoning: Encodable { let effort: String }

    let model: String
    let input: [WireResponsesItem]
    let stream: Bool
    /// OpenAI keeps responses unless told not to, and this app keeps its chats itself.
    let store = false
    let reasoning: Reasoning?
    /// nil rather than empty, since some servers reject an empty list.
    let tools: [WireResponsesTool]?
    /// Only the probes set it. OpenAI takes no fewer than 16.
    var maxOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, input, stream, store, reasoning, tools
        case maxOutputTokens = "max_output_tokens"
    }

    init(model: String, messages: [WireMessage], stream: Bool, effort: String?, tools: [WireResponsesTool]) {
        self.model = model
        input = messages.flatMap(WireResponsesItem.items(for:))
        self.stream = stream
        reasoning = effort.map(Reasoning.init)
        self.tools = tools.isEmpty ? nil : tools
    }
}

struct WireResponsesEvent: Decodable {
    struct Item: Decodable {
        let type: String?
        let callID: String?
        let name: String?

        enum CodingKeys: String, CodingKey {
            case type, name
            case callID = "call_id"
        }
    }

    struct Failure: Decodable { let message: String? }

    struct Response: Decodable {
        struct Usage: Decodable {
            struct Details: Decodable {
                let reasoningTokens: Int?

                enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
            }

            let inputTokens: Int?
            let outputTokens: Int?
            let outputTokensDetails: Details?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case outputTokensDetails = "output_tokens_details"
            }
        }

        let output: [Item]?
        let usage: Usage?
        let error: Failure?

        private enum CodingKeys: String, CodingKey { case output, usage, error }

        /// Counts a server words in its own way cost the counts, never the reply.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            output = try? c.decodeIfPresent([Item].self, forKey: .output)
            usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
            error = try? c.decodeIfPresent(Failure.self, forKey: .error)
        }
    }

    let type: String
    /// A text, reasoning or argument fragment, depending on `type`.
    let delta: String?
    let outputIndex: Int?
    let item: Item?
    let response: Response?
    /// OpenAI's `error` event carries the message here, other servers inside `error`.
    let message: String?
    let error: Failure?

    enum CodingKeys: String, CodingKey {
        case type, delta, item, response, message, error
        case outputIndex = "output_index"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        delta = try? c.decodeIfPresent(String.self, forKey: .delta)
        outputIndex = try? c.decodeIfPresent(Int.self, forKey: .outputIndex)
        item = try? c.decodeIfPresent(Item.self, forKey: .item)
        response = try? c.decodeIfPresent(Response.self, forKey: .response)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        error = try? c.decodeIfPresent(Failure.self, forKey: .error)
    }
}

/// Reads the Responses API's server-sent events into the same `StreamEvent`s chat completions gives.
/// Events it has no use for, such as `response.created` or an event type from a newer API, are ignored.
struct ResponsesDecoder {
    private let jsonDecoder = JSONDecoder()

    func decode(line: String) throws -> [StreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty || payload == "[DONE]" { return [] }
        guard let event = try? jsonDecoder.decode(WireResponsesEvent.self, from: Data(payload.utf8)) else {
            throw ChatClientError.invalidResponse
        }

        switch event.type {
        case "response.output_text.delta":
            return event.delta.flatMap { $0.isEmpty ? nil : [.content($0)] } ?? []
        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            return event.delta.flatMap { $0.isEmpty ? nil : [.reasoning($0)] } ?? []
        case "response.output_item.added":
            guard let item = event.item, item.type == "function_call" else { return [] }
            return [.toolCall(ToolCallDelta(index: event.outputIndex, id: item.callID, name: item.name, arguments: ""))]
        case "response.function_call_arguments.delta":
            return event.delta.map { [.toolCall(ToolCallDelta(index: event.outputIndex, id: nil, name: nil, arguments: $0))] } ?? []
        case "response.completed":
            var events: [StreamEvent] = []
            if let wire = event.response?.usage {
                let usage = Usage(promptTokens: wire.inputTokens, completionTokens: wire.outputTokens,
                                  reasoningTokens: wire.outputTokensDetails?.reasoningTokens)
                if usage != Usage() { events.append(.usage(usage)) }
            }
            let calls = event.response?.output?.contains { $0.type == "function_call" } == true
            return events + [.done(finishReason: calls ? "tool_calls" : "stop")]
        case "response.incomplete":
            return [.done(finishReason: "length")]
        case "response.failed":
            throw ChatClientError.server(event.response?.error?.message ?? "The response failed.")
        case "error":
            throw ChatClientError.server(event.message ?? event.error?.message ?? "Unknown server error")
        default:
            return []
        }
    }
}
