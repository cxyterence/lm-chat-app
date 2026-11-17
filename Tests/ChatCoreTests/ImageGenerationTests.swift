import Testing
@testable import ChatCore

struct ImageGenerationTests {
    /// The shape SGLang's diffusion server documents for /v1/models.
    @Test func aModelWhoseServerSaysItDoesTextToImageMakesImages() async throws {
        let server = StubServer { _ in
            (200, #"""
                {"object":"list","data":[
                  {"id":"flux","task_type":"t2i","supported_task_types":["t2i","ti2i"],"pipeline_name":"flux"},
                  {"id":"wan","task_type":"t2v","supported_task_types":["t2v"]},
                  {"id":"qwen"}]}
                """#)
        }
        #expect(try await server.client.models() == [
            ServedModel(id: "flux", makesImages: true), ServedModel(id: "qwen"), ServedModel(id: "wan"),
        ])
    }

    @Test func sendsThePromptAndDecodesAnInlineImage() async throws {
        let server = StubServer { _ in (200, #"{"created":1,"data":[{"b64_json":"aGVsbG8="}]}"#) }
        #expect(try await server.client.image(model: "flux", prompt: "a red fox") == bytes("hello"))
        let body = try #require(server.bodies.first)
        #expect(body["model"] as? String == "flux")
        #expect(body["prompt"] as? String == "a red fox")
        #expect(body["response_format"] == nil, "gpt-image models reject it")
        let request = try #require(server.requests.first)
        #expect(request.path.hasSuffix("images/generations"))
        #expect(request.contentType == "application/json")
    }

    @Test func upperCaseTaskTypesAreRecognised() async throws {
        let server = StubServer { _ in
            (200, #"{"data":[{"id":"minimax","task_type":"T2I","supported_task_types":["T2I","I2I"]},{"id":"qwen"}]}"#)
        }
        #expect(try await server.client.models() == [ServedModel(id: "minimax", makesImages: true), ServedModel(id: "qwen")])
    }

    @Test func aFastAPIDetailIsTheErrorMessage() async throws {
        let server = StubServer { _ in (400, #"{"detail":"target.width must be an integer"}"#) }
        await #expect(throws: ChatClientError.http(status: 400, message: "target.width must be an integer")) {
            try await server.client.image(model: "m", prompt: "p", sources: [bytes("jpeg")])
        }
    }

    @Test func sizeIsSentWhenGivenAndOtherwiseLeftOut() async throws {
        let server = StubServer { _ in (200, #"{"data":[{"b64_json":"aGVsbG8="}]}"#) }
        _ = try await server.client.image(model: "m", prompt: "p", size: "1280x720")
        _ = try await server.client.image(model: "m", prompt: "p")
        #expect(server.bodies.map { $0["size"] as? String } == ["1280x720", nil])

        _ = try await server.client.image(model: "m", prompt: "p", sources: [bytes("jpeg")], size: "1024x576")
        _ = try await server.client.image(model: "m", prompt: "p", sources: [bytes("jpeg")])
        let forms = server.requests.suffix(2).map { String(decoding: $0.body, as: UTF8.self) }
        #expect(forms[0].contains(#"name="size"\#r\#n\#r\#n1024x576"#))
        #expect(!forms[1].contains(#"name="size""#))
    }

    @Test(arguments: [
        ("https://api.openai.com/v1", nil as ImageRequest.Aspect?, nil as Int?, nil as String?),
        ("https://api.openai.com/v1", ImageRequest.Aspect(16, 9), 1024, "1024x576"),
        ("https://sglang.test/v1", nil, nil, "1280x720"),
    ])
    func openAIOnlyGetsASizeWhenAskedFor(base: String, aspect: ImageRequest.Aspect?, longEdge: Int?, size: String?) throws {
        let client = ChatClient(config: try ServerConfig.parse(baseURL: base, apiKey: "k"))
        let source = makePNG(width: 1280, height: 720)
        let request = ImageRequest(prompt: "a fox", aspect: aspect, longEdge: longEdge)
        #expect(client.imageSize(for: request, source: source) == size)
    }

    @Test(arguments: [1, 2]) func photosMakeItAMultipartEdit(count: Int) async throws {
        let server = StubServer { _ in (200, #"{"data":[{"b64_json":"aGVsbG8="}]}"#) }
        let sources = (1...count).map { bytes("jpeg-\($0)") }
        #expect(try await server.client.image(model: "gpt-image-2", prompt: "make it red", sources: sources) == bytes("hello"))

        let request = try #require(server.requests.first)
        #expect(request.path.hasSuffix("images/edits"))
        let type = try #require(request.contentType)
        #expect(type.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(body.contains(#"name="model"\#r\#n\#r\#ngpt-image-2"#))
        #expect(body.contains(#"name="prompt"\#r\#n\#r\#nmake it red"#))
        #expect(!body.contains("response_format"), "gpt-image models reject it")
        let field = count == 1 ? "image" : "image[]"
        for (index, source) in sources.enumerated() {
            #expect(body.contains(#"name="\#(field)"; filename="image\#(index + 1).jpg"\#r\#nContent-Type: image/jpeg\#r\#n\#r\#n\#(String(decoding: source, as: UTF8.self))"#))
        }
    }

    @Test func fetchesAnImageTheServerOnlyLinksTo() async throws {
        let server = StubServer { body in
            body["prompt"] == nil ? (200, "picture") : (200, #"{"data":[{"url":"/v1/images/abc/content"}]}"#)
        }
        #expect(try await server.client.image(model: "flux", prompt: "a red fox") == bytes("picture"))
        #expect(server.bodies.count == 2)
    }

    @Test func aRefusalSurfacesTheServersMessage() async {
        let server = StubServer { _ in (400, #"{"error":{"message":"Your request was rejected."}}"#) }
        await #expect(throws: ChatClientError.http(status: 400, message: "Your request was rejected.")) {
            try await server.client.image(model: "gpt-image-2", prompt: "x")
        }
    }

    @Test func aReplyWithNoImageIsInvalid() async {
        let server = StubServer { _ in (200, #"{"data":[]}"#) }
        await #expect(throws: ChatClientError.invalidResponse) {
            try await server.client.image(model: "flux", prompt: "x")
        }
    }

    @Test func picturesAModelDrewAreNotSentBack() throws {
        let (store, cleanup) = makeImageStore()
        defer { cleanup() }
        let picture = try store.save(bytes("jpeg"))
        let request = try StubServer { _ in (200, "") }.client.chatRequest(model: "m", messages: [
            ChatMessage(role: .user, content: "draw a fox"),
            ChatMessage(role: .assistant, content: "", images: [picture]),
            ChatMessage(role: .user, content: "what was that?"),
        ], images: store)
        let messages = try #require(jsonObject(request.httpBody)?["messages"] as? [[String: Any]])
        #expect(messages.map { $0["content"] as? String } == ["draw a fox", "", "what was that?"])
    }
}
