#if os(macOS)
import AppKit
import ChatCore
import SwiftUI

public enum UISnapshot {
    private static let chatSize = CGSize(width: 900, height: 640)
    private static let settingsSize = CGSize(width: 480, height: 640)

    @MainActor public static func render(to directory: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("uisnapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try ConversationStore.save([sampleConversation], to: scratch.appendingPathComponent("conversations.json"))

        for theme in Theme.allCases {
            let suite = "uisnapshot.\(theme.rawValue)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("http://127.0.0.1:1/v1", forKey: "baseURL")
            defaults.set("sample-model", forKey: "model")

            let store = ChatStore(defaults: defaults,
                                  fileURL: scratch.appendingPathComponent("conversations.json"),
                                  secrets: .memory())
            store.setTheme(theme)
            let appearance = NSAppearance(named: theme.colorScheme == .dark ? .darkAqua : .aqua)

            try write(RootView(store: store), size: chatSize, appearance: appearance,
                      to: directory.appendingPathComponent("\(theme.rawValue)-chat.png"))
            let pages: [(String, SettingsPage?)] = [("root", nil)] + SettingsPage.allCases.map { ($0.rawValue, $0) }
            for (name, page) in pages {
                try write(SettingsView(store: store, page: page).theme(theme), size: settingsSize, appearance: appearance,
                          to: directory.appendingPathComponent("\(theme.rawValue)-settings-\(name).png"))
            }
        }
    }

    private static var sampleConversation: Conversation {
        Conversation(
            title: "Explain tail recursion",
            model: "sample-model",
            messages: [
                ChatMessage(role: .user, content: "Explain tail recursion in one paragraph."),
                ChatMessage(role: .assistant,
                            content: "A call is a **tail call** when it is the last thing a function does, so the compiler can reuse the current stack frame instead of growing the stack.",
                            reasoning: "The user wants a short explanation. Mention stack frames and optimisation."),
            ])
    }

    @MainActor private static func write(_ view: some View, size: CGSize, appearance: NSAppearance?, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        defer { window.close() }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw SnapshotError.render(url.lastPathComponent)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.render(url.lastPathComponent)
        }
        try png.write(to: url)
    }

    private enum SnapshotError: LocalizedError {
        case render(String)
        var errorDescription: String? {
            if case .render(let name) = self { "couldn't render \(name)" } else { nil }
        }
    }
}
#endif
