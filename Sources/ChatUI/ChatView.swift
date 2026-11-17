import ChatCore
import PhotosUI
import QuickLook
import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatStore
    let conversation: Conversation
    @State private var draft = ""
    @State private var draftImages: [ImageID] = []
    /// The sent message being rewritten, and the draft it pushed aside.
    @State private var editing: (id: UUID, stash: (text: String, images: [ImageID]))?
    @FocusState private var composerFocused: Bool
    @State private var atBottom = true
    @State private var follow = Follow.following
    @State private var inspecting: InspectedReply?
    @Environment(\.palette) private var palette

    private var live: Conversation { store.selectedConversation ?? conversation }
    private var streaming: Bool { store.isStreaming(live.id) }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if let message = store.failureMessage(for: live.id) {
                let failed = store.failedReply.flatMap { store.exchanges(for: $0).isEmpty ? nil : $0 }
                ErrorBanner(message: message, retry: store.retry, dismiss: store.dismissFailure,
                            inspect: failed.map { id in { inspecting = InspectedReply(id: id) } })
            }
            Composer(draft: $draft, images: $draftImages, store: store.images, focused: $composerFocused, streaming: streaming,
                     canSend: store.canSend, editing: editing != nil, unavailable: store.unavailableReason,
                     send: send, stop: store.stop, cancelEdit: cancelEdit)
        }
        .foregroundStyle(palette.text)
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(live.title)
        .themedNavigationBar()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .primaryAction) { ModelButton(store: store) } }
        .sheet(item: $inspecting) { InspectorSheet(store: store, messageID: $0.id).theme(store.theme) }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    let erased = editing.flatMap { edit in live.messages.firstIndex { $0.id == edit.id } }
                    ForEach(Array(live.messages.enumerated()), id: \.element.id) { index, message in
                        let isLive = streaming && message.id == live.messages.last?.id
                        let exchanges = store.exchanges(for: message.id)
                        MessageRow(message: message, images: store.images, isStreaming: isLive, reply: isLive ? store.liveReply : nil,
                                   edit: store.canSend ? { beginEditing(message) } : nil,
                                   approval: isLive ? store.awaitingApproval : nil, resolve: store.resolveApproval,
                                   stats: ExchangeText.reply(in: exchanges).flatMap { ExchangeText.statsLine($0) },
                                   inspect: exchanges.isEmpty ? nil : { inspecting = InspectedReply(id: message.id) })
                            .opacity(erased.map { index > $0 } == true ? 0.35 : 1)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { if !FollowStream.supported { atBottom = true } }
                        .onDisappear { if !FollowStream.supported { atBottom = false } }
                }
                .padding()
                .animation(.smooth(duration: 0.35), value: live.messages.count)
                .disclosureGroupStyle(HeaderOnTop { opened in
                    guard FollowStream.supported else { return }
                    if opened, follow == .following {
                        follow = .reading
                    } else if !opened, follow == .reading {
                        follow = .following
                        scrollToBottom(proxy)
                    }
                })
            }
            .modifier(FollowStream(atBottom: $atBottom, follow: $follow) { scrollToBottom(proxy) })
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .overlay {
                if live.messages.isEmpty {
                    ContentUnavailableView("Start chatting", systemImage: "bubble.left",
                                           description: Text(store.isConfigured
                                                             ? "Type a message below."
                                                             : "Add a server in Settings first."))
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .overlay(alignment: .bottom) {
                if scrolledAway && !live.messages.isEmpty {
                    JumpToLatest {
                        follow = .following
                        scrollToBottom(proxy)
                    }
                        .padding(.bottom, 12)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: scrolledAway)
            .onChange(of: FollowStream.supported ? 0 : store.liveReply?.content.utf8.count ?? 0) {
                if !FollowStream.supported && atBottom { proxy.scrollTo("bottom") }
            }
            .onChange(of: live.messages.count) {
                follow = .following
                scrollToBottom(proxy)
            }
        }
    }

    /// The reader moved away from the newest text. Being briefly off the bottom during an eased scroll doesn't count.
    private var scrolledAway: Bool {
        guard FollowStream.supported else { return !atBottom }
        switch follow {
        case .following: return false
        case .reading: return !atBottom
        case .away: return true
        }
    }

    /// Matches the reply bubble's height easing so a new line and the scroll move together.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func send() {
        if let editing {
            store.edit(editing.id, to: draft, images: draftImages)
            (draft, draftImages) = editing.stash
            self.editing = nil
        } else if let (command, argument) = SlashCommand.parse(draft) {
            store.run(command, argument: argument)
            draft = ""
        } else {
            store.send(draft, images: draftImages)
            draft = ""
            draftImages = []
        }
    }

    private func beginEditing(_ message: ChatMessage) {
        let stash = editing?.stash ?? (draft, draftImages)
        withAnimation(.snappy(duration: 0.2)) { editing = (message.id, stash) }
        draft = message.content
        draftImages = message.images
        composerFocused = true
    }

    private func cancelEdit() {
        guard let editing else { return }
        (draft, draftImages) = editing.stash
        withAnimation(.snappy(duration: 0.2)) { self.editing = nil }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let images: ImageStore
    let isStreaming: Bool
    let reply: LiveReply?
    /// nil while a reply is streaming, when the message can't be changed.
    let edit: (() -> Void)?
    /// The tool call in this message waiting to be allowed.
    let approval: String?
    let resolve: (Bool) -> Void
    /// What the reply's request cost, when its server reported it.
    let stats: String?
    /// nil when the reply has no requests to show.
    let inspect: (() -> Void)?
    @Environment(\.palette) private var palette

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    if message.search != nil {
                        Label("Web search", systemImage: "globe")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)
                    }
                    if !message.images.isEmpty { SentImages(images: message.images.map(images.url)) }
                    if !message.content.isEmpty {
                        Text(message.content)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(palette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .foregroundStyle(palette.onAccent)
                    }
                    if let results = message.search?.results, !results.isEmpty { SearchSources(results: results) }
                }
                #if os(iOS)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
                #endif
                .contextMenu {
                    if let edit { Button("Edit", systemImage: "pencil", action: edit) }
                    if !message.content.isEmpty {
                        Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(message.content) }
                    }
                }
            }
        case .assistant:
            HStack {
                AssistantBubble(message: message, images: message.images.map(images.url), isStreaming: isStreaming, reply: reply,
                                approval: approval, resolve: resolve, stats: stats, inspect: inspect)
                Spacer(minLength: 48)
            }
        case .summary:
            SummaryCard(message: message, isStreaming: isStreaming, reply: reply)
        case .system:
            EmptyView()
        }
    }
}

