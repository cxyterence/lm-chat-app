import Foundation

public enum ChatTitle {
    static func messages(for prompt: String) -> [ChatMessage] {
        [
            ChatMessage(role: .system, content: """
                You name chat conversations. Reply with only a title of 2 to 6 words that says what the \
                conversation is about. No quotes, no "Title:" prefix, no trailing punctuation.
                """),
            ChatMessage(role: .user, content: "Name the conversation that starts with this message:\n\n\(prompt.prefix(2000))"),
        ]
    }

    /// Models decorate titles despite instructions, so keep the first line and strip labels, quotes and markup.
    public static func clean(_ raw: String, limit: Int = 60) -> String? {
        guard var line = raw.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        if let label = line.range(of: #"^[*_#\s]*title[*_]*\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            line.removeSubrange(label)
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*_`\"'“”‘’").union(.whitespaces))
        while let last = line.last, ".:;,".contains(last) { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        guard line.count > limit else { return line }
        return String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension ChatClient {
    /// Titles don't need deep reasoning, so ask for low effort first and retry without it when the server rejects the field.
    public func title(model: String, for prompt: String) async throws -> String? {
        do {
            return try await titleAttempt(model: model, prompt: prompt, effort: .low)
        } catch ChatClientError.http(400, _) {
            return try await titleAttempt(model: model, prompt: prompt, effort: nil)
        }
    }

    private func titleAttempt(model: String, prompt: String, effort: ReasoningEffort?) async throws -> String? {
        var text = ""
        for try await event in stream(model: model, messages: ChatTitle.messages(for: prompt), reasoningEffort: effort, includeUsage: false, purpose: .title) {
            guard case .content(let chunk) = event else { continue }
            text += chunk
            if text.count > 400 { break }
        }
        return ChatTitle.clean(text)
    }
}
