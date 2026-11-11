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
