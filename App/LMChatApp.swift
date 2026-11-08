import ChatUI
import SwiftUI

@main
struct LMChatApp: App {
    // Owned here because SwiftUI can rebuild the window's content, and each extra store would load, migrate and
    // sweep the photo folder out from under the live one.
    @State private var store = ChatStore()

    var body: some Scene {
        WindowGroup { RootView(store: store) }
    }
}
