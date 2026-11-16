import ChatCore
import Foundation
import Testing
@testable import ChatUI

@MainActor
struct ImageToolTests {
    private static let listing = #"{"data":[{"id":"img","task_type":"t2i","supported_task_types":["t2i"]},{"id":"qwen"}]}"#

    private func picture(width: Int = 64, height: Int = 48) -> String {
        #"{"data":[{"b64_json":"\#(makePNG(width: width, height: height).base64EncodedString())"}]}"#
    }

    /// A chat model that, asked something containing one of `calls`' keys while offered `generate_image`, calls it
    /// with that key's arguments, and answers a tool result by repeating it.
    private func chatModel(calling calls: [String: String]) -> StubServer {
        StubServer { body in
            if lastRole(body) == "tool" { return (200, sse(["done: ", transcript(body).last?.text ?? ""])) }
            let asked = transcript(body).last { $0.role == "user" }?.text ?? ""
            guard offeredTools(body).contains("generate_image"),
                  let arguments = calls.first(where: { asked.contains($0.key) })?.value
            else { return (200, sse(["no picture"])) }
            return (200, toolCallReply("generate_image", arguments: arguments))
        }
    }

    private func imageServer(_ reply: @escaping @Sendable ([String: Any]) -> StubServer.Reply) -> StubServer {
        let server = StubServer { _ in (404, "") }
        server.models = Self.listing
        server.image = reply
        return server
    }

    private func drawingStore(_ calls: [String: String], image: @escaping @Sendable ([String: Any]) -> StubServer.Reply)
        -> (store: ChatStore, chat: StubServer, images: StubServer, cleanup: @Sendable () -> Void) {
        let chat = chatModel(calling: calls), images = imageServer(image)
        let (store, cleanup) = makeStore(server: chat)
        useImageTool(store, at: images)
        return (store, chat, images, cleanup)
    }

    private func messages(_ store: ChatStore) -> [ChatMessage] { store.selectedConversation?.messages ?? [] }

    private func storedPictures(_ store: ChatStore) -> [ImageID] { messages(store).flatMap(\.images) }

    @Test func aReplyOffersGenerateImageWhenAnImageModelIsSet() async throws {
        let chat = chatModel(calling: [:])
        let (store, cleanup) = makeStore(server: chat)
        defer { cleanup() }
        useImageTool(store, at: imageServer { _ in (404, "") })

        store.send("hi")
        await untilIdle(store)

        let body = try #require(chat.chats.first)
        #expect(offeredTools(body) == ["generate_image"])
        let function = try #require((body["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["required"] as? [String] == ["prompt"])
    }

