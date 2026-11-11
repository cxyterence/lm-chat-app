import Foundation

/// One saved server. The API key isn't stored here: it lives in `Secrets` under `secretAccount`.
struct Connection: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var baseURL: URL
    /// The model last picked while this connection was active, so switching back restores it.
    var model = ""
    var systemPrompt = ""
    /// Whether `model` answers with pictures. Saved so the app knows before the server's model list loads.
    var makesImages = false

    var secretAccount: String { "connection.\(id.uuidString)" }

    /// Host and port, enough to tell two servers on one machine apart.
    static func address(of url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

extension Connection {
    /// Connections saved before image models have no `makesImages`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(URL.self, forKey: .baseURL)
        model = try c.decode(String.self, forKey: .model)
        systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        makesImages = try c.decodeIfPresent(Bool.self, forKey: .makesImages) ?? false
    }
}

/// Where API keys are kept. The Keychain in the app, a dictionary in tests and snapshots.
struct Secrets {
    var get: (String) -> String?
    var set: (String, String) -> Void

    static var keychain: Secrets { Secrets(get: Keychain.get, set: { Keychain.set($1, for: $0) }) }

    static func memory() -> Secrets {
        final class Box { var values: [String: String] = [:] }
        let box = Box()
        return Secrets(get: { box.values[$0] }, set: { box.values[$0] = $1.isEmpty ? nil : $1 })
    }
}
