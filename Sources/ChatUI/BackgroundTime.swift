import Foundation
#if canImport(UIKit)
import OSLog
import UIKit
import BackgroundTasks
#endif

/// How a reply keeps going after the app leaves the screen. The app asks iOS, tests pass a fake.
struct BackgroundTime {
    /// Starts about 30 seconds of extra time and returns the call that ends it. `onExpiry` runs if iOS takes the time back first.
    var begin: @MainActor (_ onExpiry: @escaping @MainActor () -> Void) -> () -> Void
    /// Asks iOS 26 and later for a continued processing task that covers one reply for as long as the system allows.
    /// Nil where there is no such task or the system refuses it. `onCancel` runs if the system ends the task, as when
    /// the person cancels it from the system's interface.
    var cover: @MainActor (_ onCancel: @escaping @MainActor () -> Void) -> ReplyCover?

    static let none = BackgroundTime(begin: { _ in {} }, cover: { _ in nil })

    #if canImport(UIKit)
    static let system = BackgroundTime(
        begin: { onExpiry in
            final class Holder { var id = UIBackgroundTaskIdentifier.invalid }
            let task = Holder()
            let end = {
                guard task.id != .invalid else { return }
                UIApplication.shared.endBackgroundTask(task.id)
                task.id = .invalid
            }
            task.id = UIApplication.shared.beginBackgroundTask(withName: "reply") { onExpiry() }
            return end
        },
        cover: { onCancel in
            guard #available(iOS 26.0, *) else { return nil }
            return ContinuedReply.submit(onCancel: onCancel)
        })
    #else
    static let system = none
    #endif
}

/// A continued processing task covering one reply. `update` is told how many characters have arrived and `finish`
/// ends the task, once.
struct ReplyCover {
    var update: @MainActor (_ characters: Int) -> Void
    var finish: @MainActor (_ success: Bool) -> Void

    static let title = "Writing a reply"

    static func subtitle(characters: Int) -> String {
        characters == 0 ? "Waiting for the model" : "\(characters.formatted()) characters"
    }

    /// A reply has no known length, so the total always stays ahead of what has arrived. Progress keeps moving
    /// and only the end of the reply completes it.
    static func progress(characters: Int) -> (completed: Int64, total: Int64) {
        (Int64(characters), Int64(characters) + 2000)
    }
}

#if canImport(UIKit)
@available(iOS 26.0, *)
@MainActor
private final class ContinuedReply {
    private enum State {
        case submitted
        case running(BGContinuedProcessingTask)
        case finished
    }

    private let identifier: String
    private var state = State.submitted
    private var characters = 0
    private let onCancel: @MainActor () -> Void

    private init(identifier: String, onCancel: @escaping @MainActor () -> Void) {
        self.identifier = identifier
        self.onCancel = onCancel
    }

    static func submit(onCancel: @escaping @MainActor () -> Void) -> ReplyCover? {
        let identifier = "\(Bundle.main.bundleIdentifier ?? "com.local.lmchat").reply.\(UUID().uuidString)"
        let reply = ContinuedReply(identifier: identifier, onCancel: onCancel)
        // The handler runs on the main queue, and each identifier is registered once, as the system requires.
        guard BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main, launchHandler: { task in
            MainActor.assumeIsolated { reply.started(task) }
        }) else { return nil }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: ReplyCover.title,
                                                       subtitle: ReplyCover.subtitle(characters: 0))
        do { try BGTaskScheduler.shared.submit(request) } catch {
            // The iOS simulator always lands here, and scripts/background_check.sh reads this line.
            Logger(subsystem: "com.local.lmchat", category: "background")
                .notice("The system refused the continued task: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return ReplyCover(update: { reply.update($0) }, finish: { reply.finish(success: $0) })
    }

    private func started(_ task: BGTask) {
        guard case .submitted = state, let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
        state = .running(task)
        task.expirationHandler = { [self] in MainActor.assumeIsolated { onCancel() } }
        update(characters)
    }

    private func update(_ characters: Int) {
        // A reply that asks for tools starts over in a new message, and progress must not go back.
        self.characters = max(self.characters, characters)
        let characters = self.characters
        guard case .running(let task) = state else { return }
        let (completed, total) = ReplyCover.progress(characters: characters)
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = completed
        task.updateTitle(ReplyCover.title, subtitle: ReplyCover.subtitle(characters: characters))
    }

    private func finish(success: Bool) {
        switch state {
        case .submitted: BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        case .running(let task):
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        case .finished: return
        }
        state = .finished
    }
}
#endif
