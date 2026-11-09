import Foundation

/// A tool an MCP server offers.
public struct MCPTool: Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    /// The server's hint that the tool only reads. Anything else may change things, so it asks first.
    public var readOnly: Bool

    public init(name: String, description: String, inputSchema: JSONValue, readOnly: Bool) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
    }
}

public enum MCPError: Error, Equatable, LocalizedError {
    case unauthorized
    case http(status: Int, message: String)
    case rpc(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The server rejected the token."
        case .http(let status, let message): message.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(message)"
        case .rpc(let message): message
        case .invalidResponse: "The server's reply wasn't valid MCP."
        }
    }
}

/// A client for one MCP server over Streamable HTTP: JSON-RPC posted to a single URL, answered with
/// either a JSON body or an SSE stream.
public actor MCPClient {
    public static let protocolVersion = "2025-06-18"
    /// Tool output beyond this is cut, since a whole file or search page would swamp the model's context.
    public static let resultLimit = 16_000

    let url: URL
    let token: String?
    let session: URLSession
    private var sessionID: String?
    private var initialized = false
    private var nextID = 1

    public init(url: URL, token: String?, session: URLSession = .shared) {
        self.url = url
        self.token = token.flatMap { $0.isEmpty ? nil : $0 }
        self.session = session
    }

    public func listTools() async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var cursor: String?
        repeat {
            let result = try await request("tools/list", cursor.map { .object(["cursor": .string($0)]) } ?? .object([:]))
            guard case .array(let page) = result["tools"] ?? .array([]) else { throw MCPError.invalidResponse }
            tools += page.compactMap { tool in
                guard let name = tool["name"]?.string else { return nil }
                return MCPTool(name: name, description: tool["description"]?.string ?? "",
                               inputSchema: tool["inputSchema"] ?? .object(["type": .string("object")]),
                               readOnly: tool["annotations"]?["readOnlyHint"] == .bool(true))
            }
            cursor = result["nextCursor"]?.string
        } while cursor != nil && tools.count < 1000
        return tools
    }

    /// A tool's own failure comes back as an error result for the model to read, not a thrown error.
    public func callTool(_ name: String, arguments: String) async throws -> ToolCall.Result {
        guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)),
              case .object = parsed
        else { return ToolCall.Result(text: "The arguments weren't a JSON object: \(arguments)", isError: true) }
        let result = try await request("tools/call", .object(["name": .string(name), "arguments": parsed]))
        var text = Self.text(of: result)
        if text.count > Self.resultLimit {
            text = String(text.prefix(Self.resultLimit)) + "\n[Cut off after \(Self.resultLimit) characters.]"
        }
        return ToolCall.Result(text: text, isError: result["isError"] == .bool(true))
    }

    static func text(of result: JSONValue) -> String {
        guard case .array(let parts) = result["content"] ?? .array([]) else { return "" }
        let pieces = parts.compactMap { part -> String? in
            switch part["type"]?.string {
            case "text": part["text"]?.string
            case "resource": part["resource"]?["text"]?.string ?? part["resource"]?["uri"]?.string.map { "[Resource \($0)]" }
            case "resource_link": part["uri"]?.string.map { "[Link \($0)]" }
            case "image": "[Image]"
            case "audio": "[Audio]"
            default: nil
            }
        }
        if pieces.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONEncoder().encode(structured) {
            return String(decoding: data, as: UTF8.self)
        }
        return pieces.joined(separator: "\n")
    }

    // MARK: Transport

    private func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        if !initialized { try await initialize() }
        do {
            return try await send(method, params)
        } catch MCPError.http(404, _) where sessionID != nil {
            // The server forgot the session, so start a new one once.
            initialized = false
            sessionID = nil
            try await initialize()
            return try await send(method, params)
        }
    }

    private func initialize() async throws {
        _ = try await send("initialize", .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("LMChat"), "version": .string("1.0")]),
        ]))
        initialized = true
        try await notify("notifications/initialized")
    }

    private func send(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let message = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                        "method": .string(method), "params": params])
        let (bytes, http) = try await post(message)
        if let header = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = header }

        let replies: AsyncThrowingStream<JSONValue, Error>
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            replies = Self.events(bytes)
        } else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            let value = try JSONDecoder().decode(JSONValue.self, from: body)
            replies = AsyncThrowingStream { continuation in
                if case .array(let batch) = value { batch.forEach { continuation.yield($0) } } else { continuation.yield(value) }
                continuation.finish()
            }
        }
        for try await reply in replies where reply["id"] == .number(Double(id)) {
            if let error = reply["error"] {
                throw MCPError.rpc(error["message"]?.string ?? "The server returned an error.")
            }
            return reply["result"] ?? .object([:])
        }
        throw MCPError.invalidResponse
    }

    private func notify(_ method: String) async throws {
        _ = try await post(.object(["jsonrpc": .string("2.0"), "method": .string(method)]))
    }

    private func post(_ message: JSONValue) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if initialized { request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try JSONEncoder().encode(message)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw MCPError.unauthorized }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 2000 { break }
            }
            throw MCPError.http(status: http.statusCode,
                                message: String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (bytes, http)
    }

    /// JSON-RPC messages from an SSE body. An event's data lines join with newlines; a blank line ends it.
    static func events(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var data: [String] = []
                    func flush() {
                        defer { data = [] }
                        guard !data.isEmpty,
                              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(data.joined(separator: "\n").utf8))
                        else { return }
                        continuation.yield(value)
                    }
                    // `lines` skips blank lines, so an event also ends where the next one's first field starts.
                    for try await line in bytes.lines {
                        if line.hasPrefix("data:") {
                            data.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                            if (try? JSONDecoder().decode(JSONValue.self, from: Data(data.joined(separator: "\n").utf8))) != nil {
                                flush()
                            }
                        } else if line.hasPrefix("event:") || line.hasPrefix("id:") {
                            flush()
                        }
                    }
                    flush()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
