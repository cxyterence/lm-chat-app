import ChatCore
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case connections, apiKeys, appearance

    var id: Self { self }
    var title: String {
        switch self {
        case .apiKeys: "API Keys"
        default: rawValue.capitalized
        }
    }
    var systemImage: String {
        switch self {
        case .connections: "network"
        case .apiKeys: "key"
        case .appearance: "paintpalette"
        }
    }
}

/// Which connection the editor opens: a blank one, or a saved one by ID.
enum ConnectionRoute: Hashable {
    case new
    case edit(UUID)
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
                    case .appearance: AppearanceSettings(store: store)
                    }
                }
                .background(palette.groupedBackground)
                .modifier(SettingsChrome(title: page.title, done: { dismiss() }))
            }
            .navigationDestination(for: ConnectionRoute.self) { route in
                ConnectionEditor(store: store, route: route)
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
        case .apiKeys:
            APIService.allCases.filter { !store.serviceKey($0).isEmpty }.map(\.name).joined(separator: ", ")
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

            if existing != nil {
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
