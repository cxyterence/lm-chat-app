import ChatCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case connections, appearance

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
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
    @AppStorage private var tab: SettingsTab
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var draft = ConnectionDraft()

    init(store: ChatStore) {
        self.store = store
        _tab = AppStorage(wrappedValue: .connections, "settingsTab", store: store.defaults)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Settings", selection: $tab) {
                    ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding()

                switch tab {
                case .connections: ConnectionsSettings(store: store, draft: $draft)
                case .appearance: AppearanceSettings(store: store)
                }
            }
            .background(palette.groupedBackground)
            .navigationTitle("Settings")
            .themedNavigationBar()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { done() }
                }
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

    private func done() {
        do {
            if draft.baseURL != store.baseURLText || draft.apiKey != store.apiKey {
                try store.applyServer(baseURL: draft.baseURL, apiKey: draft.apiKey)
                Task { await store.refreshModels() }
            }
        } catch {
            draft.parseError = error.localizedDescription
            tab = .connections
            return
        }
        store.updatePreferences(model: draft.model.isEmpty ? nil : draft.model, systemPrompt: draft.systemPrompt)
        dismiss()
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
