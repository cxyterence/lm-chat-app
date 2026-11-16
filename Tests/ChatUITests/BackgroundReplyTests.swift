import ChatCore
import Foundation
import Testing
@testable import ChatUI

@MainActor
private final class FakeBackgroundTime {
    private(set) var begun = 0
    private(set) var ended = 0
    private var expire: (@MainActor () -> Void)?

    var time: BackgroundTime {
        BackgroundTime { [self] onExpiry in
            begun += 1
            expire = onExpiry
            return { [self] in ended += 1 }
        }
    }

    var isHeld: Bool { begun > ended }
    func expireNow() { expire?() }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

/// What a held stream's first request is answered with, so a test can change it before a retry.
private final class Script: @unchecked Sendable {
    nonisolated(unsafe) var body: String
    init(_ body: String) { self.body = body }
}

@MainActor
struct BackgroundReplyTests {
    private struct Setup {
        let rig: Rig
        let server: StubServer
        let fake: FakeBackgroundTime
        let clock: Clock
        let script: Script
        var store: ChatStore { rig.store }
    }

    /// A store whose server leaves each reply open after `first`.
    private func setUp(first: String = "Hello ") -> Setup {
        let script = Script(first.isEmpty ? "" : sse([first]).replacingOccurrences(of: "data: [DONE]\n\n", with: ""))
        let server = StubServer { _ in (200, script.body) }
        server.holdsStreamsOpen = true
        let fake = FakeBackgroundTime(), clock = Clock()
        return Setup(rig: Rig(server: server, background: fake.time, now: { clock.now }), server: server, fake: fake, clock: clock,
                     script: script)
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func streamed(_ store: ChatStore, _ text: String) async {
        await until { store.liveReply?.content == text }
    }

    /// Sends a message and waits until its reply has shown `text` and the generated title has been saved, so no
    /// save from the title lands in the middle of what a test checks.
    private func startReply(_ s: Setup, showing text: String = "Hello ") async {
        s.store.send("hi")
        await streamed(s.store, text)
        await until { s.store.selectedConversation?.title == "Stub Title" }
    }

    private func savedReply(_ s: Setup) throws -> ChatMessage? {
        try s.rig.saved().first?.messages.first { $0.role == .assistant }
    }

    @Test func aReplyIsOnDiskWhileItIsStillStreaming() async throws {
        let s = setUp()
        defer { s.rig.cleanup() }
        await startReply(s)

        #expect(s.store.isBusy)
        let saved = try #require(try savedReply(s))
        #expect(saved.content == "Hello ")
        #expect(saved.interrupted)
    }

    @Test func savesAreThrottledToOneEveryTwoSeconds() async throws {
        let s = setUp()
        defer { s.rig.cleanup() }
        await startReply(s)

        s.clock.advance(1)
        s.server.deliver(["more "])
        await streamed(s.store, "Hello more ")
        #expect(try savedReply(s)?.content == "Hello ", "one second on is too soon")

        s.clock.advance(1.5)
        s.server.deliver(["again"])
        await streamed(s.store, "Hello more again")
        #expect(try savedReply(s)?.content == "Hello more again")
    }

    @Test func leavingTheAppSavesAtOnceAndBeginsOneGrant() async throws {
        let s = setUp()
        defer { s.rig.cleanup() }
        await startReply(s)
        s.server.deliver(["quietly "])
        await streamed(s.store, "Hello quietly ")
        #expect(try savedReply(s)?.content == "Hello ", "the throttle holds it back")

        s.store.appMovedToBackground()

        #expect(try savedReply(s)?.content == "Hello quietly ")
        #expect(s.fake.begun == 1 && s.fake.isHeld)
        s.store.appMovedToBackground()
        #expect(s.fake.begun == 1, "a second move is not a second grant")
    }

    @Test func theGrantEndsWhenTheReplyFinishes() async {
        let s = setUp()
        defer { s.rig.cleanup() }
        await startReply(s)
        s.store.appMovedToBackground()

        s.server.endStreams()
        await untilIdle(s.store)

        #expect(s.fake.begun == 1 && s.fake.ended == 1)
        #expect(s.store.selectedConversation?.messages.last?.content == "Hello ")
    }

    @Test func theGrantEndsWhenTheAppBecomesActive() async {
        let s = setUp()
        defer { s.rig.cleanup() }
        await startReply(s)
        s.store.appMovedToBackground()

        s.store.appBecameActive()

        #expect(s.fake.begun == 1 && s.fake.ended == 1)
        #expect(s.store.isBusy, "the reply carries on")
        s.server.endStreams()
        await untilIdle(s.store)
        #expect(s.fake.ended == 1, "finishing does not end it twice")
    }

    @Test func whenTimeRunsOutTheReplySoFarIsSavedTheGrantEndsAndTheStreamIsNotCancelled() async throws {
        let s = setUp()
        defer { s.rig.cleanup() }
        await startReply(s)
        s.store.appMovedToBackground()
        s.server.deliver(["late "])
        await streamed(s.store, "Hello late ")

        s.fake.expireNow()

        #expect(try savedReply(s)?.content == "Hello late ")
        #expect(s.fake.ended == 1 && !s.fake.isHeld)
        #expect(s.store.isBusy)
        s.server.deliver(["end"])
        s.server.endStreams()
        await untilIdle(s.store)
        let message = try #require(s.store.selectedConversation?.messages.last)
        #expect(message.content == "Hello late end", "the stream went on after the grant ended")
        #expect(s.store.failureMessage(for: s.store.selectedConversation!.id) == nil)
    }

    @Test func nothingStreamingMeansNoGrant() {
        let s = setUp()
        defer { s.rig.cleanup() }

        s.store.appMovedToBackground()
        s.store.appBecameActive()

        #expect(s.fake.begun == 0)
    }

    @Test func aReplyThatHasShownNothingYetIsNotSavedAsAnEmptyMessage() async throws {
        let s = setUp(first: "")
        defer { s.rig.cleanup() }
        s.store.send("hi")
        await until { s.store.isBusy && s.store.selectedConversation?.title == "Stub Title" }

        s.store.appMovedToBackground()

        #expect(try s.rig.saved().first?.messages.map(\.role) == [.user])
    }

    @Test func aChatFoundMidStreamAtLaunchShowsWhatArrivedAsInterruptedAndFinishingClearsTheMark() async throws {
        let s = setUp()
        defer { s.rig.cleanup() }
        await startReply(s)

        let launched = s.rig.reopened()
        let found = try #require(launched.selectedConversation?.messages.last)
        #expect(found.role == .assistant && found.content == "Hello " && found.interrupted)
        #expect(!launched.isBusy)

        s.server.endStreams()
        await untilIdle(s.store)
        let finished = try #require(s.rig.reopened().selectedConversation?.messages.last)
        #expect(finished.content == "Hello " && !finished.interrupted)
    }

    @Test func aReplyStoppedByTheUserIsNotLeftMarkedInterrupted() async throws {
        let s = setUp()
        defer { s.rig.cleanup() }
        await startReply(s)

        s.store.stop()
        await untilIdle(s.store)

        let saved = try #require(try savedReply(s))
        #expect(saved.content == "Hello " && !saved.interrupted)
    }

    @Test func oldSavesWithoutTheMarkStillLoad() throws {
        let (file, cleanup) = makeTempFileURL("conversations.json")
        defer { cleanup() }
        let old = """
            [{"id":"\(UUID())","title":"Old","updatedAt":"2024-01-01T00:00:00Z","messages":[
              {"id":"\(UUID())","role":"user","content":"hi","reasoning":"","createdAt":"2024-01-01T00:00:00Z"},
              {"id":"\(UUID())","role":"assistant","content":"hello","reasoning":"","createdAt":"2024-01-01T00:00:01Z"}]}]
            """
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(old.utf8).write(to: file)
        let (defaults, cleanDefaults) = makeDefaults()
        defer { cleanDefaults() }

        let store = ChatStore(defaults: defaults, fileURL: file, secrets: .memory())

        #expect(store.persistenceError == nil)
        #expect(store.conversations.first?.messages.map(\.content) == ["hi", "hello"])
        #expect(store.conversations.first?.messages.allSatisfy { !$0.interrupted } == true)
    }

    @Test func aStreamThatDiesInTheBackgroundSaysSoPlainlyKeepsTheTextAndCanBeRetried() async throws {
        let s = setUp()
        defer { s.rig.cleanup() }
        await startReply(s)
        s.store.appMovedToBackground()
        s.store.appBecameActive()

        s.server.dropStreams()
        await untilIdle(s.store)

        let id = try #require(s.store.selectedConversation?.id)
        #expect(s.store.failureMessage(for: id) == ChatStore.backgroundFailure)
        #expect(s.store.selectedConversation?.messages.last?.content == "Hello ")
        #expect(try savedReply(s)?.interrupted == false)

        s.script.body = sse(["Second try"])
        s.server.holdsStreamsOpen = false
        s.store.retry()
        await untilIdle(s.store)

        #expect(s.store.failureMessage(for: id) == nil)
        #expect(s.store.selectedConversation?.messages.map(\.content).suffix(2) == ["hi", "Second try"])
    }

    @Test func aStreamThatDiesWhileTheAppIsInFrontKeepsTheNetworkError() async throws {
        let s = setUp()
        defer { s.rig.cleanup() }
        await startReply(s)

        s.server.dropStreams()
        await untilIdle(s.store)

        let id = try #require(s.store.selectedConversation?.id)
        let message = try #require(s.store.failureMessage(for: id))
        #expect(message != ChatStore.backgroundFailure)
    }
}
