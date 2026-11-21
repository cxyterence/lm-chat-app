#if DEBUG
import ChatCore
import Foundation

public extension ChatStore {
    /// Lets scripts/background_check.sh drive the app with no taps. `--debug-server URL` makes that server the only
    /// connection, and `--debug-send TEXT` sends a message once. Without them it does nothing.
    func applyDebugLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let address = value(after: "--debug-server"),
              let server = try? ServerConfig.parse(baseURL: address, apiKey: "") else { return }
        let id = UUID(uuidString: "DEB06000-0000-4000-8000-000000000001")!
        saveConnection(Connection(id: id, name: "Debug server", baseURL: server.baseURL, model: "mock-chat"), apiKey: "")
        if let text = value(after: "--debug-send") { send(text) }
    }
}
#endif