private struct AssistantBubble: View {
    let message: ChatMessage
    /// Pictures an image model drew for this reply.
    let images: [URL]
    let isStreaming: Bool
    let reply: LiveReply?
    let approval: String?
    let resolve: (Bool) -> Void
    let stats: String?
    let inspect: (() -> Void)?
    @State private var thinkingOverride: Bool?

    private var content: String { reply?.content ?? message.content }
    private var reasoning: String { reply?.reasoning ?? message.reasoning }
    private var toolCalls: [ToolCall] { reply?.toolCalls ?? message.toolCalls }
    @Environment(\.palette) private var palette

    private var thinkingExpanded: Binding<Bool> {
        Binding(
            get: { thinkingOverride ?? false },
            set: { thinkingOverride = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !reasoning.isEmpty {
                DisclosureGroup(isExpanded: thinkingExpanded) {
                    Paced(text: reasoning, live: isStreaming) { text, unfinished in
                        ParagraphText(text: text, latestOnly: unfinished)
                            .font(.callout)
                            .foregroundStyle(palette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                } label: {
                    ThinkingLabel(reasoning: reasoning,
                                  live: isStreaming && content.isEmpty && !thinkingExpanded.wrappedValue)
                }
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
            }
            if !content.isEmpty {
                Paced(text: content, live: isStreaming) { text, unfinished in
                    MarkdownView(text: unfinished ? Markdown.completingPartial(text) : text)
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                }
            }
            ForEach(images, id: \.self) { GeneratedImage(url: $0) }
            if !toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(toolCalls) { call in
                        ToolCallRow(call: call, running: isStreaming, awaiting: call.id == approval, resolve: resolve)
                    }
                }
            }
            if isStreaming, let status = reply?.status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout).foregroundStyle(palette.secondaryText)
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            } else if content.isEmpty && isStreaming && reasoning.isEmpty && toolCalls.isEmpty {
                TypingDots().transition(.opacity)
            }
            let notes = message.adaptations.map(\.note) + (message.interrupted ? ["Interrupted. The app closed before the reply finished."] : [])
            if !notes.isEmpty { Notes(notes: notes) }
            if !isStreaming, let stats, let inspect { StatsLine(text: stats, action: inspect) }
        }
        .contextMenu {
            if !content.isEmpty { Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(content) } }
            if let inspect { Button("Inspect", systemImage: "list.bullet.rectangle", action: inspect) }
        }
    }
}

