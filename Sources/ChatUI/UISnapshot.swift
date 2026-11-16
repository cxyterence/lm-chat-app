#if os(macOS)
import AppKit
import ChatCore
import SwiftUI

public enum UISnapshot {
    private static let chatSize = CGSize(width: 900, height: 640)
    private static let settingsSize = CGSize(width: 480, height: 640)

    @MainActor public static func render(to directory: URL) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("uisnapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try ConversationStore.save([sampleConversation], to: scratch.appendingPathComponent("conversations.json"))

        let only = ProcessInfo.processInfo.environment["UISNAPSHOT_THEMES"].map { Set($0.split(separator: ",").map(String.init)) }
        for theme in Theme.allCases where only?.contains(theme.rawValue) != false {
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
            try await renderDevTools(theme: theme, appearance: appearance, defaults: defaults, scratch: scratch, to: directory)
            let pages: [(String, SettingsPage?)] = [("root", nil)] + SettingsPage.allCases.map { ($0.rawValue, $0) }
            for (name, page) in pages {
                try write(SettingsView(store: store, page: page).theme(theme), size: settingsSize, appearance: appearance,
                          to: directory.appendingPathComponent("\(theme.rawValue)-settings-\(name).png"))
            }
        }
    }

    /// Every developer-tools screen: a reply with notes and a stats line, the inspector, a request and its response,
    /// the resend editor, a failed reply with Inspect, a reply that read a page, and the Check Model pages.
    @MainActor private static func renderDevTools(theme: Theme, appearance: NSAppearance?, defaults: UserDefaults,
                                                  scratch: URL, to directory: URL) async throws {
        func file(_ name: String) -> URL { directory.appendingPathComponent("\(theme.rawValue)-devtools-\(name).png") }
        let sample = try DevToolsSnapshot.makeSample(defaults: defaults, directory: scratch)
        let store = sample.store
        let phone = DevToolsSnapshot.phone

        try write(RootView(store: store), size: chatSize, appearance: appearance, to: file("reply"))
        try write(InspectorSheet(store: store, messageID: sample.reply).theme(theme), size: phone, appearance: appearance, to: file("inspector"))
        func detail(_ exchange: Exchange, part: ExchangeDetail.Part = .request) -> some View {
            NavigationStack {
                ExchangeDetail(store: store, exchange: exchange, messageID: sample.reply, part: part, request: exchange.placeholders) { _ in }
                    .background(theme.palette.groupedBackground)
            }
            .theme(theme)
        }
        try write(detail(sample.worked), size: phone, appearance: appearance, to: file("request"))
        try write(detail(sample.worked, part: .response), size: phone, appearance: appearance, to: file("response"))
        try write(detail(sample.refused), size: phone, appearance: appearance, to: file("request-failed"))
        let longText = (1...60).map { #"data: {"choices":[{"delta":{"content":"word \#($0) "}}]}"# }.joined(separator: "\n")
        try write(BodyText(text: longText, empty: "", limit: 1_200).padding().frame(width: 390, alignment: .topLeading)
                    .background(theme.palette.groupedBackground).theme(theme),
                  size: CGSize(width: 390, height: 460), appearance: appearance, to: file("response-cut"))
        try write(ResendEditor(text: sample.worked.displayBody, cancel: {}, send: { _ in }).theme(theme),
                  size: phone, appearance: appearance, to: file("resend"))

        try renderCheckModel(theme: theme, appearance: appearance, store: store, to: directory)
        try renderCompareTexts(theme: theme, appearance: appearance, to: directory)

        let fetching = try DevToolsSnapshot.makeFetchStore(defaults: defaults, directory: scratch)
        try write(RootView(store: fetching), size: chatSize, appearance: appearance, to: file("fetch"))

        // A reply that can't reach its server leaves a request with no response, and Inspect on the banner.
        let failing = try await DevToolsSnapshot.makeFailingStore(defaults: defaults, directory: scratch)
        try write(RootView(store: failing), size: chatSize, appearance: appearance, to: file("failed"))
        if let id = failing.failedReply {
            try write(InspectorSheet(store: failing, messageID: id).theme(theme), size: phone, appearance: appearance, to: file("inspector-failed"))
        }
    }

    /// A connection's page with its Check Model row, then the report page with results, with details open, running and failed.
    @MainActor private static func renderCheckModel(theme: Theme, appearance: NSAppearance?, store: ChatStore, to directory: URL) throws {
        func file(_ name: String) -> URL { directory.appendingPathComponent("\(theme.rawValue)-devtools-\(name).png") }
        let phone = DevToolsSnapshot.phone
        if let id = store.connections.first?.id {
            try write(NavigationStack { ConnectionEditor(store: store, route: .edit(id)).background(theme.palette.groupedBackground) }.theme(theme),
                      size: phone, appearance: appearance, to: file("connection"))
        }
        let report = DevToolsSnapshot.report
        func page(_ check: ChatStore.CapabilityCheck?, open: Bool = false) -> some View {
            NavigationStack {
                CapabilityReportPage(model: "gpt-6-luna", check: check, isActive: true, detailsOpen: open, run: {})
                    .background(theme.palette.groupedBackground)
            }
            .theme(theme)
        }
        try write(page(.done(report)), size: phone, appearance: appearance, to: file("check"))
        try write(page(.done(report), open: true), size: phone, appearance: appearance, to: file("check-details"))
        try write(page(DevToolsSnapshot.failedCheck), size: phone, appearance: appearance, to: file("check-failed"))
        try write(page(.running), size: phone, appearance: appearance, to: file("check-running"))
    }

    /// The Compare Texts page before a run, with embeddings results, with rerank results, running, and after a 404.
    @MainActor private static func renderCompareTexts(theme: Theme, appearance: NSAppearance?, to directory: URL) throws {
        func page(_ state: ChatStore.Comparison, mode: TextComparison.Mode = .embeddings) -> some View {
            NavigationStack {
                TextComparisonPage(models: ["bge-small-en-v1.5", "jina-reranker-v1-tiny-en"], model: "bge-small-en-v1.5", mode: mode,
                                   state: state, canInspect: true, run: { _, _, _, _ in }, inspect: {})
                    .background(theme.palette.groupedBackground)
            }
            .theme(theme)
        }
        let cases: [(String, ChatStore.Comparison, TextComparison.Mode)] = [
            ("compare", .idle, .embeddings), ("compare-embeddings", DevToolsSnapshot.embeddingsResult, .embeddings),
            ("compare-rerank", DevToolsSnapshot.rerankResult, .rerank), ("compare-running", .running, .embeddings),
            ("compare-failed", DevToolsSnapshot.notFound, .embeddings),
        ]
        for (name, state, mode) in cases {
            try write(page(state, mode: mode), size: CGSize(width: 390, height: 900), appearance: appearance,
                      to: directory.appendingPathComponent("\(theme.rawValue)-devtools-\(name).png"))
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

    @MainActor static func write(_ view: some View, size: CGSize, appearance: NSAppearance?, to url: URL) throws {
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
