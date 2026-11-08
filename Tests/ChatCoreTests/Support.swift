@testable import ChatCore
import Foundation

// Kept separate from the Testing-importing files: the CLT toolchain lacks the
// _Testing_Foundation overlay, which a file importing both would require.
func jsonObject(_ data: Data?) -> [String: Any]? {
    data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

func makeTempFileURL(_ name: String) -> (url: URL, cleanup: @Sendable () -> Void) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (dir.appendingPathComponent(name), { try? FileManager.default.removeItem(at: dir) })
}

func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

func bytes(_ text: String) -> Data { Data(text.utf8) }

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// A fake OpenAI-compatible server reached through URLProtocol. Each instance owns a unique host,
/// so tests using different servers can run in parallel.
final class StubServer: @unchecked Sendable {
    typealias Reply = (status: Int, body: String)

    let host = "stub-\(UUID().uuidString.lowercased()).test"
    private let respond: @Sendable ([String: Any]) -> Reply
    private let lock = NSLock()
    private var received: [[String: Any]] = []

    init(respond: @escaping @Sendable ([String: Any]) -> Reply) {
        self.respond = respond
        StubProtocol.register(self)
    }

    var bodies: [[String: Any]] { lock.withLock { received } }

    var client: ChatClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ChatClient(config: try! ServerConfig.parse(baseURL: "http://\(host)/v1", apiKey: ""),
                          session: URLSession(configuration: configuration))
    }

    fileprivate func handle(_ body: [String: Any]) -> Reply {
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

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]
    private static let lock = NSLock()

    static func register(_ server: StubServer) { lock.withLock { servers[server.host] = server } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let server = Self.lock.withLock { Self.servers[request.url?.host ?? ""] }!
        let reply = server.handle(jsonObject(Self.body(of: request)) ?? [:])
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


func makeImageStore() -> (store: ImageStore, cleanup: @Sendable () -> Void) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (ImageStore(directory: dir), { try? FileManager.default.removeItem(at: dir) })
}

func fileSize(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
