import Foundation

/// Names a photo kept in an `ImageStore`. Saved in chats as its UUID string.
public struct ImageID: Hashable, Sendable, Codable {
    public let uuid: UUID

    public init(uuid: UUID = UUID()) { self.uuid = uuid }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        if let uuid = UUID(uuidString: text) {
            self.uuid = uuid
        } else if let jpeg = Data(base64Encoded: text), let store = decoder.userInfo[.imageStore] as? ImageStore {
            // Chats saved by the first photo build held the JPEG inline. Move it into the store.
            self = try store.save(jpeg)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an image ID"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid.uuidString)
    }
}

/// Photos live as files beside the chat file, so saving a chat rewrites only text.
public struct ImageStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func url(for id: ImageID) -> URL {
        directory.appendingPathComponent(id.uuid.uuidString + ".jpg")
    }

    public func save(_ jpeg: Data) throws -> ImageID {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = ImageID()
        try jpeg.write(to: url(for: id), options: .atomic)
        return id
    }

    public func data(for id: ImageID) -> Data? { try? Data(contentsOf: url(for: id)) }

    public func remove(_ ids: some Sequence<ImageID>) {
        for id in ids { try? FileManager.default.removeItem(at: url(for: id)) }
    }

    /// Deletes every photo no chat refers to, such as ones picked but never sent.
    public func removeAll(except keep: Set<ImageID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent).map { ImageID(uuid: $0) }
            if id.map(keep.contains) != true { try? FileManager.default.removeItem(at: file) }
        }
    }
}

extension CodingUserInfoKey {
    static let imageStore = CodingUserInfoKey(rawValue: "imageStore")!
}
