import Foundation
import Testing
@testable import ChatCore

struct ExchangeCurlTests {
    private func chat(body: String) -> Exchange {
        Exchange(purpose: .chat, url: URL(string: "http://localhost:8099/v1/chat/completions")!, requestHeaders: [
            .init(name: "Accept", value: "text/event-stream"),
            .init(name: "Authorization", value: "Bearer $API_KEY"),
            .init(name: "Content-Type", value: "application/json"),
        ], requestBody: bytes(body))
    }

    @Test func aJSONBodyWithQuotesAndApostrophesIsQuotedForTheShell() {
        let exchange = chat(body: #"{"model":"m","stream":true,"messages":[{"role":"user","content":"it's a \"quote\""}]}"#)
        #expect(exchange.curl == #"""
            curl -N -X POST 'http://localhost:8099/v1/chat/completions' \
              -H 'Accept: text/event-stream' \
              -H "Authorization: Bearer $API_KEY" \
              -H 'Content-Type: application/json' \
              -d '{
              "messages": [
                {
                  "content": "it'\''s a \"quote\"",
                  "role": "user"
                }
              ],
              "model": "m",
              "stream": true
            }'
            """#)
    }

    @Test func theBodyIsTakenFromPlaceholdersAlreadyReadNotReadAgain() {
        let exchange = chat(body: #"{"model":"m"}"#)
        #expect(exchange.curl(using: exchange.placeholders) == exchange.curl)
        let given = ImagePlaceholders(body: bytes(#"{"given":true}"#), contentType: "application/json")
        let command = exchange.curl(using: given)
        #expect(command.contains(#""given": true"#) && !command.contains(#""model""#))
    }

    @Test func aGetHasNoMethodOrBody() {
        let exchange = Exchange(purpose: .models, method: "GET", url: URL(string: "http://localhost:8099/v1/models")!,
                                requestHeaders: [.init(name: "Authorization", value: "Bearer $API_KEY")])
        #expect(exchange.curl == """
            curl 'http://localhost:8099/v1/models' \\
              -H "Authorization: Bearer $API_KEY"
            """)
    }

    @Test func aRequestWithPhotosSaysTheyWereLeftOut() {
        let exchange = chat(body: #"{"messages":[{"content":[{"image_url":{"url":"data:image/jpeg;base64,/9j/4AAQ"},"type":"image_url"}]}]}"#)
        let lines = exchange.curl.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "# Photos were left out. Replace each <image> placeholder with a data:image URL of your own.")
        #expect(exchange.curl.contains(#""url": "<image 1: 1 KB>""#))
        #expect(!exchange.curl.contains("/9j/"))
        #expect(exchange.curl.filter { $0 == "#" }.count == 1, "one comment line")
    }

    @Test func aFormBecomesFlagsWithPhotosAsFilesToSupply() {
        var form = MultipartForm()
        form.field("model", "m")
        form.field("prompt", "it's a fox")
        form.field("n", "1")
        form.jpeg("image[]", filename: "image1.jpg", Data([1, 2, 3]))
        form.jpeg("image[]", filename: "image2.jpg", Data([4]))
        let exchange = Exchange(purpose: .image, url: URL(string: "http://localhost:8099/v1/images/edits")!, requestHeaders: [
            .init(name: "Authorization", value: "Bearer $API_KEY"),
            .init(name: "Content-Type", value: "multipart/form-data; boundary=\(form.boundary)"),
        ], requestBody: form.closed)
        #expect(exchange.curl == #"""
            # Photos were left out. Point each @file at a photo of your own.
            curl -X POST 'http://localhost:8099/v1/images/edits' \
              -H "Authorization: Bearer $API_KEY" \
              --form-string 'model=m' \
              --form-string 'prompt=it'\''s a fox' \
              --form-string 'n=1' \
              -F 'image[]=@image1.jpg;type=image/jpeg' \
              -F 'image[]=@image2.jpg;type=image/jpeg'
            """#)
    }

    #if os(macOS)
    /// Runs the command in a shell with `curl` replaced by a function that lists its arguments, which shows
    /// what curl would be given.
    private func argumentsCurlWouldGet(_ command: String, key: String) throws -> [String] {
        let script = "curl() { for a in \"$@\"; do printf '%s\\0' \"$a\"; done; }; API_KEY=\(key); \(command)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    @Test func theShellHandsCurlTheBodyAndTheKeyIntact() throws {
        let exchange = chat(body: #"{"model":"m","messages":[{"role":"user","content":"it's \"quoted\" $HOME `date` \\ done"}]}"#)
        let arguments = try argumentsCurlWouldGet(exchange.curl, key: "sk-real")
        #expect(arguments.dropLast() == ["-N", "-X", "POST", "http://localhost:8099/v1/chat/completions",
                                         "-H", "Accept: text/event-stream", "-H", "Authorization: Bearer sk-real",
                                         "-H", "Content-Type: application/json", "-d"])
        #expect(arguments.last == exchange.displayBody)
    }
    #endif
}
