import Foundation
import Testing
@testable import ChatCore

struct ImagePlaceholdersTests {
    private let url = URL(string: "http://h/v1/chat/completions")!

    /// A real chat request holding two photos, as the client builds it.
    private func chatExchange(photos: [Data] = [Data(repeating: 7, count: 2000), Data(repeating: 9, count: 400_000)],
                              text: String = "what's in these?") throws -> Exchange {
        let (store, cleanup) = makeImageStore()
        defer { cleanup() }
        let message = ChatMessage(role: .user, content: text, images: try photos.map { try store.save($0) })
        let client = ChatClient(config: try ServerConfig.parse(baseURL: "h:1", apiKey: "k"))
        let request = try client.chatRequest(model: "m", messages: [ChatMessage(role: .system, content: "be brief"), message],
                                             reasoningEffort: .low, images: store)
        return Exchange(capturing: request, purpose: .chat, startedAt: date(0))
    }

    private func sameJSON(_ left: Data, _ right: Data) throws -> Bool {
        let a = try JSONSerialization.jsonObject(with: left), b = try JSONSerialization.jsonObject(with: right)
        return (a as? NSDictionary)?.isEqual(b) == true
    }

    private func imageURLs(_ body: Data) throws -> [String] {
        let json = try #require(jsonObject(body))
        let messages = try #require(json["messages"] as? [[String: Any]])
        return (messages.last?["content"] as? [[String: Any]] ?? []).compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
    }

    @Test func photosBecomeShortTokensInAReadableBody() throws {
        let exchange = try chatExchange()
        let shown = exchange.displayBody
        #expect(shown.contains(#""url": "<image 1: 2 KB>""#))
        #expect(shown.contains(#""url": "<image 2: 391 KB>""#))
        #expect(!shown.contains("base64"))
        #expect(shown.hasPrefix("{\n  \"messages\": [\n    {"), "pretty-printed with keys in order")
        #expect(shown.count < 800, "the photos took up \(exchange.requestBody.count) bytes")
    }

    @Test func puttingTheTokensBackGivesTheSameRequest() throws {
        let exchange = try chatExchange()
        let restored = exchange.placeholders.restore(exchange.displayBody)
        #expect(try sameJSON(restored, exchange.requestBody))
        #expect(try imageURLs(restored) == imageURLs(exchange.requestBody))
    }

