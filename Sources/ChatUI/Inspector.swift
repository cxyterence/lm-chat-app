import ChatCore
import SwiftUI

/// What the inspector sheet is open on: one reply, or the reply that failed before it showed anything.
struct InspectedReply: Identifiable {
    let id: UUID
}

/// Every request made for one reply: a summary of what it cost, a row per request, and on tap the request itself.
struct InspectorSheet: View {
    let store: ChatStore
    let messageID: UUID
    @State private var path: [UUID] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    private var exchanges: [Exchange] { store.exchanges(for: messageID) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let reply = ExchangeText.reply(in: exchanges) {
                    Section { SummaryGrid(exchange: reply) }.listRowBackground(palette.surface)
                }
                Section {
                    ForEach(exchanges) { exchange in
                        NavigationLink(value: exchange.id) { ExchangeRow(exchange: exchange) }
                    }
                } header: {
                    Text("Requests")
                } footer: {
                    Text("Kept in memory until you quit the app.")
                }
                .listRowBackground(palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(palette.groupedBackground)
            .foregroundStyle(palette.text)
            .navigationTitle("Inspect")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: UUID.self) { id in
                if let exchange = exchanges.first(where: { $0.id == id }) {
                    ExchangeDetail(store: store, exchange: exchange, messageID: messageID) { path = [$0] }
                        .background(palette.groupedBackground)
                }
            }
        }
    }
}

/// Status, time to first token, total time and token counts of one request, as far as the server reported them.
private struct SummaryGrid: View {
    let exchange: Exchange
    @Environment(\.palette) private var palette

    private struct Cell: Identifiable {
        let value: String
        let label: String
        var color: Color?
        var id: String { label + value }
    }

