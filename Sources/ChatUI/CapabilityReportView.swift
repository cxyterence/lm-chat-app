import ChatCore
import SwiftUI

/// Settings › Connections › a connection › Check Model. Runs the checks for the connection's selected model and
/// keeps the result for the session.
struct CapabilityReportView: View {
    let store: ChatStore
    let connectionID: UUID

    private var connection: Connection? { store.connections.first { $0.id == connectionID } }

    var body: some View {
        let model = connection?.model ?? ""
        CapabilityReportPage(
            model: model,
            check: store.capabilityChecks[.init(connection: connectionID, model: model)],
            isActive: connectionID == store.activeConnectionID,
            run: { Task { await store.checkCapabilities(of: connectionID) } }
        )
    }
}

/// The page itself, given what it shows, so it can be drawn from any state.
struct CapabilityReportPage: View {
    let model: String
    let check: ChatStore.CapabilityCheck?
    /// Whether this is the connection in use. Only then does a result change how requests are sent.
    let isActive: Bool
    let run: () -> Void
    @State private var detailsOpen: Bool
    @State private var showAllFacts = false
    @Environment(\.palette) private var palette

    init(model: String, check: ChatStore.CapabilityCheck?, isActive: Bool, detailsOpen: Bool = false, run: @escaping () -> Void) {
        self.model = model
        self.check = check
        self.isActive = isActive
        self.run = run
        _detailsOpen = State(initialValue: detailsOpen)
    }

    private static let factLimit = 30

    private var running: Bool { check == .running }

    var body: some View {
        Form {
            Section {
                LabeledContent("Model") { Text(model.isEmpty ? "None picked" : model).foregroundStyle(palette.secondaryText).lineLimit(1).truncationMode(.middle) }
                Button(action: run) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check == nil ? "Run Check" : "Run Again").foregroundStyle(model.isEmpty || running ? palette.secondaryText : palette.accent)
                        Text("Sends a few one-token requests to the model.").font(.caption).foregroundStyle(palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .disabled(model.isEmpty || running)
            } footer: {
                if model.isEmpty { Text("Pick a model from the model button in a chat first.") }
            }
            .listRowBackground(palette.surface)

            switch check {
            case nil:
                EmptyView()
            case .running:
                Section {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…") }
                        .font(.callout).foregroundStyle(palette.secondaryText)
                }
                .listRowBackground(palette.surface)
            case .failed(let message):
                Section { Text(message).font(.callout).foregroundStyle(palette.danger) }
                    .listRowBackground(palette.surface)
            case .done(let report):
                results(report)
            }
        }
        .formStyle(.grouped)
        .foregroundStyle(palette.text)
        .scrollContentBackground(.hidden)
        .navigationTitle("Check Model")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .animation(.snappy(duration: 0.2), value: check)
    }

    private func changesRequests(_ tools: ToolSupport) -> Bool {
        switch tools {
        case .onlyWithReasoningOff, .no: true
        case .yes, .unknown: false
        }
    }

    @ViewBuilder private func results(_ report: CapabilityReport) -> some View {
        Section {
            switch report.tools {
            case .yes: Finding("Tools", .yes)
            case .onlyWithReasoningOff:
                Finding("Tools", .qualified("Reasoning off only"), reason: "The server refuses tools while the model reasons.")
            case .no(let reason): Finding("Tools", .no, reason: reason)
            case .unknown(let reason): Finding("Tools", .unknown, reason: reason)
            }
            switch report.vision {
            case .yes: Finding("Vision", .yes)
            case .no(let reason): Finding("Vision", .no, reason: reason)
            case .unknown(let reason): Finding("Vision", .unknown, reason: reason)
            }
            Finding("Reasoning levels", report.efforts.isEmpty ? .qualified("Not adjustable") : .qualified(report.efforts.map(\.label).joined(separator: ", ")))
            Finding("Context length", report.contextLength.map { .qualified("\($0.formatted()) tokens") } ?? .unknown,
                    reason: report.contextLength == nil ? "The server doesn't say." : nil)
        } header: {
            Text("Results")
        } footer: {
            if isActive, changesRequests(report.tools) {
                Text("Chats on this connection use this result until you quit the app.")
            }
        }
        .listRowBackground(palette.surface)

        Section {
            if report.server.isEmpty {
                LabeledContent("Server details") { Text("Nothing reported").foregroundStyle(palette.secondaryText) }
            } else {
                DisclosureGroup(isExpanded: $detailsOpen) {
                    let shown = showAllFacts ? report.server : Array(report.server.prefix(Self.factLimit))
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, fact in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fact.name).font(.caption.monospaced()).foregroundStyle(palette.secondaryText)
                            Text(fact.value).font(.callout).lineLimit(4).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                    if report.server.count > shown.count {
                        Button("Show all \(report.server.count)") { showAllFacts = true }.foregroundStyle(palette.accent)
                    }
                } label: {
                    HStack {
                        Text("Server details")
                        Spacer()
                        Text("\(report.server.count)").foregroundStyle(palette.secondaryText)
                    }
                }
            }
        }
        .listRowBackground(palette.surface)
    }
}

/// One thing a model can or can't do: its name, the answer, and when the answer is no or unknown, why.
private struct Finding: View {
    enum Answer: Equatable {
        case yes, no, unknown
        /// An answer that is a value, such as the levels a model takes.
        case qualified(String)
    }

    let name: String
    let answer: Answer
    var reason: String?
    @Environment(\.palette) private var palette

    init(_ name: String, _ answer: Answer, reason: String? = nil) {
        self.name = name
        self.answer = answer
        self.reason = reason
    }

    private var word: String {
        switch answer {
        case .yes: "Yes"
        case .no: "No"
        case .unknown: "Unknown"
        case .qualified(let text): text
        }
    }

    private var color: Color {
        switch answer {
        case .yes: palette.success
        case .no, .qualified: palette.text
        case .unknown: palette.secondaryText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                Spacer(minLength: 12)
                Text(word).foregroundStyle(color).multilineTextAlignment(.trailing)
            }
            if let reason, !reason.isEmpty {
                Text(reason).font(.caption).foregroundStyle(palette.secondaryText).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue([word, reason].compactMap { $0 }.joined(separator: ". "))
    }
}
