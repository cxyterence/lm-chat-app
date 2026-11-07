import ChatCore
import Foundation
import Observation

/// The reply being streamed. Kept apart from `conversations` so a token only invalidates the bubble that
/// shows it, not every view that reads the conversation list.
@MainActor @Observable
final class LiveReply {
    let messageID: UUID
    var content = ""
    var reasoning = ""

    init(messageID: UUID) { self.messageID = messageID }
}

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
        static let reasoningEffort = "reasoningEffort"
        static let theme = "theme"
        static let apiKey = "apiKey"
    }

    var conversations: [Conversation] = []
    var selection: UUID?
    private(set) var baseURLText: String
    private(set) var apiKey: String
    private(set) var model: String
    private(set) var systemPrompt: String
    private(set) var reasoningEffort: ReasoningEffort?
    private(set) var theme: Theme
    private(set) var models: ModelsState = .idle
    private(set) var generation: Generation = .idle
    private(set) var liveReply: LiveReply?
    private(set) var persistenceError: String?

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let fileURL: URL

    public convenience init() {
        self.init(defaults: .standard, fileURL: ChatStore.defaultFileURL)
    }

    init(defaults: UserDefaults, fileURL: URL, apiKey: String? = nil) {
        self.defaults = defaults
        self.fileURL = fileURL
        baseURLText = defaults.string(forKey: Keys.baseURL) ?? ""
        model = defaults.string(forKey: Keys.model) ?? ""
        systemPrompt = defaults.string(forKey: Keys.systemPrompt) ?? ""
        reasoningEffort = defaults.string(forKey: Keys.reasoningEffort).flatMap(ReasoningEffort.init(rawValue:))
        theme = defaults.string(forKey: Keys.theme).flatMap(Theme.init(rawValue:)) ?? .system
        self.apiKey = apiKey ?? Keychain.get(Keys.apiKey) ?? ""
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

    func setReasoningEffort(_ effort: ReasoningEffort?) {
        reasoningEffort = effort
        if let effort {
            defaults.set(effort.rawValue, forKey: Keys.reasoningEffort)
        } else {
            defaults.removeObject(forKey: Keys.reasoningEffort)
        }
    }

    func setTheme(_ theme: Theme) {
        self.theme = theme
        defaults.set(theme.rawValue, forKey: Keys.theme)
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

        let isFirstPrompt = conversations[index].messages.isEmpty
        if isFirstPrompt {
            conversations[index].title = Conversation.title(fromFirstUserMessage: trimmed)
        }
        conversations[index].model = model
        conversations[index].messages.append(ChatMessage(role: .user, content: trimmed))
        startStreaming(conversationID: id)
        if isFirstPrompt { generateTitle(for: id, prompt: trimmed) }
    }

    /// Runs beside the reply. The first-line title stays if the model gives nothing usable.
    private func generateTitle(for id: UUID, prompt: String) {
        guard let config else { return }
        let client = ChatClient(config: config), model = model
        Task { [weak self] in
            guard let title = try? await client.title(model: model, for: prompt),
                  let self, let index = self.conversations.firstIndex(where: { $0.id == id })
            else { return }
            self.conversations[index].title = title
            self.persist()
        }
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
        liveReply = LiveReply(messageID: assistant.id)

        let stream = ChatClient(config: config).stream(model: model, messages: wire, reasoningEffort: reasoningEffort)
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
        guard let reply = liveReply, reply.messageID == messageID else { return }
        switch event {
        case .content(let text): reply.content += text
        case .reasoning(let text): reply.reasoning += text
        case .done: break
        }
    }

    private func finish(conversationID id: UUID, assistantID: UUID, failure: String?) {
        if let c = conversations.firstIndex(where: { $0.id == id }),
           let m = conversations[c].messages.firstIndex(where: { $0.id == assistantID }) {
            if let reply = liveReply, reply.messageID == assistantID {
                conversations[c].messages[m].content = reply.content
                conversations[c].messages[m].reasoning = reply.reasoning
            }
            let message = conversations[c].messages[m]
            if message.content.isEmpty && message.reasoning.isEmpty {
                conversations[c].messages.remove(at: m)
            }
            conversations[c].updatedAt = Date()
        }
        if liveReply?.messageID == assistantID { liveReply = nil }
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
