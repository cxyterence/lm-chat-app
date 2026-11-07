import SwiftUI

public struct RootView: View {
    @State private var store: ChatStore
    @State private var showSettings = false

    public init() { self.init(store: ChatStore()) }

    init(store: ChatStore) { _store = State(initialValue: store) }

    public var body: some View {
        NavigationSplitView {
            Sidebar(store: store, showSettings: $showSettings)
        } detail: {
            if let conversation = store.selectedConversation {
                ChatView(store: store, conversation: conversation)
                    .id(conversation.id)
            } else {
                NoChatSelected()
            }
        }
        .theme(store.theme)
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store).theme(store.theme)
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

private struct NoChatSelected: View {
    @Environment(\.palette) private var palette

    var body: some View {
        ContentUnavailableView("No Chat Selected", systemImage: "bubble.left.and.bubble.right",
                               description: Text("Start a new chat from the sidebar."))
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background)
            .themedNavigationBar()
    }
}

private struct Sidebar: View {
    @Bindable var store: ChatStore
    @Environment(\.palette) private var palette
    @Binding var showSettings: Bool

    var body: some View {
        List(selection: $store.selection) {
            ForEach(store.conversations) { conversation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title).lineLimit(1).foregroundStyle(palette.text)
                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(store.selection == conversation.id ? palette.text.opacity(0.75) : palette.secondaryText)
                }
                .tag(conversation.id)
                .listRowBackground(store.selection == conversation.id ? palette.accent.opacity(0.3) : palette.surface)
            }
            .onDelete { offsets in
                store.delete(ids: offsets.map { store.conversations[$0].id })
            }
        }
        .scrollContentBackground(.hidden)
        .background(palette.groupedBackground)
        .overlay {
            if store.conversations.isEmpty {
                ContentUnavailableView("No Chats", systemImage: "text.bubble")
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .navigationTitle("Chats")
        .themedNavigationBar()
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
