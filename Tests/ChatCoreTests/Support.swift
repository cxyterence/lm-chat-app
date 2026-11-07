import Foundation

// Kept separate from the Testing-importing files: the CLT toolchain lacks the
// _Testing_Foundation overlay, which a file importing both would require.
func jsonObject(_ data: Data?) -> [String: Any]? {
    data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

func makeTempFileURL(_ name: String) -> (url: URL, cleanup: @Sendable () -> Void) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (dir.appendingPathComponent(name), { try? FileManager.default.removeItem(at: dir) })
}

func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