    @Test func itIsOfferedAlongsideMCPToolsAndNoMCPToolTakesItsName() async throws {
        let mcp = FakeMCP(tools: [.init(name: "get_me", readOnly: true, result: "x"),
                                  .init(name: "generate_image", readOnly: true, result: "impostor")])
        let chat = chatModel(calling: [:])
        chat.mcp = mcp
        let (store, cleanup) = makeStore(server: chat)
        defer { cleanup() }
        addMCP(store, at: chat)
        useImageTool(store, at: imageServer { _ in (404, "") })

        store.send("hi")
        await untilIdle(store)

        let offered = offeredTools(try #require(chat.chats.first))
        #expect(offered.filter { $0 == "generate_image" }.count == 1)
        #expect(offered.contains("get_me") && offered.contains("Fake_generate_image"))
    }

    @Test func withNoImageModelSetNothingIsOfferedAndPhotosGoUnannotated() async throws {
        let chat = chatModel(calling: [:])
        let (store, cleanup) = makeStore(server: chat)
        defer { cleanup() }
        let photo = try store.images.save(makePNG(width: 8, height: 8))

        store.send("look", images: [photo])
        await untilIdle(store)

        let body = try #require(chat.chats.first)
        #expect(body["tools"] == nil)
        #expect(transcript(body).last?.text == "look")
    }

    @Test func aGenerateImageCallDrawsAttachesThePictureAndTheModelAnswers() async throws {
        let reply = picture()
        let (store, chat, images, cleanup) = drawingStore(
            ["fox": #"{"prompt":"A red fox in deep snow, golden light.","aspect_ratio":"16:9","resolution":"1280"}"#],
            image: { _ in (200, reply) })
        defer { cleanup() }

        store.send("draw a fox, widescreen")
        await untilIdle(store)

        #expect(images.drawn.count == 1 && images.edited.isEmpty)
        let sent = try #require(images.drawn.first)
        #expect(sent["prompt"] as? String == "A red fox in deep snow, golden light.")
        #expect(sent["model"] as? String == "img")
        #expect(sent["size"] as? String == "1280x720")
        #expect(images.authorizations.contains { $0.path.hasSuffix("images/generations") && $0.authorization == "Bearer image-key" })
        #expect(chat.drawn.isEmpty, "the chat server is never asked for a picture")

        let thread = messages(store)
        #expect(thread.map(\.role) == [.user, .assistant, .assistant])
        #expect(thread[0].content == "draw a fox, widescreen")
        let asking = thread[1]
        let call = try #require(asking.toolCalls.first)
        #expect(call.name == "generate_image" && call.server == "images")
        #expect(call.result?.isError == false && call.result?.text.hasPrefix("Created image 1 (64x48).") == true)
        let saved = try #require(asking.images.first.flatMap { store.images.data(for: $0) }.flatMap(imageInfo))
        #expect(saved.type == "public.jpeg" && saved.width == 64 && saved.height == 48)
        #expect(asking.images.count == 1 && thread[2].images.isEmpty)
        #expect(thread[2].content.hasPrefix("done: Created image 1"))
        #expect(chat.chats.count == 2, "one request for the call, one for the answer")
        #expect(store.failureMessage(for: try #require(store.selection)) == nil)
    }

    @Test func sourceImagesSendTheUsersPhotoAsAnEditAtItsOwnSize() async throws {
        let reply = picture()
        let (store, chat, images, cleanup) = drawingStore(["night": #"{"prompt":"The same scene at night.","source_images":[1]}"#],
                                                          image: { _ in (200, reply) })
        defer { cleanup() }
        let photo = try store.images.save(makePNG(width: 1000, height: 600))

        store.send("make it night", images: [photo])
        await untilIdle(store)

        #expect(images.drawn.isEmpty)
        let form = String(decoding: try #require(images.edited.first), as: UTF8.self)
        #expect(form.contains("The same scene at night."))
        #expect(form.contains(#"name="image"; filename="image1.jpg""#))
        #expect(form.contains("name=\"size\"\r\n\r\n1008x608"))
        #expect(messages(store)[1].toolCalls.first?.result?.text.hasPrefix("Created image 2") == true)

        let firstRequest = try #require(chat.chats.first)
        let asked = try #require(transcript(firstRequest).last)
        #expect(asked.text == "make it night\n\n(Attached: image 1)", "the model is told which picture is which")
        #expect(messages(store)[0].content == "make it night", "the stored message stays as typed")
    }

    @Test func aPictureTheToolDrewCanBeEditedByItsLabelInAFollowUp() async throws {
        let reply = picture()
        let (store, chat, images, cleanup) = drawingStore([
            "fox": #"{"prompt":"A red fox in snow.","aspect_ratio":"16:9"}"#,
            "night time": #"{"prompt":"A red fox in snow at night.","source_images":[1]}"#,
        ], image: { _ in (200, reply) })
        defer { cleanup() }

        store.send("Draw a red fox in snow")
        await untilIdle(store)
        store.send("Now make it night time")
        await untilIdle(store)

        #expect(images.drawn.count == 1 && images.edited.count == 1)
        let drawn = try #require(messages(store)[1].images.first)
        let form = try #require(images.edited.first)
        #expect(form.range(of: try #require(store.images.data(for: drawn))) != nil, "the edit sent the first picture")
        let second = try #require(messages(store).last { !$0.toolCalls.isEmpty })
        #expect(second.toolCalls.first?.result?.text.hasPrefix("Created image 2") == true)
        #expect(storedPictures(store).count == 2)
        let history = transcript(try #require(chat.chats.last))
        #expect(history.contains { $0.role == "tool" && $0.text.hasPrefix("Created image 1") },
                "the model's own earlier results tell it which label is which")
    }

    @Test(arguments: [
        (#"{"prompt":"x","source_images":[2]}"#, "There is no image 2. The chat has image 1."),
        (#"{"prompt":"x","source_images":[0]}"#, "There is no image 0."),
        (#"{"prompt":"x","aspect_ratio":"wide"}"#, "aspect_ratio must look like 16:9"),
        (#"{"source_images":[1]}"#, "prompt is required"),
        ("not json", "JSON object"),
    ])
    func aCallThatCantRunIsAnErrorTheModelReadsAndNoImageIsRequested(arguments: String, said: String) async throws {
        let reply = picture()
        let (store, _, images, cleanup) = drawingStore(["go": arguments], image: { _ in (200, reply) })
        defer { cleanup() }
        let photo = try store.images.save(makePNG(width: 8, height: 8))

        store.send("go", images: [photo])
        await untilIdle(store)

        #expect(images.drawn.isEmpty && images.edited.isEmpty)
        let result = try #require(messages(store)[1].toolCalls.first?.result)
        #expect(result.isError && result.text.contains(said))
        #expect(messages(store).last?.content == "done: " + result.text, "the loop went on to an answer")
        #expect(storedPictures(store) == [photo])
        #expect(store.failureMessage(for: try #require(store.selection)) == nil)
    }

    @Test func sourceImagesInAChatWithNoPicturesIsAnError() async throws {
        let reply = picture()
        let (store, _, images, cleanup) = drawingStore(["go": #"{"prompt":"x","source_images":[1]}"#], image: { _ in (200, reply) })
        defer { cleanup() }

        store.send("go")
        await untilIdle(store)

        #expect(images.drawn.isEmpty && images.edited.isEmpty)
        #expect(messages(store)[1].toolCalls.first?.result?.text.contains("no pictures") == true)
    }

    @Test func anImageServerErrorIsAToolResultNotAFailedReply() async throws {
        let (store, _, _, cleanup) = drawingStore(
            ["fox": #"{"prompt":"A fox."}"#],
            image: { _ in (400, #"{"error":{"message":"Rejected by the safety system."}}"#) })
        defer { cleanup() }

        store.send("draw a fox")
        await untilIdle(store)

        let result = try #require(messages(store)[1].toolCalls.first?.result)
        #expect(result.isError && result.text.contains("Rejected by the safety system."))
        #expect(storedPictures(store).isEmpty)
        #expect(messages(store).last?.content == "done: " + result.text)
        #expect(store.failureMessage(for: try #require(store.selection)) == nil)
    }

    @Test func aReplyThatIsNotAPictureIsAnErrorResult() async throws {
        let (store, _, _, cleanup) = drawingStore(["fox": #"{"prompt":"A fox."}"#],
                                                  image: { _ in (200, #"{"data":[{"b64_json":"bm90IGFuIGltYWdl"}]}"#) })
        defer { cleanup() }

        store.send("draw a fox")
        await untilIdle(store)

        #expect(messages(store)[1].toolCalls.first?.result?.isError == true)
        #expect(storedPictures(store).isEmpty)
    }

    @Test func stoppingWhileThePictureIsBeingMadeLeavesNothingBehind() async throws {
        let reply = picture()
        let (store, _, images, cleanup) = drawingStore(["fox": #"{"prompt":"A fox."}"#], image: { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return (200, reply)
        })
        defer { cleanup() }

        store.send("draw a fox")
        while images.drawn.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        store.stop()
        await untilIdle(store)

        #expect(storedPictures(store).isEmpty)
        #expect(messages(store).map(\.role) == [.user, .assistant])
        #expect(messages(store)[1].toolCalls.first?.result == nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: store.images.directory.path))?.isEmpty != false)
        #expect(store.failureMessage(for: try #require(store.selection)) == nil)
    }

    @Test func retryingDropsThePicturesOfTheRoundsItErases() async throws {
        let reply = picture()
        let images = imageServer { _ in (200, reply) }
        let chat = StubServer { body in
            lastRole(body) == "tool" ? (500, #"{"error":{"message":"overloaded"}}"#)
                : (200, toolCallReply("generate_image", arguments: #"{"prompt":"A fox."}"#))
        }
        let (store, cleanup) = makeStore(server: chat)
        defer { cleanup() }
        useImageTool(store, at: images)

        store.send("draw a fox")
        await untilIdle(store)
        let first = try #require(storedPictures(store).first)
        #expect(store.failureMessage(for: try #require(store.selection)) != nil)

        store.retry()
        await untilIdle(store)

        #expect(store.images.data(for: first) == nil)
        #expect(storedPictures(store).count == 1)
        #expect((try FileManager.default.contentsOfDirectory(atPath: store.images.directory.path)).count == 1)
    }

    @Test func aServerWithoutToolSupportStillAnswersWhenOnlyTheImageToolIsOffered() async throws {
        let chat = StubServer { body in
            offeredTools(body).isEmpty ? (200, sse(["plain answer"])) : (400, #"{"error":{"message":"tools unsupported"}}"#)
        }
        let (store, cleanup) = makeStore(server: chat)
        defer { cleanup() }
        useImageTool(store, at: imageServer { _ in (404, "") })

        store.send("hi")
        await untilIdle(store)
        store.send("again")
        await untilIdle(store)

        #expect(messages(store).last?.content == "plain answer")
        #expect(chat.chats.map { offeredTools($0).isEmpty } == [false, true, true])
    }

    private nonisolated static let reasoningRefusal = #"{"error":{"message":"Function tools with reasoning_effort are not supported for gpt-6-luna in /v1/chat/completions. To use function tools, use /v1/responses or set reasoning_effort to 'none'.","type":"invalid_request_error"}}"#

    /// Like OpenAI's gpt-6-luna: tools are refused unless reasoning is off.
    private func reasoningAverseChat() -> StubServer {
        StubServer { body in
            guard !offeredTools(body).isEmpty else { return (200, sse(["no picture"])) }
            guard body["reasoning_effort"] as? String == "none" else { return (400, Self.reasoningRefusal) }
            if lastRole(body) == "tool" { return (200, sse(["done: ", transcript(body).last?.text ?? ""])) }
            return (200, toolCallReply("generate_image", arguments: #"{"prompt":"A red fox in snow.","aspect_ratio":"16:9"}"#))
        }
    }

    @Test(arguments: [nil, ReasoningEffort.low])
    func aServerThatTakesToolsOnlyWithReasoningOffStillDrawsThePicture(effort: ReasoningEffort?) async throws {
        let reply = picture()
        let chat = reasoningAverseChat(), images = imageServer { _ in (200, reply) }
        let (store, cleanup) = makeStore(server: chat)
        defer { cleanup() }
        useImageTool(store, at: images)
        if let effort { store.setReasoningEffort(effort) }

        store.send("draw a red fox in snow, widescreen")
        await untilIdle(store)

        #expect(images.drawn.count == 1)
        #expect(messages(store).first { !$0.toolCalls.isEmpty }?.images.count == 1)
        #expect(store.failureMessage(for: try #require(store.selection)) == nil)
        let retry = try #require(chat.chats.dropFirst().first)
        #expect(offeredTools(retry) == ["generate_image"] && retry["reasoning_effort"] as? String == "none")
        #expect(chat.chats.dropFirst().allSatisfy { $0["reasoning_effort"] as? String == "none" && !offeredTools($0).isEmpty })
    }

    @Test func onceAModelNeedsReasoningOffLaterRepliesSendItStraightAway() async throws {
        let reply = picture()
        let chat = reasoningAverseChat(), images = imageServer { _ in (200, reply) }
        let (store, cleanup) = makeStore(server: chat)
        defer { cleanup() }
        useImageTool(store, at: images)

        store.send("draw a fox")
        await untilIdle(store)
        let before = chat.chats.count
        store.send("draw another")
        await untilIdle(store)

        #expect(images.drawn.count == 2)
        #expect(chat.chats.dropFirst(before).count == 2)
        #expect(chat.chats.dropFirst(before).allSatisfy { $0["reasoning_effort"] as? String == "none" })
    }

    @Test func aRefusalThatIsNotAboutReasoningStillFallsBackToNoTools() async throws {
        let chat = StubServer { body in
            offeredTools(body).isEmpty ? (200, sse(["plain answer"])) : (400, #"{"error":{"message":"tools unsupported"}}"#)
        }
        let (store, cleanup) = makeStore(server: chat)
        defer { cleanup() }
        useImageTool(store, at: imageServer { _ in (404, "") })
        store.setReasoningEffort(.low)

        store.send("hi")
        await untilIdle(store)

        #expect(messages(store).last?.content == "plain answer")
        #expect(chat.chats.map { offeredTools($0).isEmpty } == [false, true])
        #expect(chat.chats.last?["reasoning_effort"] as? String == "low", "no tools, so the chosen effort stands")
    }

    @Test func imageModelsAreNotOfferedAsChatModelsAndASavedOneFallsBack() async throws {
        let chat = StubServer { _ in (404, "") }
        chat.models = Self.listing
        let (store, cleanup) = makeStore(server: chat)
        defer { cleanup() }
        store.selectModel("img")

        await store.refreshModels()

        #expect(store.availableModels == ["qwen"])
        #expect(store.model == "qwen")
    }

    @Test func aConnectionsImageModelsAreListedWithItsOwnKey() async throws {
        let chat = StubServer { _ in (404, "") }
        let images = imageServer { _ in (404, "") }
        let (store, cleanup) = makeStore(server: chat)
        defer { cleanup() }
        useImageTool(store, at: images, key: "its-own-key")
        let id = try #require(store.imageTool?.connectionID)

        #expect(try await store.imageModels(of: id) == ["img"])
        #expect(images.authorizations.last { $0.path.hasSuffix("/models") }?.authorization == "Bearer its-own-key")
    }

    @Test func theImageToolPersistsAndADeletedConnectionLeavesItUnset() async throws {
        let chat = chatModel(calling: [:])
        let (defaults, cleanDefaults) = makeDefaults()
        let (file, cleanFile) = makeTempFileURL("conversations.json")
        defer { cleanDefaults(); cleanFile() }
        let secrets = Secrets.memory()
        let store = ChatStore(defaults: defaults, fileURL: file, secrets: secrets, session: chat.session)
        store.saveConnection(Connection(name: "chat", baseURL: chat.baseURL, model: "m"), apiKey: "")
        useImageTool(store, at: imageServer { _ in (404, "") })
        let tool = try #require(store.imageTool)

        let reopened = ChatStore(defaults: defaults, fileURL: file, secrets: secrets, session: chat.session)
        #expect(reopened.imageTool == tool)

        reopened.deleteConnection(tool.connectionID)
        #expect(reopened.imageTool == nil)
        reopened.send("hi")
        await untilIdle(reopened)
        #expect(chat.chats.allSatisfy { offeredTools($0).isEmpty })
        #expect(ChatStore(defaults: defaults, fileURL: file, secrets: secrets, session: chat.session).imageTool == nil)
    }

    @Test func connectionsSavedWithOrWithoutTheRetiredImageFlagStillLoad() throws {
        for extra in ["", #","makesImages":true"#] {
            let saved = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"n","baseURL":"http://h/v1","model":"m","systemPrompt":""\#(extra)}"#
            let connection = try JSONDecoder().decode(Connection.self, from: Data(saved.utf8))
            #expect(connection.model == "m" && connection.name == "n")
        }
    }
}
