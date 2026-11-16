import SwiftUI

public struct RootView: View {
    let store: ChatStore
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    public init(store: ChatStore) { self.store = store }

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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: store.appMovedToBackground()
            case .active: store.appBecameActive()
            default: break
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store, page: store.isConfigured ? nil : .connections).theme(store.theme)
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
    /// nil while browsing. A set, possibly empty, while picking chats to delete.
    @State private var picking: Set<UUID>?
    @State private var confirmingDelete = false

    private var selection: Binding<Set<UUID>> {
        Binding(
            get: { picking ?? Set([store.selection].compactMap { $0 }) },
            set: { if picking != nil { picking = $0 } else { store.selection = $0.first } }
        )
    }

    var body: some View {
        List(selection: selection) {
            ForEach(store.conversations) { conversation in
                let highlighted = selection.wrappedValue.contains(conversation.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title).lineLimit(1).foregroundStyle(palette.text)
                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(highlighted ? palette.text.opacity(0.75) : palette.secondaryText)
                }
                .tag(conversation.id)
                .listRowBackground(highlighted ? palette.accent.opacity(0.3) : palette.surface)
            }
            .onDelete(perform: picking == nil ? { offsets in
                store.delete(ids: offsets.map { store.conversations[$0].id })
            } : nil)
        }
        .scrollContentBackground(.hidden)
        .background(palette.groupedBackground)
        .overlay {
            if store.conversations.isEmpty {
                ContentUnavailableView("No Chats", systemImage: "text.bubble")
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .navigationTitle(picking.map { $0.isEmpty ? "Select Chats" : "\($0.count) Selected" } ?? "Chats")
        #if os(iOS)
        .environment(\.editMode, .constant(picking == nil ? .inactive : .active))
        #endif
        .toolbar { toolbar }
        .confirmationDialog(deleteLabel, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(deleteLabel, role: .destructive) {
                store.delete(ids: Array(picking ?? []))
                picking = nil
            }
        } message: {
            Text("This can't be undone.")
        }
        .onChange(of: store.conversations.isEmpty) { _, empty in if empty { picking = nil } }
    }

    private var deleteLabel: String {
        let count = picking?.count ?? 0
        return "Delete \(count) Chat\(count == 1 ? "" : "s")"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if picking == nil { browsing } else { pickingToolbar }
    }

    @ToolbarContentBuilder private var browsing: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("New Chat", systemImage: "square.and.pencil") { store.newConversation() }
        }
        ToolbarItem(placement: .automatic) {
            Button("Settings", systemImage: "gearshape") { showSettings = true }
        }
        ToolbarItem(placement: .cancellationAction) {
            Button("Select") { picking = [] }.disabled(store.conversations.isEmpty)
        }
    }

    @ToolbarContentBuilder private var pickingToolbar: some ToolbarContent {
        let all = Set(store.conversations.map(\.id))
        ToolbarItem(placement: .cancellationAction) {
            Button(picking == all ? "Deselect All" : "Select All") { picking = picking == all ? [] : all }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { picking = nil }
        }
        ToolbarItem(placement: deletePlacement) {
            Button(deleteLabel, role: .destructive) { confirmingDelete = true }
                .tint(palette.danger)
                .disabled(picking?.isEmpty ?? true)
        }
    }

    private var deletePlacement: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .automatic
        #endif
    }
}
