import ChatCore
import Foundation
import Testing
@testable import ChatUI

/// Drives the real store against a real chat server and checks what the developer tools report. Skipped unless
/// LIVE_CHAT_BASE, LIVE_CHAT_KEY and LIVE_CHAT_MODEL are set. Run with `scripts/live_test.sh LiveDevToolsTests`.
/// With LIVE_OUT_DIR set it writes request.curl.sh and capabilities.txt there.
@MainActor
@Suite(.enabled(if: LiveChatServer.current != nil, "set LIVE_CHAT_BASE, LIVE_CHAT_KEY and LIVE_CHAT_MODEL to run"))
struct LiveDevToolsTests {
    private let prompt = "Reply with one short sentence."
    private let edited = "Reply with exactly the word PINEAPPLE."

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

    /// What a streamed response said, with its pieces joined: a word can arrive split across chunks.
    private func spoken(_ sse: String) -> String {
        sse.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("data:"),
                  let object = jsonObject(Data(line.dropFirst("data:".count).utf8)),
                  let delta = ((object["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])
            else { return nil }
            return delta["content"] as? String
        }.joined()
    }

    private func text(_ report: CapabilityReport, model: String) -> String {
        func describe(_ support: Support) -> String {
            switch support {
            case .yes: "yes"
            case .no(let reason): "no (\(reason))"
            case .unknown(let reason): "unknown (\(reason))"
            }
        }
        let tools = switch report.tools {
        case .yes: "yes"
        case .onlyWithReasoningOff: "only with reasoning off"
        case .no(let reason): "no (\(reason))"
        case .unknown(let reason): "unknown (\(reason))"
        }
        var lines = ["model: \(model)", "tools: \(tools)", "vision: \(describe(report.vision))",
                     "reasoning efforts: \(report.efforts.isEmpty ? "not adjustable" : report.efforts.map(\.rawValue).joined(separator: " "))",
                     "context length: \(report.contextLength.map(String.init) ?? "not reported")",
                     report.server.isEmpty ? "server: nothing reported" : "server:"]
        lines += report.server.map { "  \($0.name): \($0.value)" }
        return lines.joined(separator: "\n") + "\n"
    }

    @Test func aReplyCanBeInspectedCopiedAsCurlEditedAndResentAndTheModelChecked() async throws {
        let live = try #require(LiveChatServer.current)
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }
        let (store, connection) = try live.makeStore(defaults: defaults, fileURL: file)
        if let directory = live.outDirectory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

        store.send(prompt)
        await untilIdle(store)
        let conversation = try #require(store.selection)
        #expect(store.failureMessage(for: conversation) == nil, "\(store.failureMessage(for: conversation) ?? "")")
        let reply = try #require(store.selectedConversation?.messages.last { $0.role == .assistant }, "the model said nothing")
        let chat = try #require(store.exchanges(for: reply.id).first { $0.purpose == .chat }, "no chat request was kept")

        #expect(chat.status == 200 && chat.error == nil)
        #expect((chat.usage?.completionTokens ?? 0) > 0, "the server reported no completion tokens: \(String(describing: chat.usage))")
        let stats = chat.stats
        let first = try #require(stats.timeToFirstToken, "no time to first token")
        let total = try #require(stats.totalTime)
        #expect(first < total, "first token \(first) s, total \(total) s")
        let line = try #require(ExchangeText.statsLine(chat), "no stats line")

        let everything = [chat.url.absoluteString, chat.requestHeaders.map { $0.name + $0.value }.joined(),
                          String(decoding: chat.requestBody, as: UTF8.self), chat.responseHeaders.map { $0.name + $0.value }.joined(),
                          chat.responseBody, chat.error ?? "", chat.curl].joined()
        #expect(!everything.contains(live.key), "the API key is in the stored exchange")
        #expect(chat.requestHeader("Authorization") == "Bearer $API_KEY")
        if let directory = live.outDirectory { try (chat.curl + "\n").write(to: directory.appendingPathComponent("request.curl.sh"), atomically: true, encoding: .utf8) }

        let before = store.selectedConversation
        let display = chat.displayBody
        let changed = display.replacingOccurrences(of: "\"\(prompt)\"", with: "\"\(edited)\"")
        #expect(changed != display, "the prompt wasn't found in the request body")
        let sent = await store.resend(chat, editedText: changed, for: reply.id)
        let resentText = spoken(sent.responseBody)

        #expect(sent.purpose == .resend && sent.status == 200 && sent.error == nil, "\(sent.error ?? "") \(sent.responseBody.prefix(300))")
        #expect(resentText.localizedCaseInsensitiveContains("pineapple"), "the resent request was answered \"\(resentText)\"")
        #expect(!(sent.requestHeaders.map(\.value).joined() + sent.responseBody + sent.curl).contains(live.key))
        #expect(store.exchanges(for: reply.id).last?.id == sent.id, "the new request joins the same reply")
        #expect(store.selectedConversation == before, "resending changed the chat")

        await store.checkCapabilities(of: connection.id)
        guard case .done(let report)? = store.capabilityChecks[.init(connection: connection.id, model: live.model)] else {
            Issue.record("the capability check did not finish: \(String(describing: store.capabilityChecks.first?.value))")
            return
        }
        let capabilities = text(report, model: live.model)
        #expect(!capabilities.contains(live.key))
        if let directory = live.outDirectory { try capabilities.write(to: directory.appendingPathComponent("capabilities.txt"), atomically: true, encoding: .utf8) }
        print("live: \(line); resent answer \"\(resentText)\"\n\(capabilities)")
    }
}
