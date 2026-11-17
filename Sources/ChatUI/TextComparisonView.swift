import ChatCore
import SwiftUI

/// Settings › Connections › a connection › Compare Texts. Runs the connection's embeddings or rerank endpoint on a
/// query and a few texts, and keeps the outcome for the session.
struct TextComparisonView: View {
    let store: ChatStore
    let connectionID: UUID
    @State private var models: [String] = []
    @State private var running: Task<Void, Never>?
    @State private var inspecting = false

    private var connection: Connection? { store.connections.first { $0.id == connectionID } }

    var body: some View {
        TextComparisonPage(
            models: models,
            draft: store.comparisonDraft(for: connectionID),
            edit: { store.setComparisonDraft($0, for: connectionID) },
            state: store.comparisons[connectionID] ?? .idle,
            canInspect: store.comparisonExchange(of: connectionID) != nil,
            run: { mode, model, query, texts in
                running = Task { await store.compare(mode, on: connectionID, model: model, query: query, texts: texts) }
            },
            inspect: { inspecting = true }
        )
        .task { models = (try? await store.servedModels(of: connectionID))?.map(\.id) ?? [] }
        .onDisappear { running?.cancel() }
        .sheet(isPresented: $inspecting) { InspectorSheet(store: store, messageID: connectionID).theme(store.theme) }
    }
}

/// The page itself, given what it shows, so it can be drawn from any state.
struct TextComparisonPage: View {
    typealias Mode = TextComparison.Mode

    /// What the server lists. The picked model is offered too, so a server with no model list still has one choice.
    let models: [String]
    let state: ChatStore.Comparison
    let canInspect: Bool
    let edit: (ChatStore.ComparisonDraft) -> Void
    let run: (Mode, String, String, [String]) -> Void
    let inspect: () -> Void
    @State private var draft: ChatStore.ComparisonDraft
    @Environment(\.palette) private var palette

    init(models: [String], draft: ChatStore.ComparisonDraft, edit: @escaping (ChatStore.ComparisonDraft) -> Void = { _ in },
         state: ChatStore.Comparison, canInspect: Bool, run: @escaping (Mode, String, String, [String]) -> Void,
         inspect: @escaping () -> Void) {
        self.models = models
        self.edit = edit
        self.state = state
        self.canInspect = canInspect
        self.run = run
        self.inspect = inspect
        _draft = State(initialValue: draft)
    }

    private var choices: [String] { draft.model.isEmpty || models.contains(draft.model) ? models : [draft.model] + models }
    private var lines: [String] { TextComparison.texts(from: draft.texts) }
    private var running: Bool { state == .running }
    private var canRun: Bool {
        !draft.model.trimmingCharacters(in: .whitespaces).isEmpty && !draft.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !lines.isEmpty && !running
    }

    /// Why Run can't work for want of a model, in one line. Nil when there is a model.
    static func modelPrompt(model: String, hasChoices: Bool) -> String? {
        guard model.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return hasChoices ? "Pick a model to run." : "Type the name of a model to run."
    }

    var body: some View {
        Form {
            Section {
                if choices.isEmpty {
                    TextField("Model", text: $draft.model)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } else {
                    Picker("Model", selection: $draft.model) {
                        ForEach(choices, id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("Endpoint", selection: $draft.mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                Text(Self.modelPrompt(model: draft.model, hasChoices: !choices.isEmpty)
                     ?? (draft.mode == .embeddings ? "Ranks the texts by how close their embeddings are to the query's."
                                                   : "Asks the server to score each text against the query."))
            }
            .listRowBackground(palette.surface)

            Section {
                TextField("Query", text: $draft.query)
                    .autocorrectionDisabled()
            }
            .listRowBackground(palette.surface)

            Section {
                TextEditor(text: $draft.texts)
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .frame(minHeight: 100)
            } header: {
                Text("Texts")
            } footer: {
                Text("One text per line.")
            }
            .listRowBackground(palette.surface)

            Section {
                Button { run(draft.mode, draft.model.trimmingCharacters(in: .whitespaces), draft.query.trimmingCharacters(in: .whitespacesAndNewlines), lines) } label: {
                    Text(state == .idle ? "Run" : "Run Again")
                        .foregroundStyle(canRun ? palette.accent : palette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(!canRun)
            }
            .listRowBackground(palette.surface)

            outcome
        }
        .formStyle(.grouped)
        .foregroundStyle(palette.text)
        .scrollContentBackground(.hidden)
        .navigationTitle("Compare Texts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .animation(.snappy(duration: 0.2), value: state)
        .onChange(of: models) { if draft.model.isEmpty { draft.model = models.first ?? "" } }
        .onChange(of: draft) { edit(draft) }
    }

    @ViewBuilder private var outcome: some View {
        switch state {
        case .idle:
            EmptyView()
        case .running:
            Section {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Comparing…") }
                    .font(.callout).foregroundStyle(palette.secondaryText)
            }
            .listRowBackground(palette.surface)
        case .failed(let message):
            Section {
                Text(message).font(.callout).foregroundStyle(palette.danger).textSelection(.enabled)
                inspectButton
            }
            .listRowBackground(palette.surface)
        case .done(let result):
            Section {
                ForEach(Array(result.ranked.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(entry.text).lineLimit(3)
                        Spacer(minLength: 8)
                        Text(TextComparison.format(score: entry.score)).font(.body.monospacedDigit()).foregroundStyle(palette.secondaryText)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(entry.text)
                    .accessibilityValue("score \(TextComparison.format(score: entry.score))")
                }
                inspectButton
            } header: {
                Text("Results")
            } footer: {
                Text(result.summary())
            }
            .listRowBackground(palette.surface)
        }
    }

    @ViewBuilder private var inspectButton: some View {
        if canInspect {
            Button("Inspect request", action: inspect).foregroundStyle(palette.accent)
        }
    }
}
