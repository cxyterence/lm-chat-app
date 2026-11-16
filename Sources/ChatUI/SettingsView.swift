import ChatCore
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case connections, apiKeys, mcp, imageTool, webPages, appearance

    var id: Self { self }
    var title: String {
        switch self {
        case .apiKeys: "API Keys"
        case .mcp: "MCP Connections"
        case .imageTool: "Image Generation"
        case .webPages: "Web Pages"
        default: rawValue.capitalized
        }
    }
    var systemImage: String {
        switch self {
        case .connections: "network"
        case .apiKeys: "key"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .imageTool: "photo"
        case .webPages: "link"
        case .appearance: "paintpalette"
        }
    }
}

/// Which MCP server the editor opens: GitHub's preset, a blank one, or a saved one.
enum MCPRoute: Hashable {
    case github
    case new
    case edit(UUID)
}

/// Which connection the editor opens: a blank one, or a saved one by ID.
enum ConnectionRoute: Hashable {
    case new
    case edit(UUID)
    /// The Check Model page of a saved connection.
    case check(UUID)
    /// The Compare Texts page of a saved connection.
    case compare(UUID)
}

struct SettingsView: View {
    let store: ChatStore
    @State private var path: NavigationPath
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    init(store: ChatStore, page: SettingsPage? = nil) {
        self.store = store
        _path = State(initialValue: NavigationPath(page.map { [$0] } ?? []))
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(SettingsPage.allCases) { page in
                NavigationLink(value: page) {
                    Label {
                        HStack {
                            Text(page.title).foregroundStyle(palette.text)
                            Spacer()
                            Text(summary(page)).foregroundStyle(palette.secondaryText).lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: page.systemImage).foregroundStyle(palette.accent)
                    }
                }
                .listRowBackground(palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(palette.groupedBackground)
            .modifier(SettingsChrome(title: "Settings", done: { dismiss() }))
            .navigationDestination(for: SettingsPage.self) { page in
                Group {
                    switch page {
                    case .connections: ConnectionsSettings(store: store) { path.append($0) }
                    case .apiKeys: APIKeysSettings(store: store)
                    case .mcp: MCPSettings(store: store) { path.append($0) }
                    case .imageTool: ImageToolSettings(store: store)
                    case .webPages: WebPagesSettings(store: store)
                    case .appearance: AppearanceSettings(store: store)
                    }
                }
                .background(palette.groupedBackground)
                .modifier(SettingsChrome(title: page.title, done: { dismiss() }))
            }
            .navigationDestination(for: MCPRoute.self) { route in
                MCPServerEditor(store: store, route: route)
                    .background(palette.groupedBackground)
            }
            .navigationDestination(for: ConnectionRoute.self) { route in
                Group {
                    switch route {
                    case .check(let id): CapabilityReportView(store: store, connectionID: id)
                    case .compare(let id): TextComparisonView(store: store, connectionID: id)
                    case .new, .edit: ConnectionEditor(store: store, route: route)
                    }
                }
                .background(palette.groupedBackground)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    private func summary(_ page: SettingsPage) -> String {
        switch page {
        case .connections: store.activeConnection?.name ?? "Not set"
        case .mcp:
            store.mcpServers.filter(\.enabled).map(\.name).joined(separator: ", ")
        case .apiKeys:
            APIService.allCases.filter { !store.serviceKey($0).isEmpty }.map(\.name).joined(separator: ", ")
        case .imageTool: store.imageTool?.model ?? ""
        case .webPages: store.fetchesPages ? "On" : "Off"
        case .appearance: store.theme.name
        }
    }
}

private struct SettingsChrome: ViewModifier {
    let title: String
    let done: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
    }
}

struct ConnectionsSettings: View {
    let store: ChatStore
    let open: (ConnectionRoute) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        List {
            Section {
                ForEach(store.connections) { connection in
                    row(connection)
                        .swipeActions {
                            Button("Delete", role: .destructive) { store.deleteConnection(connection.id) }
                        }
                }
                Button { open(.new) } label: {
                    Label("Add Connection", systemImage: "plus").foregroundStyle(palette.accent)
                }
            } footer: {
                Text("Tap a connection to use it. Each one keeps its own server, key, model and system prompt.")
            }
            .listRowBackground(palette.surface)
        }
        .foregroundStyle(palette.text)
        .scrollContentBackground(.hidden)
    }

    private func row(_ connection: Connection) -> some View {
        let active = connection.id == store.activeConnectionID
        return HStack(spacing: 12) {
            Button { if !active { store.activate(connection.id) } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.accent)
                        .opacity(active ? 1 : 0)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.name).foregroundStyle(palette.text)
                        if active {
                            status
                        } else {
                            Text(Connection.address(of: connection.baseURL))
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                    .font(.body)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel(connection.name)
            .accessibilityAddTraits(active ? .isSelected : [])
            Button("Edit \(connection.name)", systemImage: "info.circle") { open(.edit(connection.id)) }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(palette.accent)
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder private var status: some View {
        Group {
            switch store.models {
            case .idle:
                Text("Not connected").foregroundStyle(palette.secondaryText)
            case .loading:
                Text("Connecting…").foregroundStyle(palette.secondaryText)
            case .loaded(let ids):
                Text("Connected · \(ids.count) model\(ids.count == 1 ? "" : "s")").foregroundStyle(palette.success)
            case .failed(let message):
                Text(message).foregroundStyle(palette.danger).lineLimit(2)
            }
        }
        .font(.caption)
    }
}

struct ConnectionEditor: View {
    let store: ChatStore
    let route: ConnectionRoute
    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var systemPrompt = ""
    @State private var api = WireAPI.chatCompletions
    @State private var error: String?
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    private var existing: Connection? {
        guard case .edit(let id) = route else { return nil }
        return store.connections.first { $0.id == id }
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name, prompt: Text(hostHint ?? "My server"))
            }
            .listRowBackground(palette.surface)

            Section {
                TextField("Server URL", text: $baseURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                SecureField("API key (optional)", text: $apiKey)
                Picker("API", selection: $api) {
                    Text("Chat Completions").tag(WireAPI.chatCompletions)
                    Text("Responses").tag(WireAPI.responses)
                }
                if let error {
                    Text(error).foregroundStyle(palette.danger).font(.callout)
                }
            } header: {
                Text("Server")
            } footer: {
                Text(verbatim: "Examples: 192.168.1.5:1234 (LM Studio), 192.168.1.5:11434 (Ollama), https://api.openai.com/v1. \"/v1\" is added when the address has no path.")
            }
            .listRowBackground(palette.surface)

            Section {
                TextEditor(text: $systemPrompt)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100)
            } header: {
                Text("System Prompt")
            } footer: {
                Text("Sent before every conversation on this connection. Leave empty for none.")
            }
            .listRowBackground(palette.surface)

            if let existing {
                Section {
                    NavigationLink(value: ConnectionRoute.check(existing.id)) {
                        LabeledContent("Check Model") {
                            Text(existing.model.isEmpty ? "No model" : existing.model)
                                .foregroundStyle(palette.secondaryText).lineLimit(1).truncationMode(.middle)
                        }
                    }
                } footer: {
                    Text("Finds out whether the model takes tools and pictures, and which reasoning levels it accepts.")
                }
                .listRowBackground(palette.surface)

                Section {
                    NavigationLink("Compare Texts", value: ConnectionRoute.compare(existing.id))
                } footer: {
                    Text("Tries the server's embeddings and rerank endpoints on a few texts.")
                }
                .listRowBackground(palette.surface)

                Section {
                    Button("Delete Connection", role: .destructive) { confirmingDelete = true }
                }
                .listRowBackground(palette.surface)
            }
        }
        .formStyle(.grouped)
        .foregroundStyle(palette.text)
        .scrollContentBackground(.hidden)
        .navigationTitle(existing == nil ? "New Connection" : "Edit Connection")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .confirmationDialog("Delete this connection?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Connection", role: .destructive) {
                if let existing { store.deleteConnection(existing.id) }
                dismiss()
            }
        }
        .onAppear {
            guard let existing else { return }
            name = existing.name
            baseURL = existing.baseURL.absoluteString
            apiKey = store.apiKey(for: existing.id)
            systemPrompt = existing.systemPrompt
            api = existing.api
        }
    }

