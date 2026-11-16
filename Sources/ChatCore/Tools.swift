import Foundation

/// Arbitrary JSON carried through untouched, like a tool's input schema.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}

/// A function the model may call, in the shape OpenAI's `tools` field takes.
public struct ToolSpec: Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// One call the model asked for, with its outcome once it has run. Kept on the assistant message that made
/// it, so a round of tool use is a single message on screen and expands to the wire's assistant and tool
/// messages when sent.
public struct ToolCall: Codable, Equatable, Sendable, Identifiable {
    public struct Result: Codable, Equatable, Sendable {
        public var text: String
        public var isError: Bool

        public init(text: String, isError: Bool = false) {
            self.text = text
            self.isError = isError
        }
    }

    public var id: String
    public var name: String
    /// JSON text exactly as the model wrote it.
    public var arguments: String
    /// The MCP server that offers the tool, or the image connection for `generate_image`, for display.
    public var server: String
    public var result: Result?

    public init(id: String, name: String, arguments: String, server: String = "", result: Result? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.server = server
        self.result = result
    }
}

/// A piece of a tool call as it streams. Servers split the arguments across chunks keyed by `index`.
public struct ToolCallDelta: Equatable, Sendable {
    public var index: Int?
    public var id: String?
    public var name: String?
    public var arguments: String

    public init(index: Int?, id: String?, name: String?, arguments: String) {
        self.index = index
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Reassembles streamed deltas into whole calls, in the order the model made them.
public struct ToolCallAccumulator: Sendable {
    private var order: [Int] = []
    private var parts: [Int: ToolCall] = [:]

    public init() {}

    public mutating func add(_ delta: ToolCallDelta) {
        // Without an index, a delta carrying an id starts a call and one without continues the last.
        let index = delta.index ?? (delta.id != nil || order.isEmpty ? (order.last ?? -1) + 1 : order.last!)
        if parts[index] == nil {
            order.append(index)
            parts[index] = ToolCall(id: "", name: "", arguments: "")
        }
        if let id = delta.id, !id.isEmpty { parts[index]!.id = id }
        if let name = delta.name { parts[index]!.name += name }
        parts[index]!.arguments += delta.arguments
    }

    /// Calls missing an id get one, since the reply must refer back to each call by id.
    public var calls: [ToolCall] {
        order.enumerated().compactMap { position, index in
            guard var call = parts[index], !call.name.isEmpty else { return nil }
            if call.id.isEmpty { call.id = "call_\(position)" }
            if call.arguments.trimmingCharacters(in: .whitespaces).isEmpty { call.arguments = "{}" }
            return call
        }
    }
}
