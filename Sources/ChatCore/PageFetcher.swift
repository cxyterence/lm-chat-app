import Foundation

/// A page fetched for `fetch_url`, as text.
public struct Page: Equatable, Sendable {
    /// The most characters of a page the model is given.
    public static let characterLimit = 20_000

    /// The address the page was read from, after redirects.
    public var url: URL
    public var title: String?
    public var text: String
    /// The download was stopped at `PageFetcher.byteLimit`.
    public var truncated: Bool

    public init(url: URL, title: String?, text: String, truncated: Bool = false) {
        self.url = url
        self.title = title
        self.text = text
        self.truncated = truncated
    }

    /// What the model reads: the title, the address, then the text, all cut to `characterLimit` with a last line saying so.
    public var toolResult: String {
        let full = (title.map { "Title: \($0)\n" } ?? "") + "URL: \(url.absoluteString)\n\n" + text
        guard truncated || full.count > Self.characterLimit else { return full }
        return full.prefix(Self.characterLimit) + "\n\n[The page was cut off here. It has more text than fits.]"
    }
}

/// Fetches a page over HTTP, refusing addresses on this device or a private network. Sends no cookies and no
/// credentials. Pass a session without a cookie store, such as `privateSession()`.
public struct PageFetcher: Sendable {
    public static let byteLimit = 2 * 1024 * 1024
    public static let timeout: TimeInterval = 20
    /// The most a whole fetch may take. `timeout` only counts the time between bytes.
    public static let deadline: TimeInterval = 30
    static let userAgent = "LMChat/1.0"

    let session: URLSession
    let record: (@Sendable (Exchange) -> Void)?
    /// The numeric addresses a host name resolves to. A name that resolves to a private address is refused.
    let resolve: @Sendable (String) async -> [String]

    public init(session: URLSession = PageFetcher.privateSession(), record: (@Sendable (Exchange) -> Void)? = nil,
                resolve: @escaping @Sendable (String) async -> [String] = PageFetcher.systemResolve) {
        self.session = session
        self.record = record
        self.resolve = resolve
    }

    /// The same fetcher, reporting each request to `record`.
    public func recording(to record: @escaping @Sendable (Exchange) -> Void) -> PageFetcher {
        PageFetcher(session: session, record: record, resolve: resolve)
    }

