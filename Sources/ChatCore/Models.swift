import Foundation

public enum Role: String, Codable, Sendable {
    case system, user, assistant
    /// A `/compact` summary standing in for everything before it. Never sent as is: `Compaction.context`
    /// folds it into the system message.
    case summary
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var role: Role
    public var content: String
    public var reasoning: String
    /// Photos sent to the model alongside `content`.
    public var images: [ImageID]
    /// Set on a user message sent with `/web-search`.
    public var search: WebSearch?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        reasoning: String = "",
        images: [ImageID] = [],
        search: WebSearch? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.images = images
        self.search = search
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        reasoning = try c.decode(String.self, forKey: .reasoning)
        images = try c.decodeIfPresent([ImageID].self, forKey: .images) ?? []
        search = try c.decodeIfPresent(WebSearch.self, forKey: .search)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
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
