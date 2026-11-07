import Foundation

public enum Role: String, Codable, Sendable {
    case system, user, assistant
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var role: Role
    public var content: String
    public var reasoning: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        reasoning: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.createdAt = createdAt
    }
}

public struct Conversation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var model: String?
    public var messages: [ChatMessage]
    public var updatedAt: Date

    public static let placeholderTitle = "New Chat"

    public init(
        id: UUID = UUID(),
        title: String = Conversation.placeholderTitle,
        model: String? = nil,
        messages: [ChatMessage] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.model = model
        self.messages = messages
        self.updatedAt = updatedAt
    }

    public static func title(fromFirstUserMessage text: String, limit: Int = 40) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard !firstLine.isEmpty else { return placeholderTitle }
        guard firstLine.count > limit else { return firstLine }
        return String(firstLine.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
