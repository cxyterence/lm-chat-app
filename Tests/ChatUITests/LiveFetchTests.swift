import ChatCore
import Foundation
import Testing
@testable import ChatUI

/// Drives the real store against a real chat server, with the Fetch web pages setting on, and has the model read
/// https://example.com on the real internet. Skipped unless LIVE_CHAT_BASE, LIVE_CHAT_KEY and LIVE_CHAT_MODEL are set.
/// Runs once on Chat Completions and once on Responses. Run with `scripts/live_test.sh LiveFetchTests`.
@MainActor
@Suite(.enabled(if: LiveChatServer.current != nil, "set LIVE_CHAT_BASE, LIVE_CHAT_KEY and LIVE_CHAT_MODEL to run"))
struct LiveFetchTests {
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

    @Test(arguments: [WireAPI.chatCompletions, .responses])
    func theModelCallsFetchUrlAndAnswersFromThePage(api: WireAPI) async throws {
        let live = try #require(LiveChatServer.current)
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }
        let (store, _) = try live.makeStore(defaults: defaults, fileURL: file, api: api)
        store.setFetchesPages(true)

        store.send("What is the title of the page at https://example.com? Use the fetch tool.")
        await untilIdle(store)

        let conversation = try #require(store.selection)
        #expect(store.failureMessage(for: conversation) == nil, "\(store.failureMessage(for: conversation) ?? "")")
        let messages = try #require(store.selectedConversation?.messages)
        let calls = messages.flatMap(\.toolCalls).filter { $0.name == "fetch_url" }
        let call = try #require(calls.first, "the model never called fetch_url")
        let result = try #require(call.result, "the call has no result")
        #expect(!result.isError, "\(result.text)")
        #expect(result.text.contains("Example Domain"), "\(result.text.prefix(300))")
        #expect(call.server == "example.com")

        let reply = try #require(messages.last { $0.role == .assistant })
        #expect(reply.toolCalls.isEmpty && reply.content.contains("Example Domain"), "the final reply was \"\(reply.content)\"")

        let asking = try #require(messages.first { $0.toolCalls.contains { $0.name == "fetch_url" } })
        let fetch = try #require(store.exchanges(for: asking.id).first { $0.purpose == .fetch }, "no page request in the inspector")
        #expect(fetch.status == 200 && fetch.error == nil && fetch.url.host() == "example.com")
        #expect(fetch.requestHeader("User-Agent") == "LMChat/1.0" && fetch.requestHeader("Authorization") == nil)

        let everything = messages.map(\.content).joined() + messages.flatMap(\.toolCalls).map { $0.arguments + ($0.result?.text ?? "") }.joined()
            + fetch.requestHeaders.map(\.value).joined() + fetch.responseBody
        #expect(!everything.contains(live.key))
        let requests = messages.flatMap { store.exchanges(for: $0.id) }.filter { $0.purpose == .chat }
        print("live \(api.rawValue): \(calls.count) fetch_url call, result \(result.text.count) characters, fetch status \(fetch.status ?? 0), \(requests.count) chat requests to \(requests.first?.url.path ?? "?"), reply \"\(reply.content.prefix(120))\"")
    }
}
