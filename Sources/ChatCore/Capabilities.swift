import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Support: Equatable, Sendable {
    case yes
    /// The server's error naming the feature.
    case no(reason: String)
    /// The check itself failed, so nothing is known.
    case unknown(reason: String)
}

public enum ToolSupport: Equatable, Sendable {
    case yes
    /// Tools are refused while the model reasons, as OpenAI does for gpt-6 models on chat completions.
    case onlyWithReasoningOff
    case no(reason: String)
    case unknown(reason: String)
}

/// One name and value the server reports about itself or a model.
public struct Fact: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// What a model on a connection can do, found by asking it.
public struct CapabilityReport: Equatable, Sendable {
    public var tools: ToolSupport
    public var vision: Support
    /// The reasoning levels it accepts, empty when it takes none.
    public var efforts: [ReasoningEffort]
    public var contextLength: Int?
    /// What the model list entry and SGLang's `/server_info` say beyond that, without anything that looks like a key.
    public var server: [Fact]

    public init(tools: ToolSupport, vision: Support, efforts: [ReasoningEffort], contextLength: Int? = nil, server: [Fact] = []) {
        self.tools = tools
        self.vision = vision
        self.efforts = efforts
        self.contextLength = contextLength
        self.server = server
    }
}

extension ChatClient {
    /// Asks `model` what it supports. The probes run together and cost a handful of one-token requests, so run
    /// this when the user asks. Throws when the reasoning levels can't be read (a wrong key, a server that is
    /// down), since nothing else would be trustworthy either. A probe that fails alone reads as `unknown`.
    public func capabilities(model: String) async throws -> CapabilityReport {
        async let levels = Result { try await reasoningEfforts(model: model) }
        async let tools = toolSupport(model: model, effort: nil)
        async let vision = visionSupport(model: model)
        async let listing = try? modelList()
        async let info = serverInfo()

        let efforts = try await levels.get()
        var toolSupport = await tools
        // A model whose default is no reasoning takes tools until the app sends a level, so try one.
        if toolSupport == .yes, let level = efforts.first(where: { $0 != ReasoningEffort.none }),
           case .onlyWithReasoningOff = await self.toolSupport(model: model, effort: level.rawValue) {
            toolSupport = .onlyWithReasoningOff
        }
        let entry = await listing?.data.first { $0.id == model }?.fields
        return CapabilityReport(
            tools: toolSupport,
            vision: await vision,
            efforts: efforts,
            contextLength: entry.flatMap(Self.contextLength),
            server: Self.facts(entry: entry, serverInfo: await info, apiKey: config.apiKey)
        )
    }

    func toolSupport(model: String, effort: String?) async -> ToolSupport {
        do {
            let reply = try await probe(WireProbeRequest(model: model, reasoningEffort: effort, tools: [Self.probeTool]))
            guard Self.refusesToolsWithReasoning(reply) else { return ToolSupport(Support(reply, naming: Self.toolWords)) }
            let off = try await probe(WireProbeRequest(model: model, reasoningEffort: "none", tools: [Self.probeTool]))
            if case .yes = Support(off, naming: Self.toolWords) { return .onlyWithReasoningOff }
            return ToolSupport(Support(off, naming: Self.toolWords))
        } catch {
            return .unknown(reason: error.localizedDescription)
        }
    }

    func visionSupport(model: String) async -> Support {
        do {
            let message = WireMessage(role: .user, content: "hi", images: [Self.probeImage])
            return Support(try await probe(WireProbeRequest(model: model, messages: [message])), naming: Self.imageWords)
        } catch {
            return .unknown(reason: error.localizedDescription)
        }
    }

