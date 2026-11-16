import ChatCore
import Foundation
import Testing
@testable import ChatUI

/// Drives the real store against real servers. Skipped unless LIVE_CHAT_BASE, LIVE_CHAT_KEY, LIVE_CHAT_MODEL,
/// LIVE_IMAGE_BASE, LIVE_IMAGE_KEY and LIVE_IMAGE_MODEL are all set. Run with scripts/live_test.sh.
@MainActor
@Suite(.enabled(if: LiveServers.current != nil, "set the LIVE_CHAT_* and LIVE_IMAGE_* variables to run"))
struct LiveImageToolTests {
    private func untilIdle(_ store: ChatStore, seconds: Int = 600) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while store.isBusy {
            if ContinuousClock.now > deadline {
                Issue.record("still busy after \(seconds) seconds, so it was stopped")
                store.stop()
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func pictures(_ store: ChatStore) -> [ImageID] { store.selectedConversation?.messages.flatMap(\.images) ?? [] }

    @Test func aChatModelDrawsAPictureThenEditsIt() async throws {
        let live = try #require(LiveServers.current)
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }
        let store = try live.makeStore(defaults: defaults, fileURL: file)
        if let directory = live.outDirectory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

        func save(_ id: ImageID, as name: String) throws {
            guard let directory = live.outDirectory, let jpeg = store.images.data(for: id) else { return }
            try jpeg.write(to: directory.appendingPathComponent(name))
        }

        store.send("Draw a red fox in snow, widescreen")
        await untilIdle(store)
        let conversation = try #require(store.selection)
        #expect(store.failureMessage(for: conversation) == nil, "\(store.failureMessage(for: conversation) ?? "")")
        let first = try #require(pictures(store).first, "the model drew nothing")
        #expect(pictures(store).count == 1)
        try save(first, as: "1-draw.jpg")
        let drawn = try #require(store.images.data(for: first).flatMap(imageInfo))
        #expect(drawn.width > drawn.height, "asked for widescreen and got \(drawn.width)x\(drawn.height)")

        store.send("Now make it night time")
        await untilIdle(store)
        #expect(store.failureMessage(for: conversation) == nil, "\(store.failureMessage(for: conversation) ?? "")")
        let all = pictures(store)
        #expect(all.count == 2, "expected a second picture, found \(all.count) pictures in all")
        if all.count == 2 { try save(all[1], as: "2-night.jpg") }

        let messages = try #require(store.selectedConversation?.messages)
        let followUp = try #require(messages.lastIndex { $0.role == .user })
        let calls = messages[followUp...].flatMap(\.toolCalls).filter { $0.name == ImageRequest.toolName }
        let call = try #require(calls.first, "the model did not call generate_image for the follow-up")
        let request = try ImageRequest.parse(arguments: call.arguments)
        #expect(request.sources.contains(1), "the follow-up should edit image 1: \(call.arguments)")
        print("live: \(drawn.width)x\(drawn.height) first picture, follow-up call \(call.arguments)")
    }
}
