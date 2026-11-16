import Foundation

/// The image model chat models draw with through `generate_image`: one model on one saved connection.
struct ImageTool: Codable, Equatable {
    var connectionID: UUID
    var model: String
}
