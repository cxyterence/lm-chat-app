#if os(macOS)
import ChatCore
import Foundation
import SwiftUI

/// Sample replies, requests and reports for the developer-tools screens.
@MainActor
enum DevToolsSnapshot {
    static let phone = CGSize(width: 390, height: 780)

    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    private static let reasonWhy = "this model does not support tools"

    /// A reply that went out without tools after the server refused them, with the refused request and the one that worked.
    struct Sample {
        let store: ChatStore
        let reply: UUID
        let refused: Exchange
        let worked: Exchange
        let resent: Exchange
    }

    static func makeSample(defaults: UserDefaults, directory: URL) throws -> Sample {
        let reply = ChatMessage(role: .assistant,
                                content: "A red fox stands in deep snow, ears forward, with low golden light behind it.",
                                adaptations: [.toolsDropped(reason: reasonWhy), .effortChanged(from: .high, to: .medium)])
        let conversation = Conversation(title: "What is in this photo?", model: "sample-model", messages: [
            ChatMessage(role: .user, content: "What is in this photo?"), reply,
        ])
        try ConversationStore.save([conversation], to: directory.appendingPathComponent("devtools.json"))
        let store = ChatStore(defaults: defaults, fileURL: directory.appendingPathComponent("devtools.json"), secrets: .memory())

        let refused = chat(at: 0, tools: true, status: 400, finish: 0.34, response: #"{"error":{"message":"\#(reasonWhy)","type":"invalid_request_error"}}"#,
                           error: "HTTP 400: \(reasonWhy)")
        let worked = chat(at: 0.4, tools: false, status: 200, finish: 29.9, response: stream(deltas: 700), firstToken: 1.2,
                          usage: Usage(promptTokens: 1_850, completionTokens: 1_204, reasoningTokens: 310))
        var resent = chat(at: 40, tools: false, status: 200, finish: 41.1, response: stream(deltas: 3), purpose: .resend)
        resent.usage = nil
        for exchange in [refused, worked, resent] { store.attach(exchange, to: reply.id) }
        return Sample(store: store, reply: reply.id, refused: refused, worked: worked, resent: resent)
    }

    private static func chat(at offset: TimeInterval, tools: Bool, status: Int, finish: TimeInterval, response: String,
                             purpose: Exchange.Purpose = .chat, firstToken: TimeInterval? = nil, error: String? = nil,
                             usage: Usage? = nil) -> Exchange {
        let photo = "data:image/jpeg;base64," + Data(count: 312 * 1024).base64EncodedString()
        var body: [String: Any] = [
            "model": "gpt-6-luna", "stream": true, "stream_options": ["include_usage": true], "reasoning_effort": "medium",
            "messages": [
                ["role": "system", "content": "You are a helpful assistant."],
                ["role": "user", "content": [["type": "text", "text": "What is in this photo?"],
                                              ["type": "image_url", "image_url": ["url": photo]]]],
            ],
        ]
        if tools {
            body["tools"] = [["type": "function", "function": ["name": "get_me", "description": "Returns the signed-in user.",
                                                                  "parameters": ["type": "object", "properties": [String: Any]()]]]]
        }
        return Exchange(
            purpose: purpose, url: URL(string: "https://llm.example.com/v1/chat/completions")!,
            requestHeaders: [.init(name: "Accept", value: "text/event-stream"), .init(name: "Authorization", value: "Bearer $API_KEY"),
                             .init(name: "Content-Type", value: "application/json")],
            requestBody: try! JSONSerialization.data(withJSONObject: body),
            status: status,
            responseHeaders: [.init(name: "content-type", value: status == 200 ? "text/event-stream; charset=utf-8" : "application/json"),
                              .init(name: "date", value: "Tue, 14 Nov 2023 22:13:20 GMT"), .init(name: "server", value: "uvicorn"),
                              .init(name: "x-request-id", value: "req_8f2c1d0a")],
            responseBody: response, responseTruncated: response.utf8.count >= Exchange.bodyLimit, error: error,
            startedAt: start + offset, firstByteAt: start + offset + 0.3, firstTokenAt: firstToken.map { start + offset + $0 },
            finishedAt: start + finish, usage: usage)
    }

    private static func stream(deltas: Int) -> String {
        let words = "A red fox stands in deep snow with its ears forward and low golden light behind it.".split(separator: " ")
        var lines: [String] = []
        for index in 0..<deltas {
            lines.append(#"data: {"id":"chatcmpl-91","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"\#(words[index % words.count]) "}}]}"# + "\n")
        }
        lines.append(#"data: {"id":"chatcmpl-91","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n")
        lines.append(#"data: {"id":"chatcmpl-91","choices":[],"usage":{"prompt_tokens":1850,"completion_tokens":1204}}"# + "\n")
        lines.append("data: [DONE]\n")
        return lines.joined(separator: "\n")
    }

    /// Every request fails to connect, as when the server is off.
    private final class Refusing: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let message = [NSLocalizedDescriptionKey: "Could not connect to the server."]
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: message))
        }
        override func stopLoading() {}
    }

    /// A store whose server is off, after one message that could not be sent.
    static func makeFailingStore(defaults: UserDefaults, directory: URL) async throws -> ChatStore {
        try ConversationStore.save([Conversation(title: "Hello", model: "sample-model")], to: directory.appendingPathComponent("failing.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Refusing.self]
        let store = ChatStore(defaults: defaults, fileURL: directory.appendingPathComponent("failing.json"), secrets: .memory(),
                              session: URLSession(configuration: configuration))
        store.send("Hello there")
        for _ in 0..<200 where store.isBusy { try await Task.sleep(for: .milliseconds(50)) }
        return store
    }

    static let report = CapabilityReport(
        tools: .onlyWithReasoningOff,
        vision: .no(reason: "Invalid content type. image_url is only supported by certain models."),
        efforts: [.none, .low, .medium],
        contextLength: 131_072,
        server: (1...95).map { Fact(name: $0 % 7 == 0 ? "meta.n_vocab_\($0)" : "field_\($0)", value: $0 == 3 ? String(repeating: "a long value ", count: 14) : "\($0 * 128)") })

    static let failedCheck = ChatStore.CapabilityCheck.failed("The server rejected the API key.")
}
#endif
