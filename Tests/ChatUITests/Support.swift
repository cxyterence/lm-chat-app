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
    var root: URL { URL(string: "http://\(host)")! }

    /// Bodies of streamed chat requests, oldest first. Title requests are answered "Stub Title" and left out.
    var chats: [[String: Any]] { lock.withLock { received } }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    var baseURL: URL { URL(string: "http://\(host)/v1")! }

    fileprivate func handle(path: String, body: [String: Any]) -> Reply {
        if path == "/search" {
            let query = body["q"] as? String ?? ""
            lock.withLock { queries.append(query) }
            return search(query)
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
        let server = Self.lock.withLock { Self.servers[request.url?.host ?? ""] }!
        let body = Self.body(of: request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let reply = server.handle(path: request.url?.path ?? "", body: body ?? [:])
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