/// What the app changed about the request behind a reply, one quiet line each.
private struct Notes: View {
    let notes: [String]
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "info.circle").accessibilityHidden(true)
                    Text(note)
                }
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// How fast the reply came, as one line. Tap for the requests behind it.
private struct StatsLine: View {
    let text: String
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(text).multilineTextAlignment(.leading)
                Image(systemName: "chevron.right").imageScale(.small).accessibilityHidden(true)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(palette.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Request details")
        .accessibilityValue(text)
        .accessibilityHint("Shows the requests behind this reply")
    }
}

/// A picture the model drew. Tap to see it full screen. Hold to share it or save it to Photos.
private struct GeneratedImage: View {
    let url: URL
    @State private var preview: URL?

    var body: some View {
        Button { preview = url } label: {
            AttachmentImage(url: url, maxPixels: 1024)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: 320, maxHeight: 420, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Generated image")
        .contextMenu {
            ShareLink(item: url) { Label("Share or Save", systemImage: "square.and.arrow.up") }
        }
        .quickLookPreview($preview)
    }
}

/// One tool the model called: what it ran, how it went, and on tap the arguments and result.
struct ToolCallRow: View {
    let call: ToolCall
    let running: Bool
    let awaiting: Bool
    let resolve: (Bool) -> Void
    @State private var expanded = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(palette.secondaryText)
                    (Text(call.server.isEmpty ? "" : call.server + " · ").foregroundStyle(palette.secondaryText)
                        + Text(call.name).foregroundStyle(palette.text))
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    state
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tool \(call.name)")
            .accessibilityValue(stateLabel)

