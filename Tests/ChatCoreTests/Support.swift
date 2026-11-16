@testable import ChatCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
/// A reply with status 0 fails the connection, and `holdsOpen` leaves a response unfinished, like a stream
/// that is still going.
final class StubServer: @unchecked Sendable {
    typealias Reply = (status: Int, body: String)

    let host = "stub-\(UUID().uuidString.lowercased()).test"
    let holdsOpen: Bool
    private let respond: @Sendable (_ path: String, _ body: [String: Any]) -> Reply
    private let lock = NSLock()
    private var received: [[String: Any]] = []

    init(holdsOpen: Bool = false, respond: @escaping @Sendable ([String: Any]) -> Reply) {
        self.holdsOpen = holdsOpen
        self.respond = { _, body in respond(body) }
        StubProtocol.register(self)
    }

    init(route: @escaping @Sendable (_ path: String, _ body: [String: Any]) -> Reply) {
        holdsOpen = false
        respond = route
        StubProtocol.register(self)
    }

    var bodies: [[String: Any]] { lock.withLock { received } }
    private var raw: [(path: String, method: String?, contentType: String?, body: Data)] = []
    /// Every request as sent, oldest first.
    var requests: [(path: String, method: String?, contentType: String?, body: Data)] { lock.withLock { raw } }

    var client: ChatClient { makeClient(apiKey: "") }

    func makeClient(apiKey: String, record: (@Sendable (Exchange) -> Void)? = nil) -> ChatClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ChatClient(config: try! ServerConfig.parse(baseURL: "http://\(host)/v1", apiKey: apiKey),
                          session: URLSession(configuration: configuration), record: record)
    }

    fileprivate func handle(_ body: [String: Any], raw request: (path: String, method: String?, contentType: String?, body: Data)) -> Reply {
        lock.withLock { received.append(body); raw.append(request) }
        return respond(request.path, body)
    }
}

/// Collects the exchanges a client reports.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Exchange] = []

    var exchanges: [Exchange] { lock.withLock { items } }
    var sink: @Sendable (Exchange) -> Void { { [self] exchange in lock.withLock { items.append(exchange) } } }

    /// Waits for `count` exchanges, since a stream reports from its own task after the caller has moved on.
    func wait(for count: Int) async -> [Exchange] {
        for _ in 0..<300 where exchanges.count < count { try? await Task.sleep(for: .milliseconds(10)) }
        return exchanges
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
        let body = Self.body(of: request) ?? Data()
        let reply = server.handle(jsonObject(body) ?? [:],
                                  raw: (request.url?.path ?? "", request.httpMethod, request.value(forHTTPHeaderField: "Content-Type"), body))
        let response = HTTPURLResponse(url: request.url!, statusCode: max(reply.status, 200), httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        if reply.status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        if !server.holdsOpen { client?.urlProtocolDidFinishLoading(self) }
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

func isJSONNull(_ value: Any?) -> Bool { value is NSNull }

func makePNG(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}