    private var hostHint: String? {
        (try? ServerConfig.parse(baseURL: baseURL, apiKey: "")).map { Connection.address(of: $0.baseURL) }
    }

    private func save() {
        let parsed: ServerConfig
        do {
            parsed = try ServerConfig.parse(baseURL: baseURL, apiKey: apiKey)
        } catch {
            self.error = error.localizedDescription
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var connection = existing ?? Connection(name: "", baseURL: parsed.baseURL)
        connection.name = trimmedName.isEmpty ? Connection.address(of: parsed.baseURL) : trimmedName
        connection.baseURL = parsed.baseURL
        connection.systemPrompt = systemPrompt
        connection.api = api
        store.saveConnection(connection, apiKey: parsed.apiKey ?? "")
        dismiss()
    }
}

struct APIKeysSettings: View {
    let store: ChatStore
    @Environment(\.palette) private var palette

    var body: some View {
        Form {
            ForEach(APIService.allCases) { service in
                ServiceKeyRow(store: store, service: service)
            }
        }
        .formStyle(.grouped)
        .foregroundStyle(palette.text)
        .scrollContentBackground(.hidden)
    }
}

/// Saves as you type, so there's no Save button to forget.
private struct ServiceKeyRow: View {
    let store: ChatStore
    let service: APIService
    @State private var key = ""
    @Environment(\.palette) private var palette