            if awaiting {
                VStack(alignment: .leading, spacing: 8) {
                    let ask = call.approval
                    Text(ask.question).font(.caption).foregroundStyle(palette.secondaryText)
                    if let address = ask.address {
                        Text(address)
                            .font(.caption.monospaced())
                            .foregroundStyle(palette.text)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        Button("Allow") { resolve(true) }
                            .buttonStyle(.borderedProminent).tint(palette.accent)
                        Button("Decline") { resolve(false) }
                            .buttonStyle(.bordered).tint(palette.secondaryText)
                    }
                    .font(.callout.weight(.semibold))
                }
                .transition(.opacity)
            }
            if expanded {
                detail("Arguments", call.arguments)
                if let result = call.result { detail(result.isError ? "Error" : "Result", result.text) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var state: some View {
        if let result = call.result {
            Image(systemName: result.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(result.isError ? palette.danger : palette.success)
        } else if awaiting {
            Image(systemName: "hand.raised.fill").foregroundStyle(palette.accent)
        } else if running {
            ProgressView().controlSize(.small)
        } else {
            Text("Cancelled").font(.caption).foregroundStyle(palette.secondaryText)
        }
    }

    private var stateLabel: String {
        if let result = call.result { return result.isError ? "Failed" : "Done" }
        return awaiting ? "Waiting for approval" : running ? "Running" : "Cancelled"
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(palette.secondaryText)
            Text(text.count > 2000 ? text.prefix(2000) + "…" : text)
                .font(.caption.monospaced())
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
        }
    }
}

/// The pages a `/web-search` found, folded under the question until tapped.
private struct SearchSources: View {
    let results: [WebSearch.Result]
    @State private var expanded = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                Label("\(results.count) source\(results.count == 1 ? "" : "s")",
                      systemImage: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.accent)
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                        Link(destination: result.link) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(palette.secondaryText)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.title).font(.callout).foregroundStyle(palette.text).lineLimit(2)
                                    Text(result.link.host() ?? result.link.absoluteString)
                                        .font(.caption).foregroundStyle(palette.accent).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: 300)
                .background(palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Marks where `/compact` replaced the history. The summary stays folded away unless asked for.
private struct SummaryCard: View {
    let message: ChatMessage
    let isStreaming: Bool
    let reply: LiveReply?
    @State private var expanded = false
    @Environment(\.palette) private var palette

    private var content: String { reply?.content ?? message.content }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                line
                Label(isStreaming ? "Compacting…" : "Chat compacted", systemImage: "rectangle.compress.vertical")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize()
                line
            }
            DisclosureGroup(isExpanded: $expanded) {
                Paced(text: content, live: isStreaming) { text, unfinished in
                    MarkdownView(text: unfinished ? Markdown.completingPartial(text) : text)
                        .font(.callout)
                        .foregroundStyle(palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.top, 6)
            } label: {
                Text(isStreaming ? "Writing a summary of the chat so far" : "Earlier messages are summarized for the model")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(12)
            .background(palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.vertical, 4)
        .contextMenu {
            if !content.isEmpty { Button("Copy Summary", systemImage: "doc.on.doc") { copyToPasteboard(content) } }
        }
    }

    private var line: some View {
        Rectangle().fill(palette.secondaryText.opacity(0.3)).frame(height: 0.5)
    }
}

/// The system style lays the content over the header for touches, and selectable text takes touches from a
/// little beyond its frame, so the lower half of an open header ignored taps. This one keeps the header on top.
/// `toggled` tells the chat, which holds the list still while a section it was following is open.
private struct HeaderOnTop: DisclosureGroupStyle {
    let toggled: (_ opened: Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        Stack(configuration: configuration, toggled: toggled)
    }

    private struct Stack: View {
        let configuration: Configuration
        let toggled: (Bool) -> Void
        @Environment(\.palette) private var palette

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    let open = !configuration.isExpanded
                    toggled(open)
                    withAnimation(.snappy(duration: 0.2)) { configuration.isExpanded = open }
                } label: {
                    HStack {
                        configuration.label
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.text)
                            .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                .zIndex(1)
                if configuration.isExpanded {
                    configuration.content
                }
            }
        }
    }
}

/// Reveals streamed text at a steady pace. Text that existed before the view appeared shows at once.
private struct Paced<Content: View>: View {
    let text: String
    let live: Bool
    /// Receives the visible text and whether it is still unfinished (streaming, or not yet fully revealed).
    @ViewBuilder let content: (String, Bool) -> Content
    @State private var shown: Int?
    @State private var height: CGFloat?

    init(text: String, live: Bool, @ViewBuilder content: @escaping (String, Bool) -> Content) {
        self.text = text
        self.live = live
        self.content = content
        _shown = State(initialValue: live ? 0 : nil)
    }