    public static func privateSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = deadline
        return URLSession(configuration: configuration)
    }

    public func fetch(_ url: URL) async throws -> Page {
        if let reason = await refusal(for: url) { throw FetchRequest.Invalid(reason) }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.httpShouldHandleCookies = false
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,text/plain,application/json,application/xml;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")

        let redirects = RedirectGuard(fetcher: self)
        return try await Exchange.capture(request, purpose: .fetch, record: record) { exchange in
            var body = BodyCapture()
            defer { exchange.store(body) }
            var bytes: URLSession.AsyncBytes?
            let response: URLResponse
            do {
                let started = try await session.bytes(for: request, delegate: redirects)
                (bytes, response) = (started.0, started.1)
            } catch {
                throw redirects.refusal.map(FetchRequest.Invalid.init) ?? error
            }
            guard let http = response as? HTTPURLResponse else { throw ChatClientError.invalidResponse }
            exchange.receive(http)
            exchange.firstByteAt = Date()
            guard (200..<300).contains(http.statusCode) else {
                throw FetchRequest.Invalid("The server answered HTTP \(http.statusCode) (\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))).")
            }
            let kind = Kind(contentType: http.value(forHTTPHeaderField: "Content-Type"))
            if case .other(let message) = kind { throw FetchRequest.Invalid(message) }

            var data = Data()
            var truncated = false
            for try await byte in bytes! {
                if data.count == Self.byteLimit { truncated = true; break }
                data.append(byte)
                body.append(byte)
            }
            // Letting go of the stream ends a download that was cut short, and the connection metrics come with it.
            bytes = nil
            if let reason = await redirects.connectionRefusal() { throw FetchRequest.Invalid(reason) }
            let text = Self.decode(data, charset: http.textEncodingName)
            if case .html = kind {
                let page = PageText.extract(fromHTML: text)
                return Page(url: http.url ?? url, title: page.title, text: page.text, truncated: truncated)
            }
            return Page(url: http.url ?? url, title: nil, text: text, truncated: truncated)
        }.outcome.get()
    }

    /// Why `url` can't be fetched: what its address says, then what its host name resolves to. A name that resolves
    /// to nothing is refused too, since a proxy could still resolve it to a machine on a private network.
    func refusal(for url: URL) async -> String? {
        if let reason = FetchRequest.refusal(for: url) { return reason }
        guard let host = url.host(percentEncoded: false) else { return nil }
        let resolved = await resolve(host)
        if resolved.isEmpty { return "No server was found for \(host)." }
        return resolved.contains(where: FetchRequest.isPrivate(host:))
            ? "\(host) resolves to this device or a private network, so it can't be fetched." : nil
    }

    /// Why a page read over a connection to `address` must not be returned, for a name that resolved to a public
    /// address when it was checked and to a private one when the connection was made. A proxied connection shows the
    /// proxy's address, which says nothing about the page's.
    static func refusal(connectedTo address: String?, viaProxy: Bool) -> String? {
        guard let address, !viaProxy, FetchRequest.isPrivate(host: address) else { return nil }
        return "The connection went to \(address), which is on this device or a private network, so the page was not read."
    }

    enum Kind {
        case html, text
        /// Why the content is refused, in a sentence.
        case other(String)

        init(contentType: String?) {
            func refused(_ what: String) -> Kind { .other("That address is \(what), not a page of text.") }
            let mime = contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            switch mime {
            case "text/html", "application/xhtml+xml": self = .html
            case "": self = .text
            case _ where mime.hasPrefix("text/") || mime.hasSuffix("json") || mime.hasSuffix("xml"): self = .text
            case "application/pdf": self = refused("a PDF")
            case "application/zip", "application/gzip", "application/x-tar": self = refused("an archive")
            case "application/octet-stream": self = refused("a binary file")
            case _ where mime.hasPrefix("image/"): self = refused("an image")
            case _ where mime.hasPrefix("audio/"): self = refused("audio")
            case _ where mime.hasPrefix("video/"): self = refused("a video")
            default: self = .other("That address is not a page of text (\(mime)).")
            }
        }
    }

    static func decode(_ data: Data, charset: String?) -> String {
        if let charset {
            let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(charset as CFString))
            if encoding != UInt(kCFStringEncodingInvalidId), let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The numeric addresses `host` resolves to, none when it doesn't.
    @Sendable public static func systemResolve(_ host: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var found: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &found) == 0, let first = found else { return continuation.resume(returning: []) }
                defer { freeaddrinfo(first) }
                var addresses: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let info = cursor {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        addresses.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                    }
                    cursor = info.pointee.ai_next
                }
                continuation.resume(returning: addresses)
            }
        }
    }
}

/// Checks every redirect the way the first address was checked. A refused redirect is not followed: the task is
/// cancelled, and `refusal` says why. It also keeps where the connections really went.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let fetcher: PageFetcher
    private let lock = NSLock()
    private var reason: String?

    init(fetcher: PageFetcher) { self.fetcher = fetcher }

    private var connections: [(address: String?, viaProxy: Bool)]?

    var refusal: String? { lock.withLock { reason } }

    /// Why the body must not be returned, judged from where the connections really went. The metrics arrive when the
    /// task ends, so this waits a moment for a download that was cut short.
    func connectionRefusal() async -> String? {
        for _ in 0..<100 {
            if let connections = lock.withLock({ connections }) {
                return connections.lazy.compactMap { PageFetcher.refusal(connectedTo: $0.address, viaProxy: $0.viaProxy) }.first
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let found = metrics.transactionMetrics.map { (address: $0.remoteAddress, viaProxy: $0.isProxyConnection) }
        lock.withLock { connections = found }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url else { return nil }
        if let refused = await fetcher.refusal(for: url) {
            lock.withLock { reason = "The page redirects to an address that can't be fetched. " + refused }
            task.cancel()
            return nil
        }
        var next = request
        next.httpShouldHandleCookies = false
        next.setValue(nil, forHTTPHeaderField: "Authorization")
        return next
    }
}
