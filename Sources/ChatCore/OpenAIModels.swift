/// OpenAI lists speech, embedding and dated snapshot models alongside chat models. On an OpenAI
/// connection the app offers only text models from gpt-6 on, gpt-4o-mini, and the image models.
public enum OpenAIModels {
    public static let host = "api.openai.com"

    private static let nonText: Set = [
        "audio", "embedding", "image", "live", "moderation", "realtime", "search", "transcribe", "translate", "tts", "whisper",
    ]

    /// The models behind ChatGPT's image generation, served by the Images API and not by chat completions.
    /// Dated snapshots are left out, as they are for text models.
    public static func makesImages(_ id: String) -> Bool {
        id == "chatgpt-image-latest" || id.wholeMatch(of: /gpt-image-\d+(?:\.\d+)?(?:-[a-z]+)*/) != nil
    }

    public static func isOffered(_ id: String) -> Bool {
        if id == "gpt-4o-mini" || makesImages(id) { return true }
        // Digits after the family (a dated snapshot such as -2026-03-05) fail the match, so snapshots are left out.
        guard let match = id.wholeMatch(of: /gpt-(\d+)(?:\.\d+)?((?:-[a-z]+)*)/),
              let major = Int(match.1), major >= 6
        else { return false }
        return !match.2.split(separator: "-").contains { nonText.contains(String($0)) }
    }
}
