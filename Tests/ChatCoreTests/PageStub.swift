import Foundation
@testable import ChatCore

/// A fake web server reached through URLProtocol. Each instance owns a unique host, so tests can run in parallel.
final class PageStub: @unchecked Sendable {
    enum Reply {
        case page(status: Int = 200, type: String? = "text/html; charset=utf-8", body: Data)
        case redirect(to: String)

        static func html(_ text: String) -> Reply { .page(body: Data(text.utf8)) }
    }

    let host = "page-\(UUID().uuidString.lowercased()).test"
    fileprivate let respond: @Sendable (URL) -> Reply
    private let lock = NSLock()
    private var seen: [URLRequest] = []

    init(respond: @escaping @Sendable (URL) -> Reply) {
        self.respond = respond
        PageProtocol.register(self)
    }

    convenience init(_ reply: Reply) { self.init { _ in reply } }

    var requests: [URLRequest] { lock.withLock { seen } }
    func url(_ path: String = "/") -> URL { URL(string: "http://\(host)\(path)")! }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PageProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// A fetcher that does no DNS lookups and finds every name at a public address, since the stub's host name resolves nowhere.
    func fetcher(record: (@Sendable (Exchange) -> Void)? = nil,
                 resolve: @escaping @Sendable (String) async -> [String] = { _ in ["93.184.216.34"] }) -> PageFetcher {
        PageFetcher(session: session, record: record, resolve: resolve)
    }

    fileprivate func handle(_ request: URLRequest) -> Reply {
        lock.withLock { seen.append(request) }
        return respond(request.url!)
    }
}

final class PageProtocol: URLProtocol {
    nonisolated(unsafe) private static var stubs: [String: PageStub] = [:]
    private static let lock = NSLock()

    static func register(_ stub: PageStub) { lock.withLock { stubs[stub.host] = stub } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        guard let stub = Self.lock.withLock({ Self.stubs[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch stub.handle(request) {
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
        case .page(let status, let type, let body):
            var headers = ["Set-Cookie": "session=abc"]
            if let type { headers["Content-Type"] = type }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