    /// SGLang serves it beside `/v1`. Everything else answers 404, or fails, which is no loss.
    func serverInfo() async -> JSONValue? {
        var request = URLRequest(url: config.baseURL.deletingLastPathComponent().appendingPathComponent("server_info"))
        request.timeoutInterval = 15
        authorize(&request)
        guard let (data, http) = try? await perform(request, purpose: .probe), (200..<300).contains(http.statusCode) else {
            return nil
        }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// OpenAI's wording is "Function tools with reasoning_effort are not supported ... set reasoning_effort to 'none'".
    static func refusesToolsWithReasoning(_ reply: ProbeReply) -> Bool {
        guard reply.status == 400 || reply.status == 422 else { return false }
        let text = reply.text.lowercased()
        return (text.contains("reasoning_effort") || text.contains("reasoning effort"))
            && toolWords.contains { text.contains($0) }
    }

    private static let toolWords = ["tool", "function"]
    private static let imageWords = ["image", "vision", "multimodal", "multi-modal"]

    private static let probeTool = WireChatRequest.Tool(
        function: .init(name: "get_time", description: "Returns the current time.",
                        parameters: .object(["type": .string("object"), "properties": .object([:])]))
    )

    /// Big enough for vision models that refuse a tiny picture.
    private static let probeImage: Data = {
        let side = 64
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }()

    static func contextLength(in fields: [String: JSONValue]) -> Int? {
        for key in ["max_model_len", "context_length", "context_window", "max_context_length"] {
            if let length = fields[key]?.whole { return length }
        }
        return fields["meta"]?["n_ctx_train"]?.whole
    }

    /// The scalars of both sources, nested objects named like `meta.n_vocab`, in name order. Anything named
    /// like a secret, such as SGLang's `api_key`, is left out, and so is any value equal to the connection's key.
    static func facts(entry: [String: JSONValue]?, serverInfo: JSONValue?, apiKey: String?) -> [Fact] {
        var facts: [Fact] = []
        if let entry {
            collect(.object(entry.filter { !["id", "object", "created"].contains($0.key) }), prefix: "", into: &facts)
        }
        if let serverInfo { collect(serverInfo, prefix: "", into: &facts) }
        return facts.filter { fact in
            let name = fact.name.lowercased()
            let secret = ["key", "secret", "password", "passwd"].contains { name.contains($0) } || name.hasSuffix("token")
            return !secret && (apiKey?.isEmpty != false || fact.value != apiKey)
        }
    }

    private static func collect(_ value: JSONValue, prefix: String, into facts: inout [Fact]) {
        switch value {
        case .object(let fields):
            guard prefix.split(separator: ".").count < 2 else { return }
            for key in fields.keys.sorted() { collect(fields[key]!, prefix: prefix.isEmpty ? key : "\(prefix).\(key)", into: &facts) }
        case .array(let items):
            let texts = items.compactMap(\.scalarText)
            let joined = texts.joined(separator: ", ")
            if !prefix.isEmpty, texts.count == items.count, !items.isEmpty, joined.count <= 120 {
                facts.append(Fact(name: prefix, value: joined))
            }
        case .null:
            break
        case .bool, .number, .string:
            if let text = value.scalarText, !text.isEmpty, !prefix.isEmpty { facts.append(Fact(name: prefix, value: text)) }
        }
    }
}

private extension Support {
    /// A 400 counts as `no` only when it names the feature. The one-token limit makes some servers answer a
    /// request they accepted with a 400 about running out of tokens.
    init(_ reply: ProbeReply, naming words: [String]) {
        switch reply.status {
        case 200..<300:
            self = .yes
        case 400, 422:
            let text = reply.text.lowercased()
            self = words.contains { text.contains($0) } ? .no(reason: reply.message) : .yes
        default:
            self = .unknown(reason: reply.error.errorDescription ?? "HTTP \(reply.status)")
        }
    }
}

private extension ToolSupport {
    init(_ support: Support) {
        switch support {
        case .yes: self = .yes
        case .no(let reason): self = .no(reason: reason)
        case .unknown(let reason): self = .unknown(reason: reason)
        }
    }
}

private extension JSONValue {
    var whole: Int? {
        if case .number(let number) = self { Int(exactly: number) } else { nil }
    }

    var scalarText: String? {
        switch self {
        case .string(let text): text
        case .number(let number): Int(exactly: number).map(String.init) ?? "\(number)"
        case .bool(let flag): flag ? "true" : "false"
        case .null, .array, .object: nil
        }
    }
}
