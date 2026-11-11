import Testing
@testable import ChatCore

struct OpenAIModelsTests {
    /// The ids OpenAI listed for the user's key on 2026-11-08.
    private static let listed = """
        chat-latest chatgpt-image-latest gpt-4.1 gpt-4.1-2025-04-14 gpt-4.1-mini gpt-4.1-mini-2025-04-14 gpt-4o \
        gpt-4o-2024-08-06 gpt-4o-2024-11-20 gpt-4o-mini gpt-4o-mini-2024-07-18 gpt-4o-mini-transcribe \
        gpt-4o-mini-transcribe-2025-03-20 gpt-4o-mini-transcribe-2025-12-15 gpt-4o-mini-tts gpt-4o-mini-tts-2025-03-20 \
        gpt-4o-mini-tts-2025-12-15 gpt-4o-transcribe gpt-4o-transcribe-diarize gpt-5 gpt-5-2025-08-07 gpt-5-mini \
        gpt-5-mini-2025-08-07 gpt-5-nano gpt-5-nano-2025-08-07 gpt-5-pro gpt-5-pro-2025-10-06 gpt-5-search-api \
        gpt-5-search-api-2025-10-14 gpt-5.1 gpt-5.1-2025-11-13 gpt-5.2 gpt-5.2-2025-12-11 gpt-5.2-pro \
        gpt-5.2-pro-2025-12-11 gpt-5.3-codex gpt-5.4 gpt-5.4-2026-03-05 gpt-5.4-mini gpt-5.4-mini-2026-03-17 gpt-5.4-nano \
        gpt-5.4-nano-2026-03-17 gpt-5.4-pro gpt-5.4-pro-2026-03-05 gpt-5.5 gpt-5.5-2026-04-23 gpt-5.5-pro \
        gpt-5.5-pro-2026-04-23 gpt-5.6-luna gpt-5.6-sol gpt-5.6-terra gpt-6-astra gpt-6-luna gpt-6-sol gpt-6.1-sol \
        gpt-6.1-terra gpt-audio gpt-audio-1.5 gpt-audio-2025-08-28 gpt-audio-mini gpt-audio-mini-2025-12-15 \
        gpt-image-1-mini gpt-image-1.5 gpt-image-2 gpt-image-2-2026-04-21 gpt-image-2.5-flare \
        gpt-image-2.5-flare-2026-09-08 gpt-image-2.5-sunburst gpt-image-2.5-sunburst-2026-09-08 gpt-image-2.6-flare \
        gpt-image-2.6-sunburst gpt-live-1 gpt-live-transcribe gpt-realtime gpt-realtime-1.5 gpt-realtime-2 \
        gpt-realtime-2.1 gpt-realtime-2.1-mini gpt-realtime-2025-08-28 gpt-realtime-mini gpt-realtime-mini-2025-12-15 \
        gpt-realtime-translate gpt-realtime-whisper gpt-transcribe o3 o3-2025-04-16 omni-moderation-2024-09-26 \
        omni-moderation-latest text-embedding-3-large text-embedding-3-small text-embedding-ada-002 tts-1 tts-1-1106 \
        tts-1-hd tts-1-hd-1106 whisper-1
        """.split(separator: " ").map(String.init)

    @Test func offersGPT6AndLaterTextModelsPlusGPT4oMini() {
        #expect(Self.listed.filter { OpenAIModels.isOffered($0) && !OpenAIModels.makesImages($0) }
                == ["gpt-4o-mini", "gpt-6-astra", "gpt-6-luna", "gpt-6-sol", "gpt-6.1-sol", "gpt-6.1-terra"])
    }

    @Test func offersImageModelsWithoutTheirSnapshots() {
        #expect(Self.listed.filter(OpenAIModels.makesImages) == [
            "chatgpt-image-latest", "gpt-image-1-mini", "gpt-image-1.5", "gpt-image-2", "gpt-image-2.5-flare",
            "gpt-image-2.5-sunburst", "gpt-image-2.6-flare", "gpt-image-2.6-sunburst",
        ])
        #expect(Self.listed.filter(OpenAIModels.makesImages).allSatisfy(OpenAIModels.isOffered))
    }

    @Test(arguments: ["gpt-7", "gpt-6.2-mini", "gpt-10-pro", "gpt-6-codex"])
    func laterTextModelsAreOffered(id: String) {
        #expect(OpenAIModels.isOffered(id))
    }

    @Test(arguments: ["gpt-6-tts", "gpt-6-realtime", "gpt-6-luna-2027-01-15", "gpt-image-6-2027-01-15", "gpt-6-audio-mini"])
    func laterNonTextModelsAndSnapshotsAreNot(id: String) {
        #expect(!OpenAIModels.isOffered(id))
    }

    @Test func otherServersKeepTheirWholeList() async throws {
        let server = StubServer { _ in (200, #"{"data":[{"id":"text-embedding-3-small"},{"id":"qwen"}]}"#) }
        #expect(try await server.client.models().map(\.id) == ["qwen", "text-embedding-3-small"])
    }
}
