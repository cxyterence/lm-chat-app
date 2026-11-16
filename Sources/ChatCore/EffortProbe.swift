import Foundation

extension ChatClient {
    /// The levels the server accepts for `model`, least thinking first, found by sending a one-token request
    /// per level. Empty when the server also accepts a made-up level, since it then isn't reading the field.
    /// Only an error about the effort field rejects a level. OpenAI answers a supported level with a 400 too,
    /// because one token is too few for a reasoning model to finish.
    public func reasoningEfforts(model: String) async throws -> [ReasoningEffort] {
        let decoy = "lmchat-probe"
        let accepted = try await withThrowingTaskGroup(of: (String, Bool).self) { group in
            for value in ReasoningEffort.allCases.map(\.rawValue) + [decoy] {
                group.addTask { (value, try await accepts(model: model, effort: value)) }
            }
            return try await group.reduce(into: Set<String>()) { if $1.1 { $0.insert($1.0) } }
        }
        guard !accepted.contains(decoy) else { return [] }
        return ReasoningEffort.allCases.filter { accepted.contains($0.rawValue) }
    }

    private func accepts(model: String, effort: String) async throws -> Bool {
        let reply = try await probe(WireProbeRequest(model: model, reasoningEffort: effort))
        switch reply.status {
        case 200..<300: return true
        case 400, 422:
            let body = reply.text.lowercased()
            return !(body.contains("reasoning_effort") || body.contains("reasoning effort"))
        default: throw reply.error
        }
    }

    /// Sends a one-token request. Any status comes back as a reply, for the caller to read.
    func probe(_ body: WireProbeRequest) async throws -> ProbeReply {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, http) = try await perform(request, purpose: .probe)
        return ProbeReply(status: http.statusCode, data: data)
    }
}

struct ProbeReply {
    let status: Int
    let data: Data

    var text: String { String(decoding: data, as: UTF8.self) }
    var error: ChatClientError { ChatClient.httpError(status: status, body: data) }

    /// The server's own words, without the status.
    var message: String {
        if case .http(_, let message) = error { message } else { text }
    }
}
