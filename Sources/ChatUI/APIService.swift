import Foundation

/// Third-party services the app can use with the user's own key. Keys live in `Secrets`, never in defaults.
enum APIService: String, CaseIterable, Identifiable {
    case serper

    var id: Self { self }

    var name: String {
        switch self {
        case .serper: "Serper"
        }
    }

    var purpose: String {
        switch self {
        case .serper: "Google search results for web search and /web-search."
        }
    }

    var signupURL: URL {
        switch self {
        case .serper: URL(string: "https://serper.dev/api-key")!
        }
    }

    var secretAccount: String { "service.\(rawValue)" }
}
