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
    /// What the reply is waiting on before any text arrives, like a web search.
    var status: String?
    var toolCalls: [ToolCall] = []

    init(messageID: UUID) { self.messageID = messageID }
}

@MainActor @Observable
public final class ChatStore {
    /// What a stream produces, kept with a failure so Retry asks for the same thing.
    enum Request: Equatable {
        case reply
        case compact(focus: String)
    }

    enum Generation {
        case idle
        case streaming(conversationID: UUID, task: Task<Void, Never>)
        case failed(conversationID: UUID, message: String, request: Request)
    }

    private enum Outcome: Equatable {
        case completed, cancelled
        case failed(String)
    }

    struct CapabilityKey: Hashable {
        let connection: UUID
        let model: String
    }

    enum CapabilityCheck: Equatable {
        case running
        case failed(String)
        case done(CapabilityReport)
    }

    enum ModelsState: Equatable {
        case idle
        case loading
        case loaded([ServedModel])
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
        /// Points `/web-search` somewhere other than serper.dev, for testing against a local mock.
        static let serperURL = "serperURL"
        static let mcpServers = "mcpServers"
        static let imageTool = "imageTool"
        static let fetchPages = "fetchPages"
    }

    /// Rounds of tool use one reply may take before it must answer with what it has.
    static let maxToolRounds = 10

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
    private var serviceKeys: [APIService: String] = [:]
    private var preferredEffort: ReasoningEffort?
    private(set) var effortLevels: EffortLevels = .checking
    private(set) var theme: Theme
    private(set) var models: ModelsState = .idle
    private(set) var generation: Generation = .idle
    private(set) var liveReply: LiveReply?
    private(set) var persistenceError: String?
    /// The requests made for each reply, for the inspector. Memory only.
    private(set) var exchangeLog = ExchangeLog()
    /// A reply that failed before it showed anything has no message to hang its requests on. They are kept under
    /// this ID, for the failure banner's Inspect, until the failure is dismissed or the reply is asked for again.
    private(set) var failedReply: UUID?
    /// What Check Model found, per connection and model. Memory only.
    private(set) var capabilityChecks: [CapabilityKey: CapabilityCheck] = [:]
    private(set) var mcpServers: [MCPServer] = []
    private(set) var mcpStatus: [UUID: MCPStatus] = [:]
    private var savedImageTool: ImageTool?
    /// Whether `fetch_url` is offered with every reply. Off until the user turns it on.
    private(set) var fetchesPages: Bool
    /// The tool call waiting for the user to allow or decline it.
    private(set) var awaitingApproval: String?

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let secrets: Secrets
    @ObservationIgnored private var effortCheck: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored let images: ImageStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let pages: PageFetcher
    @ObservationIgnored private var mcpClients: [UUID: MCPClient] = [:]
    @ObservationIgnored private var mcpTokens: [UUID: String] = [:]
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?
    /// Models whose server refused a request carrying tools, with why. They're asked without tools from then on.
    @ObservationIgnored private var toolless: [String: String] = [:]
    /// Models whose server takes tools only with reasoning off, as OpenAI's gpt-6-luna does.
    @ObservationIgnored private var toolsNeedNoReasoning: Set<String> = []
    /// Servers (host and port) that refused `stream_options`, so their requests don't ask for token counts.
    @ObservationIgnored private var withoutUsage: Set<String> = []

    public convenience init() {
        self.init(defaults: .standard, fileURL: ChatStore.defaultFileURL, secrets: .keychain)
    }