    @Test func anEditedBodyKeepsItsEditsAndItsPhotos() throws {
        let exchange = try chatExchange()
        let placeholders = exchange.placeholders
        let edited = placeholders.text
            .replacingOccurrences(of: #""model": "m""#, with: #""model": "other", "max_tokens": 5"#)
            .replacingOccurrences(of: "what's in these?", with: #"what's \"in\" these? 日本語"#)
        let sent = try #require(jsonObject(placeholders.restore(edited)))

        #expect(sent["model"] as? String == "other")
        #expect(sent["max_tokens"] as? Int == 5)
        let original = try imageURLs(exchange.requestBody)
        #expect(try imageURLs(placeholders.restore(edited)) == original)
        let parts = try #require((sent["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        #expect(parts.last?["text"] as? String == #"what's "in" these? 日本語"#)
    }

    @Test func aTokenTheUserDeletesDropsItsPhoto() throws {
        let exchange = try chatExchange()
        let placeholders = exchange.placeholders
        let edited = placeholders.text.replacingOccurrences(of: "<image 2: 391 KB>", with: "removed")
        let urls = try imageURLs(placeholders.restore(edited))
        #expect(urls.count == 2)
        #expect(urls[1] == "removed")
        #expect(urls[0] == (try imageURLs(exchange.requestBody))[0])
    }

    @Test func aBodyWithoutPhotosIsJustPrettyPrinted() throws {
        let exchange = Exchange(purpose: .chat, url: url, requestHeaders: [.init(name: "Content-Type", value: "application/json")],
                                requestBody: bytes(#"{"model":"m","stream":true,"n":1.5,"stop":null,"tags":[],"o":{}}"#))
        let placeholders = exchange.placeholders
        #expect(placeholders.isEmpty)
        #expect(placeholders.text == """
            {
              "model": "m",
              "n": 1.5,
              "o": {},
              "stop": null,
              "stream": true,
              "tags": []
            }
            """)
        #expect(try sameJSON(placeholders.restore(placeholders.text), exchange.requestBody))
    }

    @Test func aBodyThatIsNotJSONIsShownAsItIs() {
        let exchange = Exchange(purpose: .resend, url: url, requestBody: bytes("not json {"))
        #expect(exchange.displayBody == "not json {")
        #expect(exchange.placeholders.restore("not json { edited") == bytes("not json { edited"))
    }

    @Test func aPhotoThatIsNotAnImageDataURLIsLeftAlone() throws {
        let body = bytes(#"{"note":"data:text/plain;base64,aGk=","link":"https://h/x.png"}"#)
        let placeholders = Exchange(purpose: .chat, url: url, requestBody: body).placeholders
        #expect(placeholders.isEmpty)
        #expect(placeholders.text.contains("data:text/plain;base64,aGk="))
    }

    // MARK: multipart

    private func form() -> Exchange {
        // The CRLF inside a file must survive.
        let photos = [Data([0xFF, 0xD8, 13, 10, 0, 1, 2, 255]) + Data(repeating: 5, count: 3000), Data([0xFF, 0xD8, 9])]
        var form = MultipartForm()
        form.field("model", "gpt-image-2")
        form.field("prompt", "a red fox")
        form.field("n", "1")
        for (index, photo) in photos.enumerated() { form.jpeg("image[]", filename: "image\(index + 1).jpg", photo) }
        return Exchange(purpose: .image, url: URL(string: "http://h/v1/images/edits")!,
                        requestHeaders: [.init(name: "Content-Type", value: "multipart/form-data; boundary=\(form.boundary)")],
                        requestBody: form.closed)
    }

    @Test func aFormShowsFieldsAsTextAndFilesAsTokens() {
        let exchange = form()
        let boundary = exchange.requestHeader("Content-Type")?.split(separator: "=").last ?? ""
        #expect(exchange.displayBody == [
            "--\(boundary)", #"Content-Disposition: form-data; name="model""#, "", "gpt-image-2",
            "--\(boundary)", #"Content-Disposition: form-data; name="prompt""#, "", "a red fox",
            "--\(boundary)", #"Content-Disposition: form-data; name="n""#, "", "1",
            "--\(boundary)", #"Content-Disposition: form-data; name="image[]"; filename="image1.jpg""#, "Content-Type: image/jpeg", "",
            "<file image1.jpg: 3 KB>",
            "--\(boundary)", #"Content-Disposition: form-data; name="image[]"; filename="image2.jpg""#, "Content-Type: image/jpeg", "",
            "<file image2.jpg: 1 KB>",
            "--\(boundary)--", "",
        ].joined(separator: "\r\n"))
    }

    @Test func aFormComesBackByteForByte() {
        let exchange = form()
        #expect(exchange.placeholders.restore(exchange.displayBody) == exchange.requestBody)
    }

    @Test func aFormEditedWithLineFeedsOnlyStillComesBackAsAForm() {
        let exchange = form()
        let placeholders = exchange.placeholders
        let edited = placeholders.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "a red fox", with: "a blue fox")
        #expect(placeholders.restore(edited) == exchange.requestBody.replacing(bytes("a red fox"), with: bytes("a blue fox")))
    }

    @Test func aFormWithAnEmptyFieldRoundTrips() {
        var form = MultipartForm()
        form.field("prompt", "")
        form.field("note", "two\nlines")
        let exchange = Exchange(purpose: .image, url: url,
                                requestHeaders: [.init(name: "Content-Type", value: "multipart/form-data; boundary=\(form.boundary)")],
                                requestBody: form.closed)
        #expect(exchange.placeholders.restore(exchange.displayBody) == exchange.requestBody)
    }
}