    var body: some View {
        Section {
            SecureField("\(service.name) API key", text: $key)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: key) { store.setServiceKey(service, key) }
            Link("Get a \(service.name) key", destination: service.signupURL).foregroundStyle(palette.accent)
        } header: {
            HStack {
                Text(service.name)
                Spacer()
                if !store.serviceKey(service).isEmpty {
                    Label("Saved", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                        .foregroundStyle(palette.success)
                }
            }
        } footer: {
            Text(service.purpose + " Stored in the Keychain on this device.")
        }
        .listRowBackground(palette.surface)
        .onAppear { key = store.serviceKey(service) }
    }
}

/// Picks the image model that chat models draw with, from the image models a saved connection serves.
struct ImageToolSettings: View {
    private enum Listing {
        case loading
        case models([String])
        case failed(String)
    }

    let store: ChatStore
    @State private var connection: UUID?
    @State private var listing = Listing.loading
    @Environment(\.palette) private var palette

    init(store: ChatStore) {
        self.store = store
        _connection = State(initialValue: store.imageTool?.connectionID)
    }

    var body: some View {
        Form {
            Section {
                Picker("Connection", selection: $connection) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.connections) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                if let connection { models(of: connection) }
            } footer: {
                Text("A chat model that supports tool calling can draw with this image model when you ask for a picture, and edit the photos you attach. The image model needs no chat of its own.")
            }
            .listRowBackground(palette.surface)
        }
        .formStyle(.grouped)
        .foregroundStyle(palette.text)
        .scrollContentBackground(.hidden)
        .task(id: connection) { await load() }
    }