    var body: some View {
        content(shown.map { String(text.prefix($0)) } ?? text, live || (shown ?? text.count) < text.count)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                guard shown != nil, height != nil else { height = newHeight; return }
                withAnimation(.smooth(duration: 0.25)) { height = newHeight }
            }
            // While revealing, the frame eases to each new line's height so the pinned scroll slides rather than steps.
            .frame(height: shown == nil ? nil : height, alignment: .top)
            .clipped()
            .task(id: text.count) {
                guard let start = shown, start != text.count else { return }
                var pacer = RevealPacer(shown: start)
                var last = ContinuousClock.now
                while !Task.isCancelled, pacer.shown != text.count {
                    try? await Task.sleep(for: .milliseconds(16))
                    let now = ContinuousClock.now
                    let elapsed = now - last
                    last = now
                    shown = pacer.advance(toward: text.count,
                                          elapsed: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
                }
            }
    }
}

/// Long reasoning as one Text is laid out again in full on every token. Settled paragraphs keep their layout.
/// While streaming, only the latest stretch is shown so each update costs the same however long the model thinks.
private struct ParagraphText: View {
    let text: String
    let latestOnly: Bool

    var body: some View {
        let shown = latestOnly ? Paragraphs.tail(text) : text[...]
        VStack(alignment: .leading, spacing: 8) {
            if shown.count < text.count {
                Text("Showing latest thinking").font(.caption2).italic()
            }
            ForEach(Array(Paragraphs.split(String(shown)).enumerated()), id: \.offset) { _, piece in
                Text(piece)
            }
        }
    }
}

/// Collapsed by default. While the model is still thinking it previews the newest line, so the block keeps
/// a fixed height instead of expanding and then collapsing under the reader when the answer starts.
private struct ThinkingLabel: View {
    let reasoning: String
    let live: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(live ? "Thinking…" : "Thinking")
            if live {
                Text(reasoning.suffix(160).replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(palette.secondaryText.opacity(0.8))
            }
        }
    }
}

private struct TypingDots: View {
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(palette.secondaryText)
                    .frame(width: 7, height: 7)
                    .phaseAnimator([0.3, 1.0]) { dot, phase in
                        dot.opacity(phase).scaleEffect(0.7 + 0.3 * phase)
                    } animation: { _ in
                        .easeInOut(duration: 0.5).delay(Double(index) * 0.15)
                    }
            }
        }
        .padding(.vertical, 6)
        .accessibilityLabel("Waiting for reply")
    }
}

/// Whether the chat keeps the newest text in view.
private enum Follow {
    case following
    /// The reader opened a section while following. The list holds still so its header stays put, and closing it follows again.
    case reading
    /// The reader dragged the list.
    case away
}

/// Follows a growing reply until the reader drags the list, and resumes once they are back at the bottom.
/// Following is explicit state rather than a size-change anchor, because an anchor only holds while the
/// view is exactly at the bottom and one animated scroll that ends short loses it for the rest of the reply.
/// iOS 17 lacks scroll geometry and phases, so ChatView falls back to a sentinel row and scrollTo.
private struct FollowStream: ViewModifier {
    @Binding var atBottom: Bool
    @Binding var follow: Follow
    let scrollToBottom: () -> Void

    static var supported: Bool {
        if #available(iOS 18, macOS 15, *) { true } else { false }
    }

    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            // No anchor for size changes. It pinned the bottom even after the reader stopped following, so opening a
            // section near the bottom pushed its header off the top.
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .alignment)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 60
                } action: { _, isAtBottom in
                    atBottom = isAtBottom
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height - geometry.containerSize.height
                } action: { old, new in
                    if follow == .following && new != old { scrollToBottom() }
                }
                .onScrollPhaseChange { _, phase in
                    switch phase {
                    case .interacting: follow = .away
                    case .idle: if atBottom, follow == .away { follow = .following }
                    default: break
                    }
                }
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

private struct JumpToLatest: View {
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 40, height: 40)
                .background(palette.surface, in: Circle())
                .overlay(Circle().strokeBorder(palette.secondaryText.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to latest")
    }
}

