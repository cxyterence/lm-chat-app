import ChatCore
import Testing
@testable import ChatUI

@MainActor
struct PhotoStorageTests {
    @Test func deletingAChatDeletesItsPhotos() throws {
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }
        let store = ChatStore(defaults: defaults, fileURL: file, secrets: .memory())
        let mine = try store.images.save(bytes("mine")), other = try store.images.save(bytes("other"))
        let doomed = Conversation(messages: [ChatMessage(role: .user, content: "", images: [mine])])
        let kept = Conversation(messages: [ChatMessage(role: .user, content: "", images: [other])])
        store.conversations = [doomed, kept]

        store.delete(ids: [doomed.id])
        #expect(store.images.data(for: mine) == nil)
        #expect(store.images.data(for: other) != nil)
    }

    @Test func launchSweepsPhotosNoChatUses() throws {
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }
        let first = ChatStore(defaults: defaults, fileURL: file, secrets: .memory())
        let sent = try first.images.save(bytes("sent")), unsent = try first.images.save(bytes("picked, never sent"))
        try ConversationStore.save([Conversation(messages: [ChatMessage(role: .user, content: "", images: [sent])])], to: file)

        let second = ChatStore(defaults: defaults, fileURL: file, secrets: .memory())
        #expect(second.images.data(for: sent) != nil)
        #expect(second.images.data(for: unsent) == nil)
    }
}
