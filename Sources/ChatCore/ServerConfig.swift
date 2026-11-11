import Foundation

/// A model the server offers, and whether it answers with pictures in place of text.
public struct ServedModel: Equatable, Sendable {
    public let id: String
    public let makesImages: Bool

    public init(id: String, makesImages: Bool = false) {
        self.id = id
        self.makesImages = makesImages
    }
}

public struct ServerConfig: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var apiKey: String?

    public init(baseURL: URL, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case invalid
        case unsupportedScheme(String)

        public var errorDescription: String? {
            switch self {
            case .empty: "Enter a server address."
            case .invalid: "That doesn't look like a valid address."
            case .unsupportedScheme(let s): "Unsupported scheme \"\(s)\". Use http or https."
            }
        }
    }

    public static func parse(baseURL: String, apiKey: String) throws -> ServerConfig {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty, !host.contains(" ")
        else { throw ParseError.invalid }

        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { throw ParseError.unsupportedScheme(scheme) }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path.isEmpty ? "/v1" : path
        components.query = nil
        components.fragment = nil

        guard let url = components.url else { throw ParseError.invalid }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return ServerConfig(baseURL: url, apiKey: key.isEmpty ? nil : key)
    }
}
