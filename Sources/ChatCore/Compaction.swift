import Foundation

/// `/compact` replaces the history the model sees with a summary it writes. Earlier messages stay on screen.
public enum Compaction {
    static let instructions = """
        You compact chat histories. Write a summary that will replace the conversation so far, so the \
        assistant can carry on as if it remembered everything. Keep the user's goals and preferences, facts \
        and numbers, decisions made, code and names that matter, open questions, and anything the assistant \
        promised to do. Keep who each fact is about. Leave out pleasantries and dead ends. Write compact notes in the conversation's \
        language. Reply with only the summary.
        """

    /// What the model is sent: one system message holding the system prompt and the newest summary, then
    /// every message after that summary.
    public static func context(of messages: [ChatMessage], systemPrompt: String) -> [ChatMessage] {
        let start = messages.lastIndex { $0.role == .summary }
        let summary = start.map { "Summary of the conversation so far:\n\n" + messages[$0].content }
        let system = [systemPrompt, summary ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let rest = messages[(start.map { $0 + 1 } ?? 0)...].filter { $0.role != .system }
        return (system.isEmpty ? [] : [ChatMessage(role: .system, content: system)]) + rest
    }

    /// The request that asks the model for a summary of everything it can see, steered by `focus` if given.
    public static func request(for messages: [ChatMessage], focus: String) -> [ChatMessage] {
        let ask = "Summarize the conversation above so the summary can replace it."
            + (focus.isEmpty ? "" : " Make sure it keeps: \(focus)")
        return context(of: messages, systemPrompt: instructions) + [ChatMessage(role: .user, content: ask)]
    }

    /// Whether anything has been said since the last summary.
    public static func hasNewMessages(_ messages: [ChatMessage]) -> Bool {
        let start = messages.lastIndex { $0.role == .summary }.map { $0 + 1 } ?? 0
        return messages[start...].contains { $0.role == .user }
    }
}