    init(defaults: UserDefaults, fileURL: URL, secrets: Secrets, session: URLSession = .shared, pages: PageFetcher = PageFetcher()) {
        self.defaults = defaults
        self.fileURL = fileURL
        self.secrets = secrets
        self.session = session
        self.pages = pages
        fetchesPages = defaults.bool(forKey: Keys.fetchPages)
        images = ImageStore(directory: fileURL.deletingLastPathComponent().appendingPathComponent("images"))
        preferredEffort = defaults.string(forKey: Keys.reasoningEffort).flatMap(ReasoningEffort.init(rawValue:))
        theme = defaults.string(forKey: Keys.theme).flatMap(Theme.init(rawValue:)) ?? .system
        loadConnections()
        savedImageTool = defaults.data(forKey: Keys.imageTool).flatMap { try? JSONDecoder().decode(ImageTool.self, from: $0) }
        for service in APIService.allCases { serviceKeys[service] = secrets.get(service.secretAccount) }
        if let data = defaults.data(forKey: Keys.mcpServers),
           let saved = try? JSONDecoder().decode([MCPServer].self, from: data) {
            mcpServers = saved
            for server in saved { mcpTokens[server.id] = secrets.get(server.secretAccount) }
        }
        do {
            conversations = try ConversationStore.load(from: fileURL, images: images)
                .sorted { $0.updatedAt > $1.updatedAt }
            images.removeAll(except: Set(conversations.flatMap(\.messages).flatMap(\.images)))
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
        activeConnection.map { $0.serverConfig(apiKey: apiKeys[$0.id]) }
    }

    var model: String { activeConnection?.model ?? "" }
    var systemPrompt: String { activeConnection?.systemPrompt ?? "" }

    func apiKey(for id: UUID) -> String { apiKeys[id] ?? "" }

    var isConfigured: Bool { config != nil }

    /// The models a chat can use. Image models are reached through `imageTool` instead.
    private var chatModels: [ServedModel] {
        if case .loaded(let served) = models { return served.filter { !$0.makesImages } }
        return []
    }

    var availableModels: [String] { chatModels.map(\.id) }

    /// The image model the chat model can call. Unset when its connection has been deleted.
    var imageTool: ImageTool? {
        savedImageTool.flatMap { tool in connections.contains { $0.id == tool.connectionID } ? tool : nil }
    }

    func setImageTool(_ tool: ImageTool?) {
        savedImageTool = tool
        defaults.set(tool.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.imageTool)
    }

    func setFetchesPages(_ on: Bool) {
        fetchesPages = on
        defaults.set(on, forKey: Keys.fetchPages)
    }

    /// The image models a saved connection serves, listed with that connection's own key.
    func imageModels(of id: UUID) async throws -> [String] {
        guard let connection = connections.first(where: { $0.id == id }) else { return [] }
        let config = connection.serverConfig(apiKey: apiKeys[id])
        return try await ChatClient(config: config, session: session).models().filter(\.makesImages).map(\.id)
    }

    /// Adds a new connection or replaces the one with the same ID. A new one becomes active.
    func saveConnection(_ connection: Connection, apiKey: String) {
        let isNew = !connections.contains { $0.id == connection.id }
        if connections.first(where: { $0.id == connection.id })?.api != connection.api && !isNew {
            // What was learned about a model on the other API says nothing about this one.
            toolless = [:]
            toolsNeedNoReasoning = []
            capabilityChecks = capabilityChecks.filter { $0.key.connection != connection.id }
        }
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
        capabilityChecks = capabilityChecks.filter { $0.key.connection != id }
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

    func serviceKey(_ service: APIService) -> String { serviceKeys[service] ?? "" }

    func setServiceKey(_ service: APIService, _ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        serviceKeys[service] = trimmed.isEmpty ? nil : trimmed
        secrets.set(service.secretAccount, trimmed)
    }

    // MARK: MCP servers

    func mcpToken(for id: UUID) -> String { mcpTokens[id] ?? "" }

    /// Adds or replaces a server. Its tools are fetched again, since the address or token may have changed.
    func saveMCPServer(_ server: MCPServer, token: String) {
        if let index = mcpServers.firstIndex(where: { $0.id == server.id }) {
            mcpServers[index] = server
        } else {
            mcpServers.append(server)
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        mcpTokens[server.id] = trimmed.isEmpty ? nil : trimmed
        secrets.set(server.secretAccount, trimmed)
        mcpClients[server.id] = nil
        mcpStatus[server.id] = nil
        persistMCPServers()
        if server.enabled { refreshMCPServer(server.id) }
    }

    func deleteMCPServer(_ id: UUID) {
        guard let server = mcpServers.first(where: { $0.id == id }) else { return }
        mcpServers.removeAll { $0.id == id }
        secrets.set(server.secretAccount, "")
        mcpTokens[id] = nil
        mcpClients[id] = nil
        mcpStatus[id] = nil
        persistMCPServers()
    }

    func setMCPServer(_ id: UUID, enabled: Bool) {
        guard let index = mcpServers.firstIndex(where: { $0.id == id }) else { return }
        mcpServers[index].enabled = enabled
        persistMCPServers()
        if enabled, mcpStatus[id] == nil { refreshMCPServer(id) }
    }

    func refreshMCPServer(_ id: UUID) {
        guard let server = mcpServers.first(where: { $0.id == id }) else { return }
        Task { await connect(server) }
    }

    @discardableResult
    private func connect(_ server: MCPServer) async -> [MCPTool]? {
        mcpStatus[server.id] = .connecting
        do {
            let tools = try await mcpClient(for: server).listTools()
            if mcpServers.contains(server) { mcpStatus[server.id] = .ready(tools) }
            return tools
        } catch {
            if mcpServers.contains(server) { mcpStatus[server.id] = .failed(error.localizedDescription) }
            return nil
        }
    }

    private func mcpClient(for server: MCPServer) -> MCPClient {
        if let client = mcpClients[server.id] { return client }
        let client = MCPClient(url: server.url, token: mcpTokens[server.id], session: session)
        mcpClients[server.id] = client
        return client
    }

    private func persistMCPServers() {
        defaults.set(try? JSONEncoder().encode(mcpServers), forKey: Keys.mcpServers)
    }

    /// Every enabled server's tools, connecting to any not yet listed, then the image tool when one is set up and
    /// the page tool when it is turned on.
    /// A server that can't be reached is left out so the reply still happens; Settings shows why.
    private func offeredTools() async -> [ReplyTool] {
        var found: [(MCPServer, MCPClient, [MCPTool])] = []
        for server in mcpServers where server.enabled {
            if case .ready(let tools) = mcpStatus[server.id] {
                found.append((server, mcpClient(for: server), tools))
                continue
            }
            liveReply?.status = "Connecting to \(server.name)…"
            if let tools = await connect(server) { found.append((server, mcpClient(for: server), tools)) }
        }
        liveReply?.status = nil
        var tools = OfferedTool.offer(found).map(ReplyTool.mcp)
        if let tool = imageTool, let connection = connections.first(where: { $0.id == tool.connectionID }) {
            let config = connection.serverConfig(apiKey: apiKeys[connection.id])
            tools.append(.image(connection: connection.name, config: config, model: tool.model))
        }
        if fetchesPages { tools.append(.fetch) }
        return tools
    }

    func resolveApproval(_ allowed: Bool) {
        guard let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        awaitingApproval = nil
        continuation.resume(returning: allowed)
    }

    /// Waits for Allow or Decline on a tool that may change things. Stopping the reply declines.
    private func approve(_ callID: String) async -> Bool {
        if Task.isCancelled { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                approvalContinuation = continuation
                awaitingApproval = callID
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveApproval(false) }
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
                result = .known(try await ChatClient(config: config, session: session).reasoningEfforts(model: model))
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
            let served = try await ChatClient(config: config, session: session).models()
            guard connectionID == activeConnectionID else { return }
            models = .loaded(served)
            let before = activeConnection
            selectModel(chatModels.contains { $0.id == model } ? model : chatModels.first?.id ?? model)
            if activeConnection == before { checkEffortLevels() }
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
        let messages = conversations.filter { ids.contains($0.id) }.flatMap(\.messages)
        images.remove(messages.flatMap(\.images))
        exchangeLog.drop(messages.map(\.id))
        if case .failed(let failed, _, _) = generation, ids.contains(failed) { releaseFailedReply() }
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
        if case .failed(let failedID, let message, _) = generation, failedID == id { return message }
        return nil
    }

    var canSend: Bool { isConfigured && !model.isEmpty && !isBusy }

    func send(_ text: String, images: [ImageID] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty, canSend else { return }

        if selectedConversation == nil { newConversation() }
        guard let id = selection, let index = conversations.firstIndex(where: { $0.id == id }) else { return }

        ask(ChatMessage(role: .user, content: trimmed, images: images), in: id, at: index)
    }

    private func ask(_ message: ChatMessage, in id: UUID, at index: Int) {
        let isFirstPrompt = conversations[index].messages.isEmpty
        if isFirstPrompt {
            conversations[index].title = message.content.isEmpty ? "Photo" : Conversation.title(fromFirstUserMessage: message.content)
        }
        conversations[index].model = model
        conversations[index].messages.append(message)
        startStreaming(conversationID: id)
        if isFirstPrompt && !message.content.isEmpty { generateTitle(for: id, prompt: message.content) }
    }

    /// Replaces a sent message and asks again from there. Everything after it is erased, along with photos
    /// no message uses any more.
    func edit(_ messageID: UUID, to text: String, images: [ImageID] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty, canSend, let id = selection,
              let c = conversations.firstIndex(where: { $0.id == id }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == messageID }),
              conversations[c].messages[m].role == .user
        else { return }

        let dropped = conversations[c].messages[m...].flatMap(\.images).filter { !images.contains($0) }
        exchangeLog.drop(conversations[c].messages[(m + 1)...].map(\.id))
        conversations[c].messages.removeSubrange((m + 1)...)
        conversations[c].messages[m].content = trimmed
        conversations[c].messages[m].images = images
        if conversations[c].messages[m].search != nil { conversations[c].messages[m].search = WebSearch(query: trimmed) }
        conversations[c].model = model
        if case .failed(id, _, _) = generation { generation = .idle }
        persist()
        self.images.remove(dropped)
        startStreaming(conversationID: id)
    }

    /// Runs beside the reply. The first-line title stays if the model gives nothing usable.
    private func generateTitle(for id: UUID, prompt: String) {
        guard let config else { return }
        let client = ChatClient(config: config, session: session), model = model
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
        guard case .failed(let id, _, let request) = generation,
              let index = conversations.firstIndex(where: { $0.id == id })
        else { return }
        if request == .reply {
            guard let lastUser = conversations[index].messages.lastIndex(where: { $0.role == .user }) else { return }
            images.remove(conversations[index].messages[(lastUser + 1)...].flatMap(\.images))
            exchangeLog.drop(conversations[index].messages[(lastUser + 1)...].map(\.id))
            conversations[index].messages.removeSubrange((lastUser + 1)...)
        }
        startStreaming(conversationID: id, request: request)
    }

    // MARK: Developer tools

    func exchanges(for messageID: UUID) -> [Exchange] { exchangeLog.exchanges(for: messageID) }

    /// Where a client reports its requests so they show under `messageID`.
    private func recorder(for messageID: UUID) -> @Sendable (Exchange) -> Void {
        { [weak self] exchange in
            Task { @MainActor in self?.attach(exchange, to: messageID) }
        }
    }

    /// Keeps a request with its reply, unless the reply is gone.
    func attach(_ exchange: Exchange, to messageID: UUID) {
        guard messageID == failedReply || conversations.contains(where: { $0.messages.contains { $0.id == messageID } }) else { return }
        exchangeLog.append(exchange, to: messageID)
    }

    /// Records what the app changed about a reply's request, once.
    private func adapt(_ adaptation: Adaptation, on messageID: UUID) {
        for c in conversations.indices {
            guard let m = conversations[c].messages.firstIndex(where: { $0.id == messageID }) else { continue }
            if !conversations[c].messages[m].adaptations.contains(adaptation) {
                conversations[c].messages[m].adaptations.append(adaptation)
            }
            return
        }
    }

    /// Sends `editedText`, a request's body as the inspector showed it, to the request's own address and keeps the
    /// answer with the same reply. The chat itself is never touched.
    @discardableResult
    func resend(_ exchange: Exchange, editedText: String, for messageID: UUID) async -> Exchange {
        let body = await Task.detached { exchange.placeholders.restore(editedText) }.value
        let client = ChatClient(config: resendConfig(for: exchange), session: session)
        let result = await client.send(rawBody: body, to: exchange.url,
                                       contentType: exchange.requestHeader("Content-Type") ?? "application/json", method: exchange.method)
        attach(result, to: messageID)
        return result
    }

    /// The connection a request was made on, so its key goes with it and only to that server. An image request
    /// prefers the image connection and any other the active one. A request no connection matches goes without a key.
    private func resendConfig(for exchange: Exchange) -> ServerConfig {
        let isImage = exchange.purpose == .image || exchange.url.path.contains("/images/")
        let preferred = isImage ? imageTool?.connectionID : activeConnectionID
        let address = exchange.url.absoluteString
        let connection = (connections.filter { $0.id == preferred } + connections)
            .first { address.hasPrefix($0.baseURL.absoluteString) }
        guard let connection else { return ServerConfig(baseURL: exchange.url) }
        return connection.serverConfig(apiKey: apiKeys[connection.id])
    }

    /// Asks a connection's selected model what it supports. When that is the active connection's model, a report
    /// that tools need reasoning off is remembered, since a second probe confirms it. A "no" is only shown: one
    /// token request is weak evidence, so a real request still decides whether tools are dropped.
    func checkCapabilities(of connectionID: UUID) async {
        guard let connection = connections.first(where: { $0.id == connectionID }), !connection.model.isEmpty else { return }
        let key = CapabilityKey(connection: connectionID, model: connection.model)
        guard capabilityChecks[key] != .running else { return }
        capabilityChecks[key] = .running
        let client = ChatClient(config: connection.serverConfig(apiKey: apiKeys[connectionID]), session: session)
        do {
            let report = try await client.capabilities(model: connection.model)
            capabilityChecks[key] = .done(report)
            if connectionID == activeConnectionID, connection.model == model {
                switch report.tools {
                case .onlyWithReasoningOff: toolsNeedNoReasoning.insert(model)
                case .yes, .no, .unknown: break
                }
            }
        } catch {
            capabilityChecks[key] = .failed(error.localizedDescription)
        }
    }

    // MARK: Commands

    /// Why a command can't run in the selected chat right now, or nil when it can.
    func unavailableReason(_ command: SlashCommand) -> String? {
        switch command {
        case .compact:
            Compaction.hasNewMessages(selectedConversation?.messages ?? []) ? nil : "Nothing to compact yet"
        case .webSearch:
            serviceKey(.serper).isEmpty ? "Add a Serper key in Settings › API Keys" : nil
        }
    }

    func run(_ command: SlashCommand, argument: String) {
        guard canSend, unavailableReason(command) == nil, !(command.needsArgument && argument.isEmpty) else { return }
        if selectedConversation == nil { newConversation() }
        guard let id = selection, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        switch command {
        case .compact:
            startStreaming(conversationID: id, request: .compact(focus: argument))
        case .webSearch:
            ask(ChatMessage(role: .user, content: argument, search: WebSearch(query: argument)), in: id, at: index)
        }
    }

    /// Runs the pending `/web-search` on the newest user message, if it has one, and saves its results there.
    private func searchIfNeeded(conversationID id: UUID) async throws {
        guard let c = conversations.firstIndex(where: { $0.id == id }),
              let m = conversations[c].messages.lastIndex(where: { $0.role == .user }),
              let search = conversations[c].messages[m].search, search.results == nil
        else { return }
        let messageID = conversations[c].messages[m].id
        liveReply?.status = "Searching the web…"
        let baseURL = defaults.string(forKey: Keys.serperURL).flatMap(URL.init(string:)) ?? SerperClient.defaultBaseURL
        let results = try await SerperClient(apiKey: serviceKey(.serper), baseURL: baseURL, session: session)
            .search(search.query)
        liveReply?.status = nil
        guard let c = conversations.firstIndex(where: { $0.id == id }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        conversations[c].messages[m].search?.results = results
    }

    func dismissFailure() {
        if case .failed = generation { generation = .idle }
        releaseFailedReply()
    }

    private func releaseFailedReply() {
        guard let id = failedReply else { return }
        exchangeLog.drop([id])
        failedReply = nil
    }

    private func startStreaming(conversationID id: UUID, request: Request = .reply) {
        guard let config, conversations.contains(where: { $0.id == id }) else { return }
        releaseFailedReply()
        let first = beginOutput(in: id, role: request == .reply ? .assistant : .summary)
        let task = Task { await generate(conversationID: id, request: request, first: first, config: config) }
        generation = .streaming(conversationID: id, task: task)
    }

    /// Streams the reply. When the model calls tools, runs them and asks again with their results, each
    /// round its own assistant message, until it answers or uses up its rounds.
    private func generate(conversationID id: UUID, request: Request, first: UUID, config: ServerConfig) async {
        let (model, effort, preferred, systemPrompt, images) = (model, reasoningEffort, preferredEffort, systemPrompt, images)
        var current = first
        var outcome = Outcome.completed
        do {
            try await searchIfNeeded(conversationID: id)
            let tools = request == .reply ? await offeredTools() : []
            let drawing = tools.contains { $0.name == ImageRequest.toolName }
            for round in 0... {
                let messages = conversations.first { $0.id == id }?.messages ?? []
                let history = messages.filter { $0.id != current }
                var wire = switch request {
                case .reply: Compaction.context(of: history, systemPrompt: systemPrompt)
                case .compact(let focus): Compaction.request(for: history, focus: focus)
                }
                if drawing { wire = ImageLabels.annotated(wire, order: ImageLabels.order(of: messages)) }
                let offer = round < Self.maxToolRounds && toolless[model] == nil ? tools : []
                var roundEffort = effort
                if request == .reply {
                    if round < Self.maxToolRounds, !tools.isEmpty, let reason = toolless[model] {
                        adapt(.toolsDropped(reason: reason), on: current)
                    }
                    if !offer.isEmpty, toolsNeedNoReasoning.contains(model), effort != .some(.none) {
                        roundEffort = ReasoningEffort.none
                        adapt(.reasoningOffForTools, on: current)
                    } else if let preferred, preferred != effort {
                        adapt(.effortChanged(from: preferred, to: effort), on: current)
                    }
                }
                // A summary's request isn't kept: there is no reply to inspect it from.
                let client = ChatClient(config: config, session: session, record: request == .reply ? recorder(for: current) : nil)
                let calls = try await streamRound(client, model: model, effort: roundEffort, images: images, wire: wire,
                                                  tools: offer, into: current, request: request)
                guard !calls.isEmpty, !offer.isEmpty, !Task.isCancelled else { break }
                await runTools(offer, for: current, in: id)
                guard !Task.isCancelled else { break }
                commitLiveReply(to: current, in: id)
                current = beginOutput(in: id, role: .assistant)
            }
            if Task.isCancelled { outcome = .cancelled }
        } catch {
            outcome = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
        }
        finish(conversationID: id, messageID: current, request: request, outcome: outcome)
    }

    private func beginOutput(in id: UUID, role: Role) -> UUID {
        let output = ChatMessage(role: role, content: "")
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index].messages.append(output)
            conversations[index].updatedAt = Date()
        }
        liveReply = LiveReply(messageID: output.id)
        return output.id
    }

    /// One request to the model. Returns the tools it called, also shown live as they arrive.
    private func streamRound(_ client: ChatClient, model: String, effort: ReasoningEffort?, images: ImageStore,
                             wire: [ChatMessage], tools: [ReplyTool], into messageID: UUID,
                             request: Request) async throws -> [ToolCall] {
        var calls = ToolCallAccumulator()
        let offered = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let server = "\(client.config.baseURL.host() ?? ""):\(client.config.baseURL.port ?? 0)"
        do {
            for try await event in client.stream(model: model, messages: wire, reasoningEffort: effort, images: images,
                                                 tools: tools.map(\.spec), includeUsage: !withoutUsage.contains(server)) {
                if case .adapted(let adaptation) = event {
                    if adaptation == .usageNotRequested { withoutUsage.insert(server) }
                    adapt(adaptation, on: messageID)
                }
                guard let reply = liveReply, reply.messageID == messageID else { continue }
                switch event {
                case .content(let text): reply.content += text
                case .reasoning(let text): reply.reasoning += text
                case .toolCall(let delta):
                    calls.add(delta)
                    reply.toolCalls = calls.calls.map { call in
                        var call = call
                        call.server = offered[call.name]?.serverName(for: call) ?? ""
                        return call
                    }
                case .done("length") where request != .reply:
                    throw SummaryCutOff()
                case .done, .usage, .adapted: break
                }
            }
        } catch ChatClientError.http(400, let message) where !tools.isEmpty && liveReply?.content.isEmpty != false {
            if effort != .some(.none), message.localizedCaseInsensitiveContains("reasoning_effort") {
                toolsNeedNoReasoning.insert(model)
                adapt(.reasoningOffForTools, on: messageID)
                return try await streamRound(client, model: model, effort: ReasoningEffort.none, images: images, wire: wire,
                                             tools: tools, into: messageID, request: request)
            }
            // Servers without tool support reject the whole request. Ask again without tools.
            let reason = ExchangeText.shortened(message)
            toolless[model] = reason
            adapt(.toolsDropped(reason: reason), on: messageID)
            return try await streamRound(client, model: model, effort: effort, images: images, wire: wire,
                                         tools: [], into: messageID, request: request)
        }
        return liveReply?.toolCalls ?? []
    }

    /// Runs each call in turn, asking first for any MCP tool that isn't read-only. Results show as they land.
    private func runTools(_ offered: [ReplyTool], for messageID: UUID, in id: UUID) async {
        guard let reply = liveReply, reply.messageID == messageID else { return }
        for index in reply.toolCalls.indices {
            let call = reply.toolCalls[index]
            let result: ToolCall.Result
            switch offered.first(where: { $0.name == call.name }) {
            case .image(_, let config, let model)?:
                // It only adds a picture to this chat, so it doesn't ask.
                result = await generateImage(call, config: config, model: model, into: messageID, in: id)
            case .fetch?:
                // It only reads a public page, like a read-only tool, so it doesn't ask.
                result = await fetchPage(call, for: messageID)
            case .mcp(let tool)?:
                if !tool.tool.readOnly, !(await approve(call.id)) {
                    guard !Task.isCancelled else { return }
                    result = .init(text: "The user declined to run this tool.", isError: true)
                } else {
                    do {
                        result = try await tool.client.callTool(tool.tool.name, arguments: call.arguments)
                    } catch {
                        result = .init(text: "The tool failed: \(error.localizedDescription)", isError: true)
                    }
                }
            case nil:
                result = .init(text: "There is no tool named \(call.name).", isError: true)
            }
            guard !Task.isCancelled else { return }
            reply.toolCalls[index].result = result
        }
    }

    /// Reads the page `fetch_url` was called with. Whatever goes wrong comes back as an error result, which the
    /// model reads and relays or tries again. The request is kept with the reply that asked for it.
    private func fetchPage(_ call: ToolCall, for messageID: UUID) async -> ToolCall.Result {
        liveReply?.status = "Fetching page…"
        defer { liveReply?.status = nil }
        do {
            let request = try FetchRequest.parse(arguments: call.arguments)
            return .init(text: try await pages.recording(to: recorder(for: messageID)).fetch(request.url).toolResult)
        } catch let invalid as FetchRequest.Invalid {
            return .init(text: invalid.message, isError: true)
        } catch {
            return .init(text: "The page couldn't be fetched: \(error.localizedDescription)", isError: true)
        }
    }

    /// Draws or edits a picture for `generate_image` and attaches it to the message that asked. Whatever goes wrong
    /// comes back as an error result, which the model reads to correct the call or explain.
    private func generateImage(_ call: ToolCall, config: ServerConfig, model: String,
                               into messageID: UUID, in id: UUID) async -> ToolCall.Result {
        func failure(_ text: String) -> ToolCall.Result { .init(text: text, isError: true) }
        let request: ImageRequest
        do { request = try ImageRequest.parse(arguments: call.arguments) } catch { return failure(error.localizedDescription) }

        let labels = ImageLabels.order(of: conversations.first { $0.id == id }?.messages ?? [])
        var sources: [Data] = []
        for label in request.sources {
            guard labels.indices.contains(label - 1) else {
                let have = labels.count == 1 ? "image 1" : "images 1 to \(labels.count)"
                return failure(labels.isEmpty ? "There are no pictures in this chat to use as source_images."
                                              : "There is no image \(label). The chat has \(have).")
            }
            guard let jpeg = images.data(for: labels[label - 1]) else { return failure("Image \(label) can't be read.") }
            sources.append(jpeg)
        }

        liveReply?.status = sources.isEmpty ? "Generating image…" : "Editing image…"
        defer { liveReply?.status = nil }
        let client = ChatClient(config: config, session: session, record: recorder(for: messageID))
        let asked = client.imageSize(for: request, source: sources.first)
        if let asked, request.aspect == nil, request.longEdge == nil {
            adapt(.imageSize(asked, fromImage: request.sources.first), on: messageID)
        }
        let bytes: Data
        do {
            bytes = try await client.image(model: model, prompt: request.prompt, sources: sources, size: asked)
        } catch {
            return failure("The image server failed: \(error.localizedDescription)")
        }
        // Stored like every other photo, as a JPEG, large enough to save or share.
        guard let jpeg = await Task.detached(operation: { ImageAttachment.jpeg(from: bytes, maxPixels: 4096) }).value else {
            return failure("The image server's reply wasn't a picture the app could read.")
        }
        guard !Task.isCancelled else { return failure("Stopped before the picture was saved.") }
        let image: ImageID
        do { image = try images.save(jpeg) } catch { return failure("The picture couldn't be saved: \(error.localizedDescription)") }
        guard let c = conversations.firstIndex(where: { $0.id == id }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == messageID })
        else {
            images.remove([image])
            return failure("The message this picture was for no longer exists.")
        }
        conversations[c].messages[m].images.append(image)
        let label = ImageLabels.order(of: conversations[c].messages).firstIndex(of: image)! + 1
        let size = ImageAttachment.dimensions(of: jpeg).map { " (\($0.width)x\($0.height))" } ?? ""
        return .init(text: "Created image \(label)\(size). It is shown to the user.")
    }

