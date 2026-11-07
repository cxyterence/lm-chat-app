import Foundation

public enum ConversationStore {
    public static func load(from url: URL) throws -> [Conversation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([Conversation].self, from: Data(contentsOf: url))
    }

    public static func save(_ conversations: [Conversation], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(conversations).write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
