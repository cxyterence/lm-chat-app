import ChatCore
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case connections, appearance

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .connections: "network"
        case .appearance: "paintpalette"
        }
    }
}

struct ConnectionDraft {
    var baseURL = ""
    var apiKey = ""
    var systemPrompt = ""
    var model = ""
    var parseError: String?
}

struct SettingsView: View {
    let store: ChatStore
    @State private var path: [SettingsPage]
    @State private var draft = ConnectionDraft()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    init(store: ChatStore, page: SettingsPage? = nil) {
        self.store = store
        _path = State(initialValue: page.map { [$0] } ?? [])
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
            .modifier(SettingsChrome(title: "Settings", done: done))
            .navigationDestination(for: SettingsPage.self) { page in
                Group {
                    switch page {
                    case .connections: ConnectionsSettings(store: store, draft: $draft)
                    case .appearance: AppearanceSettings(store: store)
                    }
                }
                .background(palette.groupedBackground)
                .modifier(SettingsChrome(title: page.title, done: done))
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .onAppear {
            draft.baseURL = store.baseURLText
            draft.apiKey = store.apiKey
            draft.systemPrompt = store.systemPrompt
            draft.model = store.model
        }
    }

    private func summary(_ page: SettingsPage) -> String {
        switch page {
        case .connections: store.config?.baseURL.host() ?? "Not set"
        case .appearance: store.theme.name
        }
    }

    private func done() {
        do {
            if draft.baseURL != store.baseURLText || draft.apiKey != store.apiKey {
                try store.applyServer(baseURL: draft.baseURL, apiKey: draft.apiKey)
                Task { await store.refreshModels() }
            }
        } catch {
            draft.parseError = error.localizedDescription
            path = [.connections]
            return
        }
        store.updatePreferences(model: draft.model.isEmpty ? nil : draft.model, systemPrompt: draft.systemPrompt)
        dismiss()
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
    @Binding var draft: ConnectionDraft
    @Environment(\.palette) private var palette

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $draft.baseURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                SecureField("API key (optional)", text: $draft.apiKey)
                Button("Connect") { Task { await connect() } }
                if let parseError = draft.parseError {
                    Text(parseError).foregroundStyle(palette.danger).font(.callout)
                }
                statusRow
            } header: {
                Text("Server")
            } footer: {
                Text("Examples: 192.168.1.5:1234 (LM Studio), 192.168.1.5:11434 (Ollama), 192.168.1.5:8080 (llama.cpp). \"/v1\" is added when the address has no path.")
            }
            .listRowBackground(palette.surface)

            if !store.availableModels.isEmpty {
                Section("Model") {
                    Picker("Model", selection: $draft.model) {
                        ForEach(store.availableModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                .listRowBackground(palette.surface)
            }

            Section {
                TextEditor(text: $draft.systemPrompt)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100)
            } header: {
                Text("System Prompt")
            } footer: {
                Text("Sent before every conversation. Leave empty for none.")
            }
            .listRowBackground(palette.surface)
        }
        .formStyle(.grouped)
        .foregroundStyle(palette.text)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var statusRow: some View {
        switch store.models {
        case .idle:
            Label("Not connected", systemImage: "circle.dashed").foregroundStyle(palette.secondaryText)
        case .loading:
            HStack { ProgressView(); Text("Connecting…").foregroundStyle(palette.secondaryText) }
        case .loaded(let ids):
            Label("\(ids.count) model\(ids.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(palette.success)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(palette.danger)
        }
    }

    private func connect() async {
        do {
            try store.applyServer(baseURL: draft.baseURL, apiKey: draft.apiKey)
            draft.parseError = nil
            draft.baseURL = store.baseURLText
        } catch {
            draft.parseError = error.localizedDescription
            return
        }
        await store.refreshModels()
        if store.availableModels.contains(draft.model) == false { draft.model = store.model }
    }
}
