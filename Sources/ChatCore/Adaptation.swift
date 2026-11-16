/// Something the app changed about a request without being asked, kept on the reply it applies to.
public enum Adaptation: Codable, Equatable, Sendable {
    /// The server refused tools, so the request went out without them.
    case toolsDropped(reason: String)
    /// Tools only work on this model with reasoning off.
    case reasoningOffForTools
    /// The preferred level isn't supported, so `to` was sent, or none when the model takes no level.
    case effortChanged(from: ReasoningEffort, to: ReasoningEffort?)
    /// The size the app chose for `generate_image`, and the picture it followed when it came from one.
    case imageSize(String, fromImage: Int?)
    /// The server refused `stream_options`, so the reply carries no token counts.
    case usageNotRequested

    /// One short line to show under the reply.
    public var note: String {
        switch self {
        case .toolsDropped: "Sent without tools. The server refused them."
        case .reasoningOffForTools: "Reasoning turned off so tools work on this model."
        case .effortChanged(let from, let to):
            "Reasoning effort \(to?.rawValue ?? "left out"). \(from.rawValue) isn't supported."
        case .imageSize(let size, let image): "Size \(size)" + (image.map { ", from image \($0)." } ?? ".")
        case .usageNotRequested: "Sent without token counts. The server refused them."
        }
    }
}
