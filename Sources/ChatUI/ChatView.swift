import ChatCore
import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatStore
    let conversation: Conversation
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var atBottom = true
    @State private var following = true
    @Environment(\.palette) private var palette

    private var live: Conversation { store.selectedConversation ?? conversation }
    private var streaming: Bool { store.isStreaming(live.id) }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if let message = store.failureMessage(for: live.id) {
                ErrorBanner(message: message, retry: store.retry, dismiss: store.dismissFailure)
            }
            Composer(draft: $draft, focused: $composerFocused, streaming: streaming, canSend: store.canSend,
                     send: send, stop: store.stop)
        }
        .foregroundStyle(palette.text)
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(live.title)
        .themedNavigationBar()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .primaryAction) { ModelButton(store: store) } }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(live.messages) { message in
                        let isLive = streaming && message.id == live.messages.last?.id
                        MessageRow(message: message, isStreaming: isLive, reply: isLive ? store.liveReply : nil)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { if !FollowStream.supported { atBottom = true } }
                        .onDisappear { if !FollowStream.supported { atBottom = false } }
                }
                .padding()
                .animation(.smooth(duration: 0.35), value: live.messages.count)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(FollowStream(atBottom: $atBottom, following: $following) { scrollToBottom(proxy) })
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
                        following = true
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
                following = true
                scrollToBottom(proxy)
            }
        }
    }

    /// The reader moved away from the newest text. Being briefly off the bottom during an eased scroll doesn't count.
    private var scrolledAway: Bool { FollowStream.supported ? !following : !atBottom }

    /// Matches the reply bubble's height easing so a new line and the scroll move together.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func send() {
        store.send(draft)
        draft = ""
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    let reply: LiveReply?
    @Environment(\.palette) private var palette

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(palette.onAccent)
                    .contextMenu { Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(message.content) } }
            }
        case .assistant:
            HStack {
                AssistantBubble(message: message, isStreaming: isStreaming, reply: reply)
                Spacer(minLength: 48)
            }
        case .system:
            EmptyView()
        }
    }
}

private struct AssistantBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    let reply: LiveReply?
    @State private var thinkingOverride: Bool?

    private var content: String { reply?.content ?? message.content }
    private var reasoning: String { reply?.reasoning ?? message.reasoning }
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
            } else if isStreaming && reasoning.isEmpty {
                TypingDots().transition(.opacity)
            }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(content) }
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

/// Follows a growing reply until the reader drags the list, and resumes once they are back at the bottom.
/// Following is explicit state rather than a size-change anchor, because an anchor only holds while the
/// view is exactly at the bottom and one animated scroll that ends short loses it for the rest of the reply.
/// iOS 17 lacks scroll geometry and phases, so ChatView falls back to a sentinel row and scrollTo.
private struct FollowStream: ViewModifier {
    @Binding var atBottom: Bool
    @Binding var following: Bool
    let scrollToBottom: () -> Void

    static var supported: Bool {
        if #available(iOS 18, macOS 15, *) { true } else { false }
    }

    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 60
                } action: { _, isAtBottom in
                    atBottom = isAtBottom
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height - geometry.containerSize.height
                } action: { old, new in
                    if following && new != old { scrollToBottom() }
                }
                .onScrollPhaseChange { _, phase in
                    switch phase {
                    case .interacting: following = false
                    case .idle: if atBottom { following = true }
                    default: break
                    }
                }
        } else {
            content
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
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.danger)
            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
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
    var focused: FocusState<Bool>.Binding
    let streaming: Bool
    let canSend: Bool
    let send: () -> Void
    let stop: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused(focused)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(palette.text)
                .background(palette.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if streaming {
                Button("Stop", systemImage: "stop.circle.fill", action: stop)
                    .labelStyle(.iconOnly).font(.title)
                    .foregroundStyle(palette.danger)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly).font(.title)
                    .foregroundStyle(palette.accent)
                    .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal).padding(.vertical, 8)
        .background(palette.background)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.secondaryText.opacity(0.3)).frame(height: 0.5)
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

    /// Slider positions, ordered by how much the model thinks. nil omits the field, which is the server's own default.
    private static let detents: [ReasoningEffort?] = [.low, .medium, nil]

    private var detent: Binding<Double> {
        Binding(
            get: { Double(Self.detents.firstIndex(of: store.reasoningEffort) ?? Self.detents.count - 1) },
            set: { store.setReasoningEffort(Self.detents[Int($0.rounded())]) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Model").font(.headline)
                Spacer()
                Button("Refresh Models", systemImage: "arrow.clockwise") { Task { await store.refreshModels() } }
                    .labelStyle(.iconOnly)
            }
            ViewThatFits(in: .vertical) {
                modelList
                ScrollView { modelList }.frame(maxHeight: 240)
            }
            Divider().overlay(palette.secondaryText.opacity(0.3))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Reasoning effort").font(.headline)
                    Spacer()
                    Text(store.reasoningEffort?.rawValue.capitalized ?? "Server default")
                        .foregroundStyle(palette.accent)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: store.reasoningEffort)
                }
                Slider(value: detent, in: 0...Double(Self.detents.count - 1), step: 1)
                    .accessibilityLabel("Reasoning effort")
                    .accessibilityValue(store.reasoningEffort?.rawValue.capitalized ?? "Server default")
                HStack {
                    Text("Low")
                    Spacer()
                    Text("Medium")
                    Spacer()
                    Text("Server default")
                }
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                Text("Lower effort answers sooner. Server default leaves the choice to the server.")
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .padding()
        .frame(width: 320)
        .foregroundStyle(palette.text)
        .presentationBackground(palette.surface)
        .sensoryFeedback(.selection, trigger: store.reasoningEffort)
    }

    @ViewBuilder private var modelList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.availableModels.isEmpty {
                Text(store.model.isEmpty ? "No models loaded. Check the server in Settings." : store.model)
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
            }
            ForEach(store.availableModels, id: \.self) { id in
                Button { store.updatePreferences(model: id) } label: {
                    HStack {
                        Text(id).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if id == store.model { Image(systemName: "checkmark").foregroundStyle(palette.accent) }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
