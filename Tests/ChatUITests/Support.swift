import ChatCore
import Foundation
@testable import ChatUI

// Same split as ChatCoreTests: Foundation-using helpers stay out of the Testing-importing file.
func makeTempFileURL(_ name: String) -> (url: URL, cleanup: @Sendable () -> Void) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (dir.appendingPathComponent(name), { try? FileManager.default.removeItem(at: dir) })
}

func makeDefaults() -> (defaults: UserDefaults, cleanup: @Sendable () -> Void) {
    let suite = "ChatUITests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) })
}

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func makePNG(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

func imageInfo(_ data: Data) -> (type: String, width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let type = CGImageSourceGetType(source) as String?,
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int,
          let height = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (type, width, height)
}

func garbage() -> Data { Data("not an image".utf8) }

func bytes(_ text: String) -> Data { Data(text.utf8) }

/// A fake OpenAI-compatible server for a store's URLSession. Replies are decided per chat request body;
/// other paths (models, effort probes) get a 404.
final class StubServer: @unchecked Sendable {
    typealias Reply = (status: Int, body: String)

    let host = "stub-\(UUID().uuidString.lowercased()).test"
    private let respond: @Sendable ([String: Any]) -> Reply
    private let search: @Sendable (String) -> Reply
    private let lock = NSLock()
    private var received: [[String: Any]] = []
    private var queries: [String] = []

    /// `search` answers Serper's /search with the query it was sent.
    init(search: @escaping @Sendable (String) -> Reply = { _ in (404, "") },
         respond: @escaping @Sendable ([String: Any]) -> Reply) {
        self.respond = respond
        self.search = search
        StubProtocol.register(self)
    }

    var searches: [String] { lock.withLock { queries } }
    /// The body of GET /v1/models when set. Otherwise the model list is a 404.
    nonisolated(unsafe) var models: String?
    /// Answers POST /v1/images/generations when set.
    nonisolated(unsafe) var image: (@Sendable ([String: Any]) -> Reply)?
    private var drawings: [[String: Any]] = []
    private var credentials: [(path: String, authorization: String?)] = []
    private var edits: [Data] = []
    /// Raw multipart bodies of POST /v1/images/edits, answered by `image`.
    var edited: [Data] { lock.withLock { edits } }
    /// Bodies of image requests, oldest first.
    var drawn: [[String: Any]] { lock.withLock { drawings } }
    /// The Authorization header each request carried, oldest first.
    var authorizations: [(path: String, authorization: String?)] { lock.withLock { credentials } }
    /// Answers requests to /mcp when set.
    nonisolated(unsafe) var mcp: FakeMCP?
    /// Answers the one-token requests that effort and capability checks send (chat requests that don't stream).
    nonisolated(unsafe) var probe: (@Sendable ([String: Any]) -> Reply)?
    var root: URL { URL(string: "http://\(host)")! }

    /// Bodies of streamed chat requests, oldest first. Title requests are answered "Stub Title" and left out.
    var chats: [[String: Any]] { lock.withLock { received } }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    var baseURL: URL { URL(string: "http://\(host)/v1")! }

    fileprivate func handle(path: String, authorization: String?, body: [String: Any], raw: Data) -> Reply {
        lock.withLock { credentials.append((path, authorization)) }
        if path == "/search" {
            let query = body["q"] as? String ?? ""
            lock.withLock { queries.append(query) }
            return search(query)
        }
        if path.hasSuffix("/models"), let models { return (200, models) }
        if path.hasSuffix("chat/completions"), body["stream"] as? Bool != true, let probe { return probe(body) }
        if path.hasSuffix("images/generations"), let image {
            lock.withLock { drawings.append(body) }
            return image(body)
        }
        if path.hasSuffix("images/edits"), let image {
            lock.withLock { edits.append(raw) }
            return image([:])
        }
        guard path.hasSuffix("chat/completions"), body["stream"] as? Bool == true else { return (404, "") }
        if transcript(body).first?.text.hasPrefix("You name chat conversations") == true { return (200, sse(["Stub Title"])) }
        lock.withLock { received.append(body) }
        return respond(body)
    }
}

func sse(_ chunks: [String]) -> String {
    chunks.map { chunk in
        let event = ["choices": [["index": 0, "delta": ["content": chunk]]]]
        return "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\n"
    }.joined() + "data: [DONE]\n\n"
}

/// A chat stream that ends with the token counts, as a server does when asked for `include_usage`.
func sseWithUsage(_ chunks: [String], prompt: Int, completion: Int) -> String {
    let counts: [String: Any] = ["choices": [Any](), "usage": ["prompt_tokens": prompt, "completion_tokens": completion]]
    let usage = "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: counts), as: UTF8.self) + "\n\n"
    return sse(chunks).replacingOccurrences(of: "data: [DONE]\n\n", with: usage + "data: [DONE]\n\n")
}

/// The `messages` of a chat request as (role, text) pairs. Image parts are dropped.
func transcript(_ body: [String: Any]) -> [(role: String, text: String)] {
    (body["messages"] as? [[String: Any]] ?? []).map { message in
        let role = message["role"] as? String ?? ""
        if let text = message["content"] as? String { return (role, text) }
        let parts = message["content"] as? [[String: Any]] ?? []
        return (role, parts.compactMap { $0["text"] as? String }.joined())
    }
}

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]
    private static let lock = NSLock()

    static func register(_ server: StubServer) { lock.withLock { servers[server.host] = server } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.lock.withLock({ Self.servers[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                                                  headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            return client!.urlProtocolDidFinishLoading(self)
        }
        let raw = Self.body(of: request) ?? Data()
        let body = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        if let mcp = server.mcp, request.url?.path.hasPrefix("/mcp") == true {
            let reply = mcp.handle(request, body: body ?? [:])
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let reply = server.handle(path: request.url?.path ?? "", authorization: request.value(forHTTPHeaderField: "Authorization"),
                                  body: body ?? [:], raw: raw)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A store on a fresh file whose active connection is `server`, with model "m".
@MainActor
func makeStore(server: StubServer) -> (store: ChatStore, cleanup: @Sendable () -> Void) {
    let (defaults, cleanDefaults) = makeDefaults()
    let (file, cleanFile) = makeTempFileURL("conversations.json")
    let store = ChatStore(defaults: defaults, fileURL: file, secrets: .memory(), session: server.session)
    store.saveConnection(Connection(name: "stub", baseURL: server.baseURL, model: "m"), apiKey: "")
    return (store, { cleanDefaults(); cleanFile() })
}

/// A store a test can close and open again on the same saved chats, with `key` as its connection's API key.
@MainActor
struct Rig {
    let store: ChatStore
    let server: StubServer
    let connection: Connection
    private let defaults: UserDefaults
    private let file: URL
    private let secrets: Secrets
    let cleanup: @Sendable () -> Void

    init(server: StubServer, key: String = "") {
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        let secrets = Secrets.memory()
        let store = ChatStore(defaults: defaults, fileURL: file, secrets: secrets, session: server.session)
        let connection = Connection(name: "stub", baseURL: server.baseURL, model: "m")
        store.saveConnection(connection, apiKey: key)
        (self.store, self.server, self.connection, self.defaults, self.file, self.secrets) = (store, server, connection, defaults, file, secrets)
        cleanup = { cleanDefaults(); cleanFile() }
    }

    /// What a new launch would load.
    func reopened() -> ChatStore { ChatStore(defaults: defaults, fileURL: file, secrets: secrets, session: server.session) }
}

func jsonObject(_ data: Data) -> [String: Any]? { try? JSONSerialization.jsonObject(with: data) as? [String: Any] }

/// Echoes the last user message, so a test can tell which prompt a reply answered.
func echoServer() -> StubServer {
    StubServer { body in (200, sse(["re: ", transcript(body).last { $0.role == "user" }?.text ?? ""])) }
}

@MainActor
func untilIdle(_ store: ChatStore) async {
    while store.isBusy { try? await Task.sleep(for: .milliseconds(5)) }
}

func serperPage(_ titles: [String]) -> String {
    let organic = titles.enumerated().map { index, title in
        ["title": title, "link": "https://example.com/\(index)", "snippet": "About \(title)."]
    }
    return String(decoding: try! JSONSerialization.data(withJSONObject: ["organic": organic]), as: UTF8.self)
}

@MainActor
func useSerper(_ store: ChatStore, at server: StubServer) {
    store.defaults.set(server.root.absoluteString, forKey: "serperURL")
    store.setServiceKey(.serper, "test-key")
}

/// Saves `server` as a connection and picks `model` on it as the image tool, leaving the active connection as it was.
@MainActor
func useImageTool(_ store: ChatStore, at server: StubServer, model: String = "img", key: String = "image-key") {
    let active = store.activeConnectionID
    let connection = Connection(name: "images", baseURL: server.baseURL)
    store.saveConnection(connection, apiKey: key)
    store.activate(active)
    store.setImageTool(ImageTool(connectionID: connection.id, model: model))
}

/// Real servers for the live test, read from the environment. Nil unless all six variables are set.
struct LiveServers: Sendable {
    let chatBase, chatKey, chatModel: String
    let imageBase, imageKey, imageModel: String
    /// Where the test writes the pictures it gets, when `LIVE_OUT_DIR` is set.
    let outDirectory: URL?

    static let current: LiveServers? = {
        let env = ProcessInfo.processInfo.environment
        guard let chatBase = env["LIVE_CHAT_BASE"], let chatKey = env["LIVE_CHAT_KEY"], let chatModel = env["LIVE_CHAT_MODEL"],
              let imageBase = env["LIVE_IMAGE_BASE"], let imageKey = env["LIVE_IMAGE_KEY"], let imageModel = env["LIVE_IMAGE_MODEL"],
              ![chatBase, chatModel, imageBase, imageModel].contains(where: \.isEmpty)
        else { return nil }
        return LiveServers(chatBase: chatBase, chatKey: chatKey, chatModel: chatModel,
                           imageBase: imageBase, imageKey: imageKey, imageModel: imageModel,
                           outDirectory: env["LIVE_OUT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) })
    }()

    /// A store set up as saved settings would be on launch, so no model-list refresh can swap the chat model.
    @MainActor
    func makeStore(defaults: UserDefaults, fileURL: URL) throws -> ChatStore {
        let secrets = Secrets.memory()
        let chat = Connection(name: "chat", baseURL: try ServerConfig.parse(baseURL: chatBase, apiKey: "").baseURL, model: chatModel)
        let image = Connection(name: "images", baseURL: try ServerConfig.parse(baseURL: imageBase, apiKey: "").baseURL)
        secrets.set(chat.secretAccount, chatKey)
        secrets.set(image.secretAccount, imageKey)
        defaults.set(try JSONEncoder().encode([chat, image] as [Connection]), forKey: "connections")
        defaults.set(chat.id.uuidString, forKey: "activeConnection")
        defaults.set(try JSONEncoder().encode(ImageTool(connectionID: image.id, model: imageModel)), forKey: "imageTool")
        return ChatStore(defaults: defaults, fileURL: fileURL, secrets: secrets)
    }
}

/// An MCP server over Streamable HTTP, to the spec: a token, a session, paged tools/list, tools/call.
final class FakeMCP: @unchecked Sendable {
    struct Tool {
        var name: String
        var readOnly: Bool
        var result: String
    }

    let token: String
    var tools: [Tool]
    var pageSize = 2
    /// Replies as SSE rather than a JSON body.
    var sse = false
    private let lock = NSLock()
    private var session: String?
    private var calls: [(name: String, arguments: [String: Any])] = []
    private var methods: [String] = []

    init(token: String = "tok", tools: [Tool]) {
        self.token = token
        self.tools = tools
    }

    var called: [String] { lock.withLock { calls.map(\.name) } }
    var lastArguments: [String: Any]? { lock.withLock { calls.last?.arguments } }
    var seen: [String] { lock.withLock { methods } }
    func forgetSession() { lock.withLock { session = nil } }

    func handle(_ request: URLRequest, body: [String: Any]) -> (status: Int, body: String, headers: [String: String]) {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else { return (401, "", [:]) }
        let method = body["method"] as? String ?? ""
        lock.withLock { methods.append(method) }
        guard let id = body["id"] else { return (202, "", [:]) }
        if method != "initialize" {
            let sent = request.value(forHTTPHeaderField: "Mcp-Session-Id")
            guard sent != nil, sent == lock.withLock({ session }) else { return (404, "Session not found", [:]) }
        }
        let params = body["params"] as? [String: Any] ?? [:]
        var headers: [String: String] = [:]
        let result: Any
        switch method {
        case "initialize":
            let fresh = UUID().uuidString
            lock.withLock { session = fresh }
            headers["Mcp-Session-Id"] = fresh
            result = ["protocolVersion": "2025-06-18", "capabilities": ["tools": [:]], "serverInfo": ["name": "fake", "version": "1"]]
        case "tools/list":
            let start = Int(params["cursor"] as? String ?? "0") ?? 0
            let page = tools[start..<min(start + pageSize, tools.count)].map { tool in
                ["name": tool.name, "description": "Does \(tool.name)",
                 "inputSchema": ["type": "object", "properties": [:]],
                 "annotations": ["readOnlyHint": tool.readOnly]] as [String: Any]
            }
            var listing: [String: Any] = ["tools": page]
            if start + pageSize < tools.count { listing["nextCursor"] = String(start + pageSize) }
            result = listing
        case "tools/call":
            let name = params["name"] as? String ?? ""
            lock.withLock { calls.append((name, params["arguments"] as? [String: Any] ?? [:])) }
            guard let tool = tools.first(where: { $0.name == name }) else {
                return reply(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool \(name)"]], headers)
            }
            result = ["content": [["type": "text", "text": tool.result]]]
        default:
            return reply(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "No method \(method)"]], headers)
        }
        return reply(["jsonrpc": "2.0", "id": id, "result": result], headers)
    }

    private func reply(_ message: [String: Any], _ headers: [String: String]) -> (Int, String, [String: String]) {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        var headers = headers
        if sse {
            headers["Content-Type"] = "text/event-stream"
            let ping = #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}"#
            return (200, "event: message\ndata: \(ping)\n\nevent: message\ndata: \(json)\n\n", headers)
        }
        headers["Content-Type"] = "application/json"
        return (200, json, headers)
    }
}

/// A chat stream that calls one tool.
func toolCallReply(_ name: String, id: String = "call_1", arguments: String = "{}") -> String {
    let event: [String: Any] = ["choices": [["index": 0, "delta": ["tool_calls": [[
        "index": 0, "id": id, "type": "function", "function": ["name": name, "arguments": arguments],
    ]]], "finish_reason": "tool_calls"]]]
    return "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\ndata: [DONE]\n\n"
}

/// The names of the tools a chat request offered.
func offeredTools(_ body: [String: Any]) -> [String] {
    (body["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
}

func lastRole(_ body: [String: Any]) -> String? { (body["messages"] as? [[String: Any]])?.last?["role"] as? String }

@MainActor
func addMCP(_ store: ChatStore, at server: StubServer, token: String = "tok") {
    store.saveMCPServer(MCPServer(name: "Fake", url: server.root.appendingPathComponent("mcp")), token: token)
}