    @ViewBuilder private func models(of connection: UUID) -> some View {
        switch listing {
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading models…") }
                .font(.callout).foregroundStyle(palette.secondaryText)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(palette.danger)
        case .models(let names) where names.isEmpty:
            Text("This server lists no image models.").font(.callout).foregroundStyle(palette.secondaryText)
        case .models(let names):
            Picker("Model", selection: Binding(
                get: { store.imageTool?.model ?? "" },
                set: { store.setImageTool(ImageTool(connectionID: connection, model: $0)) }
            )) {
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    /// Lists the picked connection's image models. A connection newly picked starts with the first of them.
    private func load() async {
        guard let id = connection else { return store.setImageTool(nil) }
        listing = .loading
        var names: [String] = []
        do {
            names = try await store.imageModels(of: id)
            listing = .models(names)
        } catch {
            listing = .failed(error.localizedDescription)
        }
        guard !Task.isCancelled else { return }
        if store.imageTool?.connectionID != id {
            store.setImageTool(names.first.map { ImageTool(connectionID: id, model: $0) })
        }
    }
}

/// Lets chat models read the pages of links, through `fetch_url`.
struct WebPagesSettings: View {
    let store: ChatStore
    @Environment(\.palette) private var palette

    var body: some View {
        Form {
            Section {
                Toggle("Fetch web pages", isOn: Binding(get: { store.fetchesPages }, set: store.setFetchesPages))
            } footer: {
                Text("A chat model that supports tool calling can read a link you paste. Pages are fetched from this device, and the model sees their text. It asks before reading an address you didn't give it.")
            }
            .listRowBackground(palette.surface)
        }
        .formStyle(.grouped)
        .foregroundStyle(palette.text)
        .scrollContentBackground(.hidden)
    }
}

struct MCPSettings: View {
    let store: ChatStore
    let open: (MCPRoute) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        List {
            if !store.mcpServers.isEmpty {
                Section {
                    ForEach(store.mcpServers) { server in
                        row(server)
                            .swipeActions {
                                Button("Delete", role: .destructive) { store.deleteMCPServer(server.id) }
                            }
                    }
                } footer: {
                    Text("Tools from servers that are on are offered to the model in every chat. A tool that can make changes asks you before it runs.")
                }
                .listRowBackground(palette.surface)
            }
            Section {
                if !store.mcpServers.contains(where: \.isGitHub) {
                    Button { open(.github) } label: {
                        Label("Add GitHub", systemImage: "plus").foregroundStyle(palette.accent)
                    }
                }
                Button { open(.new) } label: {
                    Label("Add Server", systemImage: "plus").foregroundStyle(palette.accent)
                }
            } footer: {
                if store.mcpServers.isEmpty {
                    Text("MCP servers give the model tools, like reading your GitHub repositories, issues and pull requests.")
                }
            }
            .listRowBackground(palette.surface)
        }
        .foregroundStyle(palette.text)
        .scrollContentBackground(.hidden)
    }

    private func row(_ server: MCPServer) -> some View {
        HStack(spacing: 12) {
            Button { open(.edit(server.id)) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).foregroundStyle(palette.text)
                    MCPStatusText(status: server.enabled ? store.mcpStatus[server.id] : nil, enabled: server.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Edit \(server.name)")
            Toggle(server.name, isOn: Binding(get: { server.enabled }, set: { store.setMCPServer(server.id, enabled: $0) }))
                .labelsHidden()
                .tint(palette.accent)
        }
        .buttonStyle(.borderless)
    }
}

private struct MCPStatusText: View {
    let status: MCPStatus?
    let enabled: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch status {
            case nil: Text(enabled ? "Not connected yet" : "Off").foregroundStyle(palette.secondaryText)
            case .connecting: Text("Connecting…").foregroundStyle(palette.secondaryText)
            case .ready(let tools):
                Text("Connected · \(tools.count) tool\(tools.count == 1 ? "" : "s")").foregroundStyle(palette.success)
            case .failed(let message): Text(message).foregroundStyle(palette.danger).lineLimit(2)
            }
        }
        .font(.caption)
    }
}

struct MCPServerEditor: View {
    private static let githubTokenURL = URL(string: "https://github.com/settings/personal-access-tokens/new")!

    let store: ChatStore
    let route: MCPRoute
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    private var existing: MCPServer? {
        guard case .edit(let id) = route else { return nil }
        return store.mcpServers.first { $0.id == id }
    }

    private var isGitHub: Bool { URL(string: url)?.host() == "api.githubcopilot.com" }

