/// Every level vLLM's `reasoning_effort` field names, from least to most thinking. A given model accepts
/// only some of them, so the app asks the server which (see `ChatClient.reasoningEfforts(model:)`).
public enum ReasoningEffort: String, CaseIterable, Codable, Sendable {
    case none, minimal, low, medium, high, xhigh, max

    /// The level to send. A saved choice the model doesn't accept falls back to the middle of its range.
    public static func choice(preferred: ReasoningEffort?, supported: [ReasoningEffort]) -> ReasoningEffort? {
        if let preferred, supported.contains(preferred) { return preferred }
        return supported.isEmpty ? nil : supported[supported.count / 2]
    }
}
