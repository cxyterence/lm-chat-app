import Foundation

/// How the model refers to a chat's pictures. Every picture in the conversation, the user's photos and the
/// ones the image tool drew alike, is "image 1", "image 2" and so on in message order.
public enum ImageLabels {
    /// The pictures in label order: label N is index N - 1. Numbered over the whole conversation, so a label
    /// keeps its number after `/compact` drops the messages that carried it from what the model sees.
    public static func order(of messages: [ChatMessage]) -> [ImageID] {
        messages.flatMap(\.images)
    }

    /// `messages` as the model should read them: each user message with photos ends with a note naming them.
    /// The stored messages stay as typed.
    public static func annotated(_ messages: [ChatMessage], order: [ImageID]) -> [ChatMessage] {
        messages.map { message in
            let labels = message.images.compactMap { order.firstIndex(of: $0) }.map { "image \($0 + 1)" }
            guard message.role == .user, !labels.isEmpty else { return message }
            var noted = message
            // A /web-search question is sent as its prompt, so the note goes after that.
            let text = message.search?.prompt ?? message.content
            noted.content = (text.isEmpty ? "" : text + "\n\n") + "(Attached: \(labels.joined(separator: ", ")))"
            noted.search = nil
            return noted
        }
    }
}