    /// GitHub's server takes `/readonly` on the end to hide every tool that writes.
    private var allowsChanges: Binding<Bool> {
        Binding(get: { !url.hasSuffix("/readonly") }, set: { allow in
            var base = url
            while base.hasSuffix("/") { base.removeLast() }
            if base.hasSuffix("/readonly") { base.removeLast("/readonly".count) }
            url = allow ? base + "/" : base + "/readonly"
        })
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name, prompt: Text("My server"))
            }
            .listRowBackground(palette.surface)

            Section {
                TextField("Server URL", text: $url)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                SecureField(isGitHub ? "Personal access token" : "Token (optional)", text: $token)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if isGitHub {
                    Link("Create a GitHub token", destination: Self.githubTokenURL).foregroundStyle(palette.accent)
                }
                if let error {
                    Text(error).foregroundStyle(palette.danger).font(.callout)
                }
            } header: {
                Text("Server")
            } footer: {
                Text(isGitHub
                     ? "A fine-grained token with read access to the repositories you want the model to see. Sent as a Bearer token and kept in the Keychain."
                     : "The server's Streamable HTTP address. A token is sent as a Bearer token and kept in the Keychain.")
            }
            .listRowBackground(palette.surface)

            if isGitHub {
                Section {
                    Toggle("Allow changes", isOn: allowsChanges).tint(palette.accent)
                } footer: {
                    Text(allowsChanges.wrappedValue
                         ? "The model can also use tools that change things, like opening issues. Each one asks you first."
                         : "The model can read repositories, issues and pull requests but has no tools that change them.")
                }
                .listRowBackground(palette.surface)
            }

            if let existing {
                Section {
                    switch store.mcpStatus[existing.id] {
                    case .ready(let tools):
                        ForEach(tools, id: \.name) { tool in
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tool.name).font(.callout.monospaced())
                                    if !tool.description.isEmpty {
                                        Text(tool.description).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(2)
                                    }
                                }
                            } icon: {
                                Image(systemName: tool.readOnly ? "eye" : "pencil")
                                    .foregroundStyle(tool.readOnly ? palette.secondaryText : palette.accent)
                            }
                        }
                    case .connecting:
                        ProgressView()
                    case .failed(let message):
                        Text(message).foregroundStyle(palette.danger).font(.callout)
                    case nil:
                        Text(existing.enabled ? "Not connected yet" : "Turned off").foregroundStyle(palette.secondaryText)
                    }
                    Button("Refresh Tools") { store.refreshMCPServer(existing.id) }.foregroundStyle(palette.accent)
                } header: {
                    Text("Tools")
                } footer: {
                    Text("Tools marked with a pencil can make changes and ask before running.")
                }
                .listRowBackground(palette.surface)

                Section {
                    Button("Delete Server", role: .destructive) { confirmingDelete = true }
                }
                .listRowBackground(palette.surface)
            }
        }
        .formStyle(.grouped)
        .foregroundStyle(palette.text)
        .scrollContentBackground(.hidden)
        .navigationTitle(existing == nil ? "New Server" : "Edit Server")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .confirmationDialog("Delete this server?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Server", role: .destructive) {
                if let existing { store.deleteMCPServer(existing.id) }
                dismiss()
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let server = existing ?? (route == .github ? .github() : nil)
            guard let server else { return }
            name = server.name
            url = server.url.absoluteString
            if let existing { token = store.mcpToken(for: existing.id) }
        }
    }

    private func save() {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard let parsed = URL(string: trimmed), let scheme = parsed.scheme, ["http", "https"].contains(scheme),
              parsed.host() != nil
        else {
            error = "Enter the server's full address, starting with https://"
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var server = existing ?? MCPServer(name: "", url: parsed)
        server.name = trimmedName.isEmpty ? (parsed.host() ?? trimmed) : trimmedName
        server.url = parsed
        store.saveMCPServer(server, token: token)
        dismiss()
    }
}