private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void
    let dismiss: () -> Void
    /// nil when no request was kept for the failure.
    var inspect: (() -> Void)?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.danger)
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.callout)
                if let inspect {
                    Button("Inspect request", systemImage: "list.bullet.rectangle", action: inspect)
                        .font(.callout).buttonStyle(.plain).foregroundStyle(palette.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry).buttonStyle(.bordered)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly).buttonStyle(.plain)
        }
        .padding(10)
        .background(palette.danger.opacity(0.12))
    }
}

private struct Composer: View {
    @Binding var draft: String
    @Binding var images: [ImageID]
    let store: ImageStore
    var focused: FocusState<Bool>.Binding
    let streaming: Bool
    let canSend: Bool
    let editing: Bool
    let unavailable: (SlashCommand) -> String?
    let send: () -> Void
    let stop: () -> Void
    let cancelEdit: () -> Void
    @State private var picks: [PhotosPickerItem] = []
    @State private var loading = 0
    /// One line of body text plus the field's vertical padding, so both buttons are exactly as tall as the empty field.
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 38
    @Environment(\.palette) private var palette

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }
    /// Commands aren't run from an edit, which always resends the text as written.
    private var parsed: (command: SlashCommand, argument: String)? { editing ? nil : SlashCommand.parse(draft) }
    private var commandReady: Bool {
        guard let parsed else { return true }
        return unavailable(parsed.command) == nil && !(parsed.command.needsArgument && parsed.argument.isEmpty)
    }
    private var suggestions: [SlashCommand] { editing ? [] : SlashCommand.suggestions(for: draft) }
    private var room: Int { ImageAttachment.limit - images.count - loading }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editing { editingBar }
            if !suggestions.isEmpty { commandList }
            if !images.isEmpty || loading > 0 { attachments }
            HStack(alignment: .bottom, spacing: 8) {
                let plus = CircleIcon(systemImage: "plus", size: height,
                                      foreground: room > 0 ? palette.text : palette.secondaryText,
                                      background: palette.fill)
                PhotosPicker(selection: $picks, maxSelectionCount: max(room, 1), selectionBehavior: .ordered,
                             matching: .images) {
                    Label { Text("Add Photos") } icon: { plus }.labelStyle(.iconOnly)
                }
                .disabled(room <= 0)
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused(focused)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(minHeight: height)
                    .foregroundStyle(palette.text)
                    .background(palette.fill, in: RoundedRectangle(cornerRadius: height / 2, style: .continuous))
                if streaming {
                    Button(action: stop) {
                        Label { Text("Stop") } icon: {
                            CircleIcon(systemImage: "stop.fill", size: height, foreground: .white, background: palette.danger)
                        }
                        .labelStyle(.iconOnly)
                    }
                } else {
                    let ready = canSend && !isEmpty && loading == 0 && commandReady
                    Button(action: send) {
                        Label { Text("Send") } icon: {
                            CircleIcon(systemImage: "arrow.up", size: height, foreground: palette.onAccent,
                                       background: palette.accent.opacity(ready ? 1 : 0.4))
                        }
                        .labelStyle(.iconOnly)
                    }
                    .disabled(!ready)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal).padding(.vertical, 8)
        .background(palette.background)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.secondaryText.opacity(0.3)).frame(height: 0.5)
        }
        .onChange(of: picks) { load() }
    }

    private var commandList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.self) { command in
                let reason = unavailable(command)
                Button {
                    if !draft.contains(where: \.isWhitespace) { draft = command.name + " " }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(command.name).font(.body.monospaced().weight(.semibold))
                                .foregroundStyle(reason == nil ? palette.accent : palette.secondaryText)
                            Text(command.argumentHint).font(.callout.monospaced()).foregroundStyle(palette.secondaryText)
                        }
                        Text(reason ?? command.summary).font(.caption)
                            .foregroundStyle(reason == nil ? palette.secondaryText : palette.danger)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(command.name)
                .accessibilityHint(reason ?? command.summary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var editingBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil").foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Editing message").font(.subheadline.weight(.semibold))
                Text("Sending replaces everything after it.").font(.caption).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            Button("Cancel", action: cancelEdit).font(.subheadline).foregroundStyle(palette.accent)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var attachments: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.element) { index, id in
                    AttachmentImage(url: store.url(for: id), maxPixels: 240)
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Photo \(index + 1)")
                        .overlay(alignment: .topTrailing) {
                            Button("Remove photo \(index + 1)", systemImage: "xmark.circle.fill") {
                                images.remove(at: index)
                            }
                            .labelStyle(.iconOnly)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .padding(4)
                        }
                }
                ForEach(0..<loading, id: \.self) { _ in
                    ProgressView()
                        .frame(width: 64, height: 64)
                        .background(palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func load() {
        let items = picks
        guard !items.isEmpty else { return }
        picks = []
        loading += items.count
        Task {
            for item in items {
                let data = try? await item.loadTransferable(type: Data.self)
                let id = await Task.detached { [store] in
                    data.flatMap { ImageAttachment.jpeg(from: $0) }.flatMap { try? store.save($0) }
                }.value
                loading -= 1
                if let id { images.append(id) }
            }
        }
    }
}

private struct CircleIcon: View {
    let systemImage: String
    let size: CGFloat
    let foreground: Color
    let background: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background, in: Circle())
    }
}