    private var cells: [Cell] {
        let stats = exchange.stats
        var cells: [Cell] = []
        switch ExchangeText.outcome(exchange) {
        case .succeeded(let status): cells.append(Cell(value: "\(status)", label: ExchangeText.statusName(status), color: palette.success))
        case .stopped: cells.append(Cell(value: "Stopped", label: "Status"))
        case .failed(let headline, _):
            let parts = headline.split(separator: " ", maxSplits: 1).map(String.init)
            cells.append(exchange.status == nil ? Cell(value: "Failed", label: "No response", color: palette.danger)
                                                : Cell(value: parts[0], label: parts.dropFirst().first ?? "", color: palette.danger))
        }
        if let first = stats.timeToFirstToken { cells.append(Cell(value: ExchangeText.duration(first), label: "First token")) }
        if let total = stats.totalTime { cells.append(Cell(value: ExchangeText.duration(total), label: "Total")) }
        if let tokens = exchange.usage?.completionTokens { cells.append(Cell(value: ExchangeText.count(tokens), label: "Tokens out")) }
        if let rate = stats.tokensPerSecond { cells.append(Cell(value: ExchangeText.rate(rate), label: "Tokens/s")) }
        if let prompt = exchange.usage?.promptTokens { cells.append(Cell(value: ExchangeText.count(prompt), label: "Tokens in")) }
        if let reasoning = exchange.usage?.reasoningTokens { cells.append(Cell(value: ExchangeText.count(reasoning), label: "Reasoning")) }
        return cells
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12, alignment: .topLeading)],
                  alignment: .leading, spacing: 12) {
            ForEach(cells) { cell in
                VStack(alignment: .leading, spacing: 2) {
                    Text(cell.value).font(.headline.monospacedDigit()).foregroundStyle(cell.color ?? palette.text)
                    Text(cell.label).font(.caption).foregroundStyle(palette.secondaryText)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(cell.label.isEmpty ? "Status" : cell.label)
                .accessibilityValue(cell.value)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ExchangeRow: View {
    let exchange: Exchange
    @Environment(\.palette) private var palette

    var body: some View {
        let outcome = ExchangeText.outcome(exchange)
        HStack(alignment: .top, spacing: 10) {
            symbol(outcome).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ExchangeText.title(exchange.purpose))
                    Spacer(minLength: 8)
                    if let total = exchange.stats.totalTime {
                        Text(ExchangeText.duration(total)).font(.callout.monospacedDigit()).foregroundStyle(palette.secondaryText)
                    }
                }
                Text(verbatim: "\(exchange.method) \(exchange.url.path)")
                    .font(.caption.monospaced()).foregroundStyle(palette.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
                detail(outcome)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(outcome))
    }

    @ViewBuilder private func symbol(_ outcome: ExchangeText.Outcome) -> some View {
        switch outcome {
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.success)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(palette.secondaryText)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.danger)
        }
    }

    @ViewBuilder private func detail(_ outcome: ExchangeText.Outcome) -> some View {
        switch outcome {
        case .succeeded(let status):
            Text("\(status) \(ExchangeText.statusName(status))").font(.caption).foregroundStyle(palette.success)
        case .stopped:
            Text("Stopped").font(.caption).foregroundStyle(palette.secondaryText)
        case .failed(let headline, let message):
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.callout.weight(.semibold))
                if !message.isEmpty { Text(message).font(.caption).lineLimit(4) }
            }
            .foregroundStyle(palette.danger)
        }
    }

    private func label(_ outcome: ExchangeText.Outcome) -> String {
        var parts = [ExchangeText.title(exchange.purpose)]
        switch outcome {
        case .succeeded(let status): parts.append("\(status) \(ExchangeText.statusName(status))")
        case .stopped: parts.append("Stopped")
        case .failed(let headline, let message): parts += ["Failed", headline, message]
        }
        if let total = exchange.stats.totalTime { parts.append("\(ExchangeText.duration(total))") }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// One request: where it went, how it ended, then its request and response text with their headers.
struct ExchangeDetail: View {
    enum Part: String, CaseIterable {
        case request = "Request"
        case response = "Response"
    }

    private struct Draft: Identifiable {
        let id = UUID()
        let text: String
    }

    let store: ChatStore
    let exchange: Exchange
    let messageID: UUID
    /// Opens the request that a resend produced.
    let show: (UUID) -> Void
    @State private var part: Part
    /// The request text, read off the main actor because a body with photos is large.
    @State private var request: ImagePlaceholders?
    @State private var requestHeadersOpen = true
    @State private var responseHeadersOpen = false
    @State private var draft: Draft?
    @State private var sending = false
    @State private var copied: String?
    @State private var copies = 0
    @Environment(\.palette) private var palette

    /// `request` is the request text when it is already at hand. Otherwise it is read as the page opens.
    init(store: ChatStore, exchange: Exchange, messageID: UUID, part: Part = .request, request: ImagePlaceholders? = nil,
         show: @escaping (UUID) -> Void) {
        self.store = store
        self.exchange = exchange
        self.messageID = messageID
        self.show = show
        _part = State(initialValue: part)
        _request = State(initialValue: request)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Picker("Show", selection: $part) {
                    ForEach(Part.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                headers
                bodyText
            }
            .padding()
        }
        .foregroundStyle(palette.text)
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .navigationTitle(ExchangeText.title(exchange.purpose))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: exchange.id) {
            guard request == nil else { return }
            let target = exchange
            request = await Task.detached { target.placeholders }.value
        }
        .sheet(item: $draft) { draft in
            ResendEditor(text: draft.text, cancel: { self.draft = nil }) { edited in
                self.draft = nil
                sending = true
                Task {
                    let sent = await store.resend(exchange, editedText: edited, for: messageID)
                    sending = false
                    show(sent.id)
                }
            }
            .theme(store.theme)
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(exchange.method) \(exchange.url.absoluteString)")
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch ExchangeText.outcome(exchange) {
            case .succeeded(let status):
                Label("\(status) \(ExchangeText.statusName(status))", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(palette.success)
            case .stopped:
                Label("Stopped", systemImage: "stop.circle").font(.callout).foregroundStyle(palette.secondaryText)
            case .failed(let headline, let message):
                VStack(alignment: .leading, spacing: 2) {
                    Label(headline, systemImage: "exclamationmark.triangle.fill").font(.callout.weight(.semibold))
                    if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
                }
                .foregroundStyle(palette.danger)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var headers: some View {
        let list = part == .request ? exchange.requestHeaders : exchange.responseHeaders
        return DisclosureGroup(isExpanded: part == .request ? $requestHeadersOpen : $responseHeadersOpen) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, header in
                    (Text(verbatim: header.name + ": ").foregroundStyle(palette.secondaryText) + Text(verbatim: header.value))
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Headers · \(list.count)").font(.subheadline).foregroundStyle(palette.secondaryText)
        }
        .disabled(list.isEmpty)
    }

    @ViewBuilder private var bodyText: some View {
        switch part {
        case .request:
            if let request { BodyText(text: request.text, empty: "No request body.") } else { ProgressView().frame(maxWidth: .infinity) }
        case .response:
            VStack(alignment: .leading, spacing: 6) {
                BodyText(text: exchange.responseBody, empty: "No response body.")
                if exchange.responseTruncated {
                    Text("The app keeps the first \(Exchange.bodyLimit / 1024) KB of a response.")
                        .font(.caption).foregroundStyle(palette.secondaryText)
                }
            }
        }
    }

    private var actions: some View {
        let copyText = part == .request ? request?.text : exchange.responseBody
        let full = HStack(spacing: 8) {
            Button { copy(copyText, as: "Copy") } label: {
                Label(copied == "Copy" ? "Copied" : "Copy", systemImage: copied == "Copy" ? "checkmark" : "doc.on.doc")
            }
            .disabled(copyText == nil)
            .accessibilityLabel(part == .request ? "Copy request" : "Copy response")
            Button { copy(exchange.curl, as: "curl") } label: {
                Label(copied == "curl" ? "Copied" : "Copy as curl", systemImage: copied == "curl" ? "checkmark" : "terminal")
            }
            Button { if let request { draft = Draft(text: request.text) } } label: {
                if sending {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sending…") }
                } else {
                    Label("Edit and Resend", systemImage: "square.and.pencil")
                }
            }
            .disabled(request == nil || sending)
        }
        return ViewThatFits(in: .horizontal) {
            full.labelStyle(.titleOnly)
            Menu {
                Button("Copy", systemImage: "doc.on.doc") { copy(copyText, as: "Copy") }.disabled(copyText == nil)
                Button("Copy as curl", systemImage: "terminal") { copy(exchange.curl, as: "curl") }
                Button("Edit and Resend", systemImage: "square.and.pencil") { if let request { draft = Draft(text: request.text) } }
                    .disabled(request == nil || sending)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .sensoryFeedback(.success, trigger: copies)
    }

    private func copy(_ text: String?, as kind: String) {
        guard let text else { return }
        copyToPasteboard(text)
        copied = kind
        copies += 1
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == kind { copied = nil }
        }
    }
}

/// Monospaced, selectable text that stays cheap to draw however long it is: past `TextPreview.limit` characters it
/// shows the start and the end and says how much it left out. Copy takes the whole text.
struct BodyText: View {
    let text: String
    let empty: String
    var limit = TextPreview.limit
    @Environment(\.palette) private var palette

    var body: some View {
        let preview = TextPreview(text, limit: limit)
        VStack(alignment: .leading, spacing: 8) {
            if text.isEmpty {
                Text(empty).font(.callout).foregroundStyle(palette.secondaryText)
            } else {
                Text(verbatim: preview.head).font(.footnote.monospaced())
                if preview.omitted > 0 {
                    Text("\(ExchangeText.count(preview.omitted)) characters not shown. Copy has all of it.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                        .padding(.vertical, 2)
                    Text(verbatim: preview.tail).font(.footnote.monospaced())
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A plain text editor on a request's body. Photos show as tokens like `<image 1: 312 KB>`, and a token left
/// in place goes back out as its photo.
struct ResendEditor: View {
    @State var text: String
    let cancel: () -> Void
    let send: (String) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.footnote.monospaced())
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding()
                .foregroundStyle(palette.text)
                .background(palette.groupedBackground)
                .navigationTitle("Edit and Resend")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                    ToolbarItem(placement: .confirmationAction) { Button("Send") { send(text) } }
                }
        }
    }
}
