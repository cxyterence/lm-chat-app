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
            model: connection?.model ?? "",
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

    static let exampleQuery = "a small cat"
    static let exampleTexts = "A kitten sleeps on the sofa\nHow to file a tax return\nThe cat sat on the mat"

    /// What the server lists. The picked model is offered too, so a server with no model list still has one choice.
    let models: [String]
    let state: ChatStore.Comparison
    let canInspect: Bool
    let run: (Mode, String, String, [String]) -> Void
    let inspect: () -> Void
    @State private var model: String
    @State private var mode: Mode
    @State private var query: String
    @State private var texts: String
    @Environment(\.palette) private var palette

    init(models: [String], model: String, mode: Mode = .embeddings, query: String = exampleQuery, texts: String = exampleTexts,
         state: ChatStore.Comparison, canInspect: Bool, run: @escaping (Mode, String, String, [String]) -> Void,
         inspect: @escaping () -> Void) {
        self.models = models
        self.state = state
        self.canInspect = canInspect
        self.run = run
        self.inspect = inspect
        _model = State(initialValue: model)
        _mode = State(initialValue: mode)
        _query = State(initialValue: query)
        _texts = State(initialValue: texts)
    }

    private var choices: [String] { model.isEmpty || models.contains(model) ? models : [model] + models }
    private var lines: [String] { TextComparison.texts(from: texts) }
    private var running: Bool { state == .running }
    private var canRun: Bool { !model.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !lines.isEmpty && !running }

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $model) {
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
                .disabled(choices.isEmpty)
                Picker("Endpoint", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                Text(mode == .embeddings ? "Ranks the texts by how close their embeddings are to the query's."
                                         : "Asks the server to score each text against the query.")
            }
            .listRowBackground(palette.surface)

            Section {
                TextField("Query", text: $query)
                    .autocorrectionDisabled()
            }
            .listRowBackground(palette.surface)

            Section {
                TextEditor(text: $texts)
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
                Button { run(mode, model, query.trimmingCharacters(in: .whitespacesAndNewlines), lines) } label: {
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
        .onChange(of: models) { if model.isEmpty { model = models.first ?? "" } }
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
