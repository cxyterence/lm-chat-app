import Foundation

/// What a model asked `fetch_url` for, decoded from the tool call's JSON arguments. The address is checked here,
/// because a page the model fetched earlier may be trying to send it somewhere it should not go.
public struct FetchRequest: Equatable, Sendable {
    /// A message for the model that made the call, which relays it to the user or tries another address.
    public struct Invalid: Error, Equatable, LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public static let toolName = "fetch_url"

    public let url: URL

    public init(address: String) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            throw Invalid("That isn't a web address. Give the whole address, such as https://example.com/page.")
        }
        if let reason = Self.refusal(for: url) { throw Invalid(reason) }
        self.url = url
    }

    public static func parse(arguments: String) throws -> FetchRequest {
        guard let address = address(in: arguments) else {
            throw Invalid("The arguments must be a JSON object with a url, such as {\"url\": \"https://example.com\"}.")
        }
        return try FetchRequest(address: address)
    }

    /// The `url` in a call's arguments, whether or not it passes the checks, for showing where a call went.
    public static func address(in arguments: String) -> String? {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)))?["url"]?.string
    }

    /// Why `url` can't be fetched, judged from the address alone. Nil when it can.
    public static func refusal(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "Only http and https addresses can be fetched."
        }
        guard url.user() == nil, url.password() == nil else {
            return "Addresses that contain a user name or password can't be fetched."
        }
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return "That address has no host name."
        }
        return isPrivate(host: host) ? "\(host) is on this device or a private network, so it can't be fetched." : nil
    }

    /// Whether the user wrote the host of `url` in one of `texts`, as a word of its own. A fetch of such an address is
    /// the user's own request. A page can ask for any other address, such as one that carries their chat in its query.
    public static func isNamed(_ url: URL, in texts: [String]) -> Bool {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return false }
        while host.hasSuffix(".") { host.removeLast() }
        return texts.contains { text in
            text.lowercased()
                .split { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
                .contains { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-")) == host }
        }
    }

    /// A name or numeric address that points at this device or a private network. IPv4 is read the way
    /// `getaddrinfo` reads it, so `2130706433`, `0x7f000001` and `127.1` count as 127.0.0.1.
    static func isPrivate(host raw: String) -> Bool {
        var host = raw
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }

        if host == "localhost" || [".localhost", ".local", ".internal"].contains(where: host.hasSuffix) { return true }

        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 { return isPrivate(v4: UInt32(bigEndian: v4.s_addr)) }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes.allSatisfy({ $0 == 0 }) || bytes[0] == 0xFF { return true }
        // Unique local (fc00::/7), and link-local (fe80::/10) with the deprecated site-local (fec0::/10).
        if bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 >= 0x80) { return true }
        // Local-use NAT64 (64:ff9b:1::/48) is meant for a private network.
        if bytes[..<6] == [0, 0x64, 0xFF, 0x9B, 0, 1] { return true }
        // IPv4 carried inside IPv6: mapped (::ffff:a.b.c.d), compatible (::a.b.c.d), translated (::ffff:0:a.b.c.d),
        // NAT64 (64:ff9b::a.b.c.d) and 6to4 (2002:a.b.c.d::).
        let embedded = bytes[12...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let leadingZeros = bytes[..<10].allSatisfy { $0 == 0 }
        if leadingZeros && (bytes[10...11] == [0xFF, 0xFF] || bytes[10...11] == [0, 0]) { return isPrivate(v4: embedded) }
        if bytes[..<8].allSatisfy({ $0 == 0 }) && bytes[8...11] == [0xFF, 0xFF, 0, 0] { return isPrivate(v4: embedded) }
        if bytes[..<12] == [0, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0] { return isPrivate(v4: embedded) }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return isPrivate(v4: bytes[2...5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) }
        return false
    }

    private static func isPrivate(v4 address: UInt32) -> Bool {
        let (a, b) = (address >> 24, address >> 16 & 0xFF)
        // 100.64.0.0/10 is carrier-grade NAT, which Tailscale also uses for its devices.
        return a == 0 || a == 10 || a == 127 || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254)
            || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
    }
}

extension FetchRequest {
    /// The tool as the model sees it. `parse(arguments:)` reads what it sends back.
    public static let toolSpec = ToolSpec(
        name: toolName,
        description: """
            Fetches a web page and returns its text. Call it when the user gives a link, or asks about the \
            contents of a page you can't already see. Only public http and https addresses work. \
            Long pages are cut off, and pages that need a login or JavaScript to show their text come back empty.
            """,
        parameters: try! JSONDecoder().decode(JSONValue.self, from: Data("""
            {"type": "object",
             "properties": {
               "url": {"type": "string", "description": "The full address of the page, such as https://example.com/page."}
             },
             "required": ["url"]}
            """.utf8))
    )
}
