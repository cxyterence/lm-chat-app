import ChatCore
import SwiftUI

struct SettingsView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var systemPrompt = ""
    @State private var model = ""
    @State private var parseError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $baseURL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    SecureField("API key (optional)", text: $apiKey)
                    Button("Connect") { Task { await connect() } }
                    if let parseError {
                        Text(parseError).foregroundStyle(.red).font(.callout)
                    }
                    statusRow
                } header: {
                    Text("Server")
                } footer: {
                    Text("Examples: 192.168.1.5:1234 (LM Studio), 192.168.1.5:11434 (Ollama), 192.168.1.5:8080 (llama.cpp). \"/v1\" is added when the address has no path.")
                }

                if !store.availableModels.isEmpty {
                    Section("Model") {
                        Picker("Model", selection: $model) {
                            ForEach(store.availableModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }

                Section {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 100)
                } header: {
                    Text("System Prompt")
                } footer: {
                    Text("Sent before every conversation. Leave empty for none.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
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
            baseURL = store.baseURLText
            apiKey = store.apiKey
            systemPrompt = store.systemPrompt
            model = store.model
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch store.models {
        case .idle:
            Label("Not connected", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .loading:
            HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) }
        case .loaded(let ids):
            Label("\(ids.count) model\(ids.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func connect() async {
        do {
            try store.applyServer(baseURL: baseURL, apiKey: apiKey)
            parseError = nil
            baseURL = store.baseURLText
        } catch {
            parseError = error.localizedDescription
            return
        }
        await store.refreshModels()
        if store.availableModels.contains(model) == false { model = store.model }
    }

    private func done() {
        do {
            if baseURL != store.baseURLText || apiKey != store.apiKey {
                try store.applyServer(baseURL: baseURL, apiKey: apiKey)
                Task { await store.refreshModels() }
            }
        } catch {
            parseError = error.localizedDescription
            return
        }
        store.updatePreferences(model: model.isEmpty ? nil : model, systemPrompt: systemPrompt)
        dismiss()
    }
}
