import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Extra time to keep a reply streaming after the app leaves the screen. The app asks iOS for it, tests pass a fake.
struct BackgroundTime {
    /// Starts the grant and returns the call that ends it. `onExpiry` runs if iOS takes the time back first.
    var begin: @MainActor (_ onExpiry: @escaping @MainActor () -> Void) -> () -> Void

    static let none = BackgroundTime { _ in {} }

    #if canImport(UIKit)
    static let system = BackgroundTime { onExpiry in
        final class Holder { var id = UIBackgroundTaskIdentifier.invalid }
        let task = Holder()
        let end = {
            guard task.id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task.id)
            task.id = .invalid
        }
        task.id = UIApplication.shared.beginBackgroundTask(withName: "reply") { onExpiry() }
        return end
    }
    #else
    static let system = none
    #endif
}
