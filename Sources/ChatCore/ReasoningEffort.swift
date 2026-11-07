/// The server's chat template defaults to its highest effort when the field is omitted, so `nil`
/// (omit) is a distinct choice from any case here. The server rejects values outside this set.
public enum ReasoningEffort: String, CaseIterable, Codable, Sendable {
    case medium, low
}
