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

    /// The effort levels the selected model accepts, as the server reported them.
    enum EffortLevels: Equatable {
        case checking
        case known([ReasoningEffort])
        case failed
    }

    private enum Keys {
        static let connections = "connections"
        static let activeConnection = "activeConnection"
        static let reasoningEffort = "reasoningEffort"
        static let theme = "theme"
    }

    /// Settings from before connections existed, read once to build the first connection.
    private enum LegacyKeys {
        static let baseURL = "baseURL"
        static let model = "model"
        static let systemPrompt = "systemPrompt"
        static let apiKey = "apiKey"
    }

    var conversations: [Conversation] = []
    var selection: UUID?
    private(set) var connections: [Connection] = []
    private(set) var activeConnectionID: UUID?
    private var apiKeys: [UUID: String] = [:]
    private var preferredEffort: ReasoningEffort?
    private(set) var effortLevels: EffortLevels = .checking
    private(set) var theme: Theme
    private(set) var models: ModelsState = .idle
    private(set) var generation: Generation = .idle
    private(set) var liveReply: LiveReply?
    private(set) var persistenceError: String?

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let secrets: Secrets
    @ObservationIgnored private var effortCheck: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL

    public convenience init() {
        self.init(defaults: .standard, fileURL: ChatStore.defaultFileURL, secrets: .keychain)
    }

    init(defaults: UserDefaults, fileURL: URL, secrets: Secrets) {
        self.defaults = defaults
        self.fileURL = fileURL
        self.secrets = secrets
        preferredEffort = defaults.string(forKey: Keys.reasoningEffort).flatMap(ReasoningEffort.init(rawValue:))
        theme = defaults.string(forKey: Keys.theme).flatMap(Theme.init(rawValue:)) ?? .system
        loadConnections()
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

    var activeConnection: Connection? {
        connections.first { $0.id == activeConnectionID }
    }

    var config: ServerConfig? {
        activeConnection.map { ServerConfig(baseURL: $0.baseURL, apiKey: apiKeys[$0.id]) }
    }

    var model: String { activeConnection?.model ?? "" }
    var systemPrompt: String { activeConnection?.systemPrompt ?? "" }

    func apiKey(for id: UUID) -> String { apiKeys[id] ?? "" }

    var isConfigured: Bool { config != nil }

    var availableModels: [String] {
        if case .loaded(let ids) = models { return ids }
        return []
    }

    /// Adds a new connection or replaces the one with the same ID. A new one becomes active.
    func saveConnection(_ connection: Connection, apiKey: String) {
        let isNew = !connections.contains { $0.id == connection.id }
        if isNew {
            connections.append(connection)
        } else {
            connections = connections.map { $0.id == connection.id ? connection : $0 }
        }
        apiKeys[connection.id] = apiKey.isEmpty ? nil : apiKey
        secrets.set(connection.secretAccount, apiKey)
        persistConnections()
        if isNew || connection.id == activeConnectionID { activate(connection.id) }
    }

    func deleteConnection(_ id: UUID) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        connections.removeAll { $0.id == id }
        apiKeys[id] = nil
        secrets.set(connection.secretAccount, "")
        persistConnections()
        if activeConnectionID == id {
            if let next = connections.first { activate(next.id) } else { activate(nil) }
        }
    }

    func activate(_ id: UUID?) {
        activeConnectionID = id
        defaults.set(id?.uuidString, forKey: Keys.activeConnection)
        models = .idle
        Task { await refreshModels() }
    }

    func selectModel(_ model: String) {
        guard let index = connections.firstIndex(where: { $0.id == activeConnectionID }),
              connections[index].model != model else { return }
        connections[index].model = model
        persistConnections()
        checkEffortLevels()
    }

    private func persistConnections() {
        defaults.set(try? JSONEncoder().encode(connections), forKey: Keys.connections)
    }

    private func loadConnections() {
        if let data = defaults.data(forKey: Keys.connections),
           let saved = try? JSONDecoder().decode([Connection].self, from: data) {
            connections = saved
            activeConnectionID = defaults.string(forKey: Keys.activeConnection).flatMap(UUID.init(uuidString:))
                .flatMap { id in saved.contains { $0.id == id } ? id : nil } ?? saved.first?.id
        } else if let url = defaults.string(forKey: LegacyKeys.baseURL),
                  let parsed = try? ServerConfig.parse(baseURL: url, apiKey: "") {
            let connection = Connection(name: Connection.address(of: parsed.baseURL), baseURL: parsed.baseURL,
                                        model: defaults.string(forKey: LegacyKeys.model) ?? "",
                                        systemPrompt: defaults.string(forKey: LegacyKeys.systemPrompt) ?? "")
            let key = secrets.get(LegacyKeys.apiKey) ?? ""
            connections = [connection]
            activeConnectionID = connection.id
            secrets.set(connection.secretAccount, key)
            persistConnections()
            defaults.set(connection.id.uuidString, forKey: Keys.activeConnection)
            for legacy in [LegacyKeys.baseURL, LegacyKeys.model, LegacyKeys.systemPrompt] { defaults.removeObject(forKey: legacy) }
            secrets.set(LegacyKeys.apiKey, "")
        }
        for connection in connections {
            apiKeys[connection.id] = secrets.get(connection.secretAccount)
        }
    }

    /// What a request sends. Until the levels are known it's the saved choice, which the server accepted before.
    var reasoningEffort: ReasoningEffort? {
        guard case .known(let levels) = effortLevels else { return preferredEffort }
        return ReasoningEffort.choice(preferred: preferredEffort, supported: levels)
    }

    func setReasoningEffort(_ effort: ReasoningEffort) {
        preferredEffort = effort
        defaults.set(effort.rawValue, forKey: Keys.reasoningEffort)
    }

    func checkEffortLevels() {
        effortCheck?.cancel()
        guard let config, !model.isEmpty else {
            effortLevels = .failed
            return
        }
        let model = model
        effortLevels = .checking
        effortCheck = Task {
            let result: EffortLevels
            do {
                result = .known(try await ChatClient(config: config).reasoningEfforts(model: model))
            } catch {
                result = .failed
            }
            guard !Task.isCancelled, model == self.model else { return }
            effortLevels = result
        }
    }

    func setTheme(_ theme: Theme) {
        self.theme = theme
        defaults.set(theme.rawValue, forKey: Keys.theme)
    }

    func refreshModels() async {
        guard let config, let connectionID = activeConnectionID else {
            models = .idle
            effortLevels = .failed
            return
        }
        models = .loading
        do {
            let ids = try await ChatClient(config: config).models()
            guard connectionID == activeConnectionID else { return }
            models = .loaded(ids)
            if !ids.contains(model), let first = ids.first {
                selectModel(first)
            } else {
                checkEffortLevels()
            }
        } catch {
            guard connectionID == activeConnectionID else { return }
            models = .failed(error.localizedDescription)
            effortLevels = .failed
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

    func send(_ text: String, images: [Data] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty, canSend else { return }

        if selectedConversation == nil { newConversation() }
        guard let id = selection, let index = conversations.firstIndex(where: { $0.id == id }) else { return }

        let isFirstPrompt = conversations[index].messages.isEmpty
        if isFirstPrompt {
            conversations[index].title = trimmed.isEmpty ? "Photo" : Conversation.title(fromFirstUserMessage: trimmed)
        }
        conversations[index].model = model
        conversations[index].messages.append(ChatMessage(role: .user, content: trimmed, images: images))
        startStreaming(conversationID: id)
        if isFirstPrompt && !trimmed.isEmpty { generateTitle(for: id, prompt: trimmed) }
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