/// A sent message's photos, one fitted to the bubble width or a row of squares when there are several.
private struct SentImages: View {
    let images: [URL]

    var body: some View {
        if images.count == 1 {
            AttachmentImage(url: images[0])
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: 240, maxHeight: 320, alignment: .trailing)
                .accessibilityLabel("Photo")
        } else {
            LazyVGrid(columns: [GridItem(.fixed(116)), GridItem(.fixed(116))], alignment: .trailing, spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.element) { index, url in
                    AttachmentImage(url: url, maxPixels: 360)
                        .scaledToFill()
                        .frame(width: 116, height: 116)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Photo \(index + 1)")
                }
            }
            .frame(width: 238)
        }
    }
}

private struct ModelButton: View {
    let store: ChatStore
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Label(store.model.isEmpty ? "Model" : store.model, systemImage: "cpu")
        }
        .accessibilityLabel("Model and reasoning")
        .popover(isPresented: $open) {
            ModelPanel(store: store).presentationCompactAdaptation(.popover)
        }
    }
}

private struct ModelPanel: View {
    let store: ChatStore
    @Environment(\.palette) private var palette
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Model").font(.headline)
                Spacer()
                Button("Refresh Models", systemImage: "arrow.clockwise") { Task { await store.refreshModels() } }
                    .labelStyle(.iconOnly)
            }
            // A popover sizes to its content's ideal height, so a long list (OpenAI lists ~100) must be
            // capped explicitly or the popover grows to the full screen.
            ScrollViewReader { proxy in
                ScrollView {
                    modelList.onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                }
                .frame(height: min(max(listHeight, 1), 280))
                .scrollBounceBehavior(.basedOnSize)
                .onAppear { proxy.scrollTo(store.model, anchor: .center) }
            }
            Divider().overlay(palette.secondaryText.opacity(0.3))
            effortSection
        }
        .padding()
        .frame(width: 320)
        .foregroundStyle(palette.text)
        .sensoryFeedback(.selection, trigger: store.reasoningEffort)
    }

    @ViewBuilder private var effortSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reasoning effort").font(.headline)
                Spacer()
                effortStatus
            }
            if case .known(let levels) = store.effortLevels, levels.count > 1, let selection = store.reasoningEffort {
                EffortSlider(levels: levels, selection: selection, select: store.setReasoningEffort)
            } else if store.effortLevels == .checking {
                Capsule().fill(palette.secondaryText.opacity(0.12)).frame(height: EffortSlider.trackHeight)
            }
        }
        .animation(.snappy, value: store.effortLevels)
    }

    @ViewBuilder private var effortStatus: some View {
        switch store.effortLevels {
        case .checking:
            ProgressView().accessibilityLabel("Checking effort levels")
        case .failed:
            Button("Retry", systemImage: "arrow.clockwise", action: store.checkEffortLevels)
                .font(.callout)
                .accessibilityLabel("Retry checking effort levels")
        case .known(let levels):
            if let effort = store.reasoningEffort {
                Text(effort.label)
                    .foregroundStyle(levels.count > 1 ? palette.accent : palette.secondaryText)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: effort)
            } else {
                Text("Not adjustable").foregroundStyle(palette.secondaryText)
            }
        }
    }

    @ViewBuilder private var modelList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.availableModels.isEmpty {
                Text(store.model.isEmpty ? "No models loaded. Check the server in Settings." : store.model)
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
            }
            ForEach(store.availableModels, id: \.self) { id in
                Button { store.selectModel(id) } label: {
                    HStack {
                        Text(id).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if id == store.model { Image(systemName: "checkmark").foregroundStyle(palette.accent) }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(id)
            }
        }
    }
}

