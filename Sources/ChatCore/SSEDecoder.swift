import Foundation

public enum StreamEvent: Equatable, Sendable {
    case content(String)
    case reasoning(String)
    case toolCall(ToolCallDelta)
    /// Token counts, from the final chunk of a stream that asked for them.
    case usage(Usage)
    /// Something the client changed about the request, such as retrying without `stream_options`.
    case adapted(Adaptation)
    case done(finishReason: String?)
}

public enum ChatClientError: Error, Equatable, LocalizedError {
    case http(status: Int, message: String)
    case invalidResponse
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            message.isEmpty ? "Server returned HTTP \(status)." : "HTTP \(status): \(message)"
        case .invalidResponse:
            "The server sent a response that couldn't be understood."
        case .server(let message):
            "Server error: \(message)"
        }
    }
}

struct SSEDecoder {
    private let jsonDecoder = JSONDecoder()

    func decode(line: String) throws -> [StreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return [] }
        if payload == "[DONE]" { return [.done(finishReason: nil)] }

        let data = Data(payload.utf8)
        if let envelope = try? jsonDecoder.decode(WireErrorEnvelope.self, from: data) {
            throw ChatClientError.server(envelope.message)
        }
        guard let chunk = try? jsonDecoder.decode(WireChunk.self, from: data) else {
            throw ChatClientError.invalidResponse
        }

        var events: [StreamEvent] = []
        for choice in chunk.choices ?? [] {
            if let delta = choice.delta {
                if let text = delta.reasoningContent ?? delta.reasoning, !text.isEmpty {
                    events.append(.reasoning(text))
                }
                if let text = delta.content, !text.isEmpty {
                    events.append(.content(text))
                }
                for call in delta.toolCalls ?? [] {
                    events.append(.toolCall(ToolCallDelta(index: call.index, id: call.id, name: call.function?.name,
                                                          arguments: call.function?.arguments ?? "")))
                }
            }
            if let reason = choice.finishReason {
                events.append(.done(finishReason: reason))
            }
        }
        if let wire = chunk.usage {
            let usage = Usage(promptTokens: wire.promptTokens, completionTokens: wire.completionTokens,
                              reasoningTokens: wire.completionTokensDetails?.reasoningTokens)
            if usage != Usage() { events.append(.usage(usage)) }
        }
        return events
    }
}
