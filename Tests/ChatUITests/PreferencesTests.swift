import ChatCore
import Testing
@testable import ChatUI

@MainActor
struct PreferencesTests {
    @Test func themeAndEffortPersistAcrossStores() {
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }

        let first = ChatStore(defaults: defaults, fileURL: file, secrets: .memory())
        first.setTheme(.dracula)
        first.setReasoningEffort(.low)

        let second = ChatStore(defaults: defaults, fileURL: file, secrets: .memory())
        #expect(second.theme == .dracula)
        #expect(second.reasoningEffort == .low)
    }

    @Test func missingOrUnknownThemeLoadsSystem() {
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }

        #expect(ChatStore(defaults: defaults, fileURL: file, secrets: .memory()).theme == .system)
        defaults.set("solarized", forKey: "theme")
        #expect(ChatStore(defaults: defaults, fileURL: file, secrets: .memory()).theme == .system)
    }
}
