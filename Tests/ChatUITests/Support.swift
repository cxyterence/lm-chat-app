import Foundation

// Same split as ChatCoreTests: Foundation-using helpers stay out of the Testing-importing file.
func makeTempFileURL(_ name: String) -> (url: URL, cleanup: @Sendable () -> Void) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (dir.appendingPathComponent(name), { try? FileManager.default.removeItem(at: dir) })
}

func makeDefaults() -> (defaults: UserDefaults, cleanup: @Sendable () -> Void) {
    let suite = "ChatUITests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) })
}