/// A capsule track holding a round knob that snaps to one dot per level, with each label centred under its dot.
private struct EffortSlider: View {
    static let trackHeight: CGFloat = 34
    private static let inset: CGFloat = 3
    private static let glide = Animation.snappy(duration: 0.2)

    let levels: [ReasoningEffort]
    let selection: ReasoningEffort
    let select: (ReasoningEffort) -> Void
    @Environment(\.palette) private var palette
    /// Where the finger holds the knob. nil when the knob rests on the selected level.
    @State private var dragX: CGFloat?

    private var selectedIndex: Int { levels.firstIndex(of: selection) ?? 0 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let knobX = dragX ?? x(selectedIndex, width)
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(palette.secondaryText.opacity(0.15))
                    .frame(height: Self.trackHeight)
                Capsule()
                    .fill(palette.accent)
                    .frame(width: knobX + Self.trackHeight / 2, height: Self.trackHeight)
                ForEach(levels.indices, id: \.self) { index in
                    Circle()
                        .fill(x(index, width) < knobX ? palette.onAccent.opacity(0.5) : palette.secondaryText.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .position(x: x(index, width), y: Self.trackHeight / 2)
                    Text(levels[index].label)
                        .font(.caption)
                        .foregroundStyle(index == selectedIndex ? palette.accent : palette.secondaryText)
                        .fixedSize()
                        .position(x: x(index, width), y: Self.trackHeight + 14)
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: Self.trackHeight - 2 * Self.inset, height: Self.trackHeight - 2 * Self.inset)
                    .position(x: knobX, y: Self.trackHeight / 2)
            }
            // Glide when the level changes without a finger on the knob (VoiceOver). While dragging the knob
            // tracks the finger exactly, since an animation there makes it trail behind.
            .animation(dragX == nil ? Self.glide : nil, value: selection)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let lo = x(0, width), hi = x(levels.count - 1, width)
                        let clamped = min(max(drag.location.x, lo), hi)
                        if dragX == nil {
                            withAnimation(Self.glide) { dragX = clamped }
                        } else {
                            dragX = clamped
                        }
                        let nearest = Int(((clamped - lo) / step(width)).rounded())
                        if levels[nearest] != selection { select(levels[nearest]) }
                    }
                    .onEnded { _ in withAnimation(Self.glide) { dragX = nil } }
            )
        }
        .frame(height: Self.trackHeight + 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(selection.label)
        .accessibilityAdjustableAction { direction in
            let index = selectedIndex + (direction == .increment ? 1 : -1)
            if levels.indices.contains(index) { select(levels[index]) }
        }
    }

    private func step(_ width: CGFloat) -> CGFloat {
        (width - Self.trackHeight) / CGFloat(levels.count - 1)
    }

    private func x(_ index: Int, _ width: CGFloat) -> CGFloat {
        Self.trackHeight / 2 + CGFloat(index) * step(width)
    }
}

extension ReasoningEffort {
    var label: String {
        switch self {
        case .none: "Off"
        case .xhigh: "X-High"
        default: rawValue.capitalized
        }
    }
}