    private func commitLiveReply(to messageID: UUID, in id: UUID) {
        guard let reply = liveReply, reply.messageID == messageID,
              let c = conversations.firstIndex(where: { $0.id == id }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        conversations[c].messages[m].content = reply.content
        conversations[c].messages[m].reasoning = reply.reasoning
        conversations[c].messages[m].toolCalls = reply.toolCalls
    }

    /// A reply keeps whatever arrived. A summary is all or nothing, since a partial one would silently drop
    /// the rest of the history from what the model sees.
    private func finish(conversationID id: UUID, messageID: UUID, request: Request, outcome: Outcome) {
        var outcome = outcome
        commitLiveReply(to: messageID, in: id)
        if let c = conversations.firstIndex(where: { $0.id == id }),
           let m = conversations[c].messages.firstIndex(where: { $0.id == messageID }) {
            let message = conversations[c].messages[m]
            if message.role == .summary, outcome == .completed, message.content.isEmpty {
                outcome = .failed("The model returned an empty summary.")
            }
            let keep = message.role == .summary
                ? outcome == .completed
                : !(message.content.isEmpty && message.reasoning.isEmpty && message.toolCalls.isEmpty && message.images.isEmpty)
            if !keep {
                if case .failed = outcome { failedReply = messageID } else { exchangeLog.drop([messageID]) }
                conversations[c].messages.remove(at: m)
            }
            conversations[c].updatedAt = Date()
        }
        if liveReply?.messageID == messageID { liveReply = nil }
        if case .failed(let message) = outcome {
            generation = .failed(conversationID: id, message: message, request: request)
        } else {
            generation = .idle
        }
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

private struct SummaryCutOff: LocalizedError {
    var errorDescription: String? { "The summary was cut off by the model's output limit." }
}
