import SwiftUI

public struct RootView: View {
    @State private var store = ChatStore()
    @State private var showSettings = false

    public init() {}

    public var body: some View {
        NavigationSplitView {
            Sidebar(store: store, showSettings: $showSettings)
        } detail: {
            if let conversation = store.selectedConversation {
                ChatView(store: store, conversation: conversation)
                    .id(conversation.id)
            } else {
                ContentUnavailableView("No Chat Selected", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Start a new chat from the sidebar."))
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
        }
        .task {
            if store.isConfigured {
                await store.refreshModels()
            } else {
                showSettings = true
            }
        }
    }
}

private struct Sidebar: View {
    @Bindable var store: ChatStore
    @Binding var showSettings: Bool

    var body: some View {
        List(selection: $store.selection) {
            ForEach(store.conversations) { conversation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title).lineLimit(1)
                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(conversation.id)
            }
            .onDelete { offsets in
                store.delete(ids: offsets.map { store.conversations[$0].id })
            }
        }
        .overlay {
            if store.conversations.isEmpty {
                ContentUnavailableView("No Chats", systemImage: "text.bubble")
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Chat", systemImage: "square.and.pencil") { store.newConversation() }
            }
            ToolbarItem(placement: .automatic) {
                Button("Settings", systemImage: "gearshape") { showSettings = true }
            }
        }
    }
}
