/// A command typed at the start of the composer, like `/compact`.
public enum SlashCommand: String, CaseIterable, Sendable {
    case compact

    public var name: String { "/" + rawValue }

    public var argumentHint: String {
        switch self {
        case .compact: "[what to keep]"
        }
    }

    public var summary: String {
        switch self {
        case .compact: "Summarize the chat so far to free up the model's context"
        }
    }

    /// The command a draft runs and the text after its name. nil for an ordinary message, including one that
    /// starts with a slash but names no command, so "/etc/hosts is missing" still reaches the model.
    public static func parse(_ text: String) -> (command: SlashCommand, argument: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let name = trimmed.dropFirst().prefix { !$0.isWhitespace }
        guard let command = SlashCommand(rawValue: name.lowercased()) else { return nil }
        let argument = trimmed.dropFirst(1 + name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, argument)
    }

    /// While the name is still being typed, every command it could become. After it, the command it names.
    public static func suggestions(for draft: String) -> [SlashCommand] {
        guard draft.hasPrefix("/") else { return [] }
        let typed = draft.dropFirst()
        if typed.contains(where: \.isWhitespace) { return parse(draft).map { [$0.command] } ?? [] }
        return allCases.filter { $0.rawValue.hasPrefix(typed.lowercased()) }
    }
}
