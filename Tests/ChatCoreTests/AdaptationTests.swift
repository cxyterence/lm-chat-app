import Foundation
import Testing
@testable import ChatCore

struct AdaptationTests {
    @Test(arguments: [
        (Adaptation.toolsDropped(reason: "tools unsupported"), "Sent without tools. The server refused them."),
        (.reasoningOffForTools, "Reasoning turned off so tools work on this model."),
        (.effortChanged(from: .high, to: .medium), "Reasoning effort medium. high isn't supported."),
        (.effortChanged(from: .xhigh, to: nil), "Reasoning effort left out. xhigh isn't supported."),
        (.imageSize("1024x576", fromImage: 1), "Size 1024x576, from image 1."),
        (.imageSize("1024x1024", fromImage: nil), "Size 1024x1024."),
        (.usageNotRequested, "Sent without token counts. The server refused them."),
    ])
    func eachSaysWhatChangedInOneLine(adaptation: Adaptation, note: String) {
        #expect(adaptation.note == note)
        #expect(!adaptation.note.contains("\n"))
    }

    @Test func aMessageKeepsItsAdaptationsThroughASave() throws {
        let adaptations: [Adaptation] = [.toolsDropped(reason: "no"), .reasoningOffForTools, .effortChanged(from: .max, to: .none),
                                         .imageSize("512x512", fromImage: 2), .usageNotRequested]
        let message = ChatMessage(role: .assistant, content: "ok", adaptations: adaptations, createdAt: date(5))
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded == message)
        #expect(decoded.adaptations == adaptations)
    }

    @Test func aSaveFromBeforeAdaptationsStillOpens() throws {
        let id = UUID().uuidString
        let old = #"{"id":"\#(id)","role":"assistant","content":"hi","reasoning":"","createdAt":1700000000}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: bytes(old))
        #expect(message.adaptations.isEmpty)
        #expect(message.content == "hi")
    }

    @Test func aWholeOldChatFileOpens() throws {
        let (url, cleanup) = makeTempFileURL("conversations.json")
        defer { cleanup() }
        let id = UUID().uuidString
        try write(#"[{"id":"\#(id)","title":"Old","messages":[{"id":"\#(UUID().uuidString)","role":"user","content":"hi","reasoning":"","createdAt":"2023-11-14T22:13:20Z"}],"updatedAt":"2023-11-14T22:13:21Z"}]"#, to: url)
        let loaded = try ConversationStore.load(from: url)
        #expect(loaded.first?.messages.first?.adaptations.isEmpty == true)
    }
}
