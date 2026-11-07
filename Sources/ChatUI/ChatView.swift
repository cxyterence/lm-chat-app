import ChatCore
import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatStore
    let conversation: Conversation
    @State private var draft = ""

    private var live: Conversation { store.selectedConversation ?? conversation }
    private var streaming: Bool { store.isStreaming(live.id) }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if let message = store.failureMessage(for: live.id) {
                ErrorBanner(message: message, retry: store.retry, dismiss: store.dismissFailure)
            }
            Composer(draft: $draft, streaming: streaming, canSend: store.canSend,
                     send: send, stop: store.stop)
        }
        .navigationTitle(live.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .primaryAction) { ModelMenu(store: store) } }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(live.messages) { message in
                        MessageRow(message: message,
                                   isStreaming: streaming && message.id == live.messages.last?.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .overlay {
                if live.messages.isEmpty {
                    ContentUnavailableView("Start chatting", systemImage: "bubble.left",
                                           description: Text(store.isConfigured
                                                             ? "Type a message below."
                                                             : "Add a server in Settings first."))
                }
            }
            .onChange(of: live.messages.last?.content) { proxy.scrollTo("bottom") }
            .onChange(of: live.messages.last?.reasoning) { proxy.scrollTo("bottom") }
            .onChange(of: live.messages.count) { proxy.scrollTo("bottom") }
        }
    }

    private func send() {
        store.send(draft)
        draft = ""
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
                    .contextMenu { Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(message.content) } }
            }
        case .assistant:
            HStack {
                AssistantBubble(message: message, isStreaming: isStreaming)
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
    @State private var thinkingOverride: Bool?

    private var thinkingExpanded: Binding<Bool> {
        Binding(
            get: { thinkingOverride ?? (isStreaming && message.content.isEmpty) },
            set: { thinkingOverride = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.reasoning.isEmpty {
                DisclosureGroup("Thinking", isExpanded: thinkingExpanded) {
                    Text(message.reasoning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            if !message.content.isEmpty {
                Text(markdown(message.content)).textSelection(.enabled)
            } else if isStreaming && message.reasoning.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(message.content) }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry).buttonStyle(.bordered)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly).buttonStyle(.plain)
        }
        .padding(10)
        .background(.red.opacity(0.1))
    }
}

private struct Composer: View {
    @Binding var draft: String
    let streaming: Bool
    let canSend: Bool
    let send: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if streaming {
                Button("Stop", systemImage: "stop.circle.fill", action: stop)
                    .labelStyle(.iconOnly).font(.title)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly).font(.title)
                    .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ModelMenu: View {
    let store: ChatStore

    var body: some View {
        Menu {
            Picker("Model", selection: Binding(
                get: { store.model },
                set: { store.updatePreferences(model: $0) }
            )) {
                if !store.availableModels.contains(store.model), !store.model.isEmpty {
                    Text(store.model).tag(store.model)
                }
                ForEach(store.availableModels, id: \.self) { Text($0).tag($0) }
            }
            Divider()
            Button("Refresh Models", systemImage: "arrow.clockwise") { Task { await store.refreshModels() } }
        } label: {
            Label(store.model.isEmpty ? "Model" : store.model, systemImage: "cpu")
        }
    }
}
