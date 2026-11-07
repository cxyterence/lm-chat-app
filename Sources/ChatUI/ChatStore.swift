import ChatCore
import Foundation
import Observation

@MainActor @Observable
public final class ChatStore {
    enum Generation {
        case idle
        case streaming(conversationID: UUID, task: Task<Void, Never>)
        case failed(conversationID: UUID, message: String)
    }

    enum ModelsState: Equatable {
        case idle
        case loading
        case loaded([String])
        case failed(String)
    }

    private enum Keys {
        static let baseURL = "baseURL"
        static let model = "model"
        static let systemPrompt = "systemPrompt"
        static let apiKey = "apiKey"
    }

    var conversations: [Conversation] = []
    var selection: UUID?
    private(set) var baseURLText: String
    private(set) var apiKey: String
    private(set) var model: String
    private(set) var systemPrompt: String
    private(set) var models: ModelsState = .idle
    private(set) var generation: Generation = .idle
    private(set) var persistenceError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fileURL: URL

    public init(defaults: UserDefaults = .standard, fileURL: URL = ChatStore.defaultFileURL) {
        self.defaults = defaults
        self.fileURL = fileURL
        baseURLText = defaults.string(forKey: Keys.baseURL) ?? ""
        model = defaults.string(forKey: Keys.model) ?? ""
        systemPrompt = defaults.string(forKey: Keys.systemPrompt) ?? ""
        apiKey = Keychain.get(Keys.apiKey) ?? ""
        do {
            conversations = try ConversationStore.load(from: fileURL)
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            persistenceError = "Couldn't load saved chats: \(error.localizedDescription)"
        }
        selection = conversations.first?.id
    }

    public static var defaultFileURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LMChat/conversations.json")
    }

    // MARK: Server and settings

    var config: ServerConfig? {
        try? ServerConfig.parse(baseURL: baseURLText, apiKey: apiKey)
    }

    var isConfigured: Bool { config != nil }

    var availableModels: [String] {
        if case .loaded(let ids) = models { return ids }
        return []
    }

    func applyServer(baseURL: String, apiKey: String) throws {
        let parsed = try ServerConfig.parse(baseURL: baseURL, apiKey: apiKey)
        baseURLText = parsed.baseURL.absoluteString
        self.apiKey = parsed.apiKey ?? ""
        defaults.set(baseURLText, forKey: Keys.baseURL)
        Keychain.set(self.apiKey, for: Keys.apiKey)
    }

    func updatePreferences(model: String? = nil, systemPrompt: String? = nil) {
        if let model {
            self.model = model
            defaults.set(model, forKey: Keys.model)
        }
        if let systemPrompt {
            self.systemPrompt = systemPrompt
            defaults.set(systemPrompt, forKey: Keys.systemPrompt)
        }
    }

    func refreshModels() async {
        guard let config else {
            models = .idle
            return
        }
        models = .loading
        do {
            let ids = try await ChatClient(config: config).models()
            models = .loaded(ids)
            if !ids.contains(model), let first = ids.first {
                updatePreferences(model: first)
            }
        } catch {
            models = .failed(error.localizedDescription)
        }
    }

    // MARK: Conversations

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selection }
    }

    func newConversation() {
        if let empty = conversations.first(where: { $0.messages.isEmpty }) {
            selection = empty.id
            return
        }
        let conversation = Conversation(model: model.isEmpty ? nil : model)
        conversations.insert(conversation, at: 0)
        selection = conversation.id
    }

    func delete(ids: [UUID]) {
        for id in ids where isStreaming(id) { stop() }
        conversations.removeAll { ids.contains($0.id) }
        if let selection, !conversations.contains(where: { $0.id == selection }) {
            self.selection = conversations.first?.id
        }
        persist()
    }

    // MARK: Generation

    func isStreaming(_ id: UUID) -> Bool {
        if case .streaming(let streamingID, _) = generation { return streamingID == id }
        return false
    }

    var isBusy: Bool {
        if case .streaming = generation { return true }
        return false
    }

    func failureMessage(for id: UUID) -> String? {
        if case .failed(let failedID, let message) = generation, failedID == id { return message }
        return nil
    }

    var canSend: Bool { isConfigured && !model.isEmpty && !isBusy }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canSend else { return }

        if selectedConversation == nil { newConversation() }
        guard let id = selection, let index = conversations.firstIndex(where: { $0.id == id }) else { return }

        if conversations[index].messages.isEmpty {
            conversations[index].title = Conversation.title(fromFirstUserMessage: trimmed)
        }
        conversations[index].model = model
        conversations[index].messages.append(ChatMessage(role: .user, content: trimmed))
        startStreaming(conversationID: id)
    }

    func stop() {
        if case .streaming(_, let task) = generation { task.cancel() }
    }

    func retry() {
        guard case .failed(let id, _) = generation, let index = conversations.firstIndex(where: { $0.id == id }),
              let lastUser = conversations[index].messages.lastIndex(where: { $0.role == .user })
        else { return }
        conversations[index].messages.removeSubrange((lastUser + 1)...)
        startStreaming(conversationID: id)
    }

    func dismissFailure() {
        if case .failed = generation { generation = .idle }
    }

    private func startStreaming(conversationID id: UUID) {
        guard let config, let index = conversations.firstIndex(where: { $0.id == id }) else { return }

        var wire = conversations[index].messages
        if !systemPrompt.isEmpty {
            wire.insert(ChatMessage(role: .system, content: systemPrompt), at: 0)
        }
        let assistant = ChatMessage(role: .assistant, content: "")
        conversations[index].messages.append(assistant)
        conversations[index].updatedAt = Date()

        let stream = ChatClient(config: config).stream(model: model, messages: wire)
        let task = Task { [weak self] in
            var failure: String?
            do {
                for try await event in stream {
                    self?.apply(event, to: assistant.id, in: id)
                }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
            self?.finish(conversationID: id, assistantID: assistant.id, failure: failure)
        }
        generation = .streaming(conversationID: id, task: task)
    }

    private func apply(_ event: StreamEvent, to messageID: UUID, in conversationID: UUID) {
        guard let c = conversations.firstIndex(where: { $0.id == conversationID }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        switch event {
        case .content(let text): conversations[c].messages[m].content += text
        case .reasoning(let text): conversations[c].messages[m].reasoning += text
        case .done: break
        }
    }

    private func finish(conversationID id: UUID, assistantID: UUID, failure: String?) {
        if let c = conversations.firstIndex(where: { $0.id == id }),
           let m = conversations[c].messages.firstIndex(where: { $0.id == assistantID }) {
            let message = conversations[c].messages[m]
            if message.content.isEmpty && message.reasoning.isEmpty {
                conversations[c].messages.remove(at: m)
            }
            conversations[c].updatedAt = Date()
        }
        generation = failure.map { .failed(conversationID: id, message: $0) } ?? .idle
        persist()
    }

    private func persist() {
        do {
            try ConversationStore.save(conversations, to: fileURL)
            persistenceError = nil
        } catch {
            persistenceError = "Couldn't save chats: \(error.localizedDescription)"
        }
    }
}
