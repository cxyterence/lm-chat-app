import Testing
@testable import ChatCore

struct ImageRequestTests {
    private func problem(_ arguments: String) -> String? {
        do {
            _ = try ImageRequest.parse(arguments: arguments)
            return nil
        } catch let error as ImageRequest.Invalid {
            return error.message
        } catch {
            return "unexpected \(error)"
        }
    }

    @Test func readsEveryField() throws {
        let request = try ImageRequest.parse(
            arguments: #"{"prompt":"a red fox in snow","source_images":[1,3],"aspect_ratio":"16:9","resolution":"2k"}"#)
        #expect(request == ImageRequest(prompt: "a red fox in snow", aspect: .init(16, 9), longEdge: 2048, sources: [1, 3]))
    }

    @Test func aPromptAloneIsEnough() throws {
        #expect(try ImageRequest.parse(arguments: #"{"prompt":"  a red fox\n"}"#) == ImageRequest(prompt: "a red fox"))
    }

    @Test func nullsStandForLeftOutFields() throws {
        let request = try ImageRequest.parse(
            arguments: #"{"prompt":"x","source_images":null,"aspect_ratio":null,"resolution":null}"#)
        #expect(request == ImageRequest(prompt: "x"))
    }

    @Test(arguments: [("1k", 1024), ("2K", 2048), ("4k", 4096), ("256", 256), ("1536", 1536), ("4096", 4096)])
    func resolutionTakesNamedSizesAndPixelCounts(text: String, longEdge: Int) throws {
        #expect(try ImageRequest.parse(arguments: #"{"prompt":"x","resolution":"\#(text)"}"#).longEdge == longEdge)
    }

    @Test func resolutionMayBeANumberToo() throws {
        #expect(try ImageRequest.parse(arguments: #"{"prompt":"x","resolution":1536}"#).longEdge == 1536)
    }

    @Test(arguments: [
        "{}", #"{"prompt":""}"#, #"{"prompt":"  \n"}"#, #"{"prompt":7}"#, #"{"aspect_ratio":"16:9"}"#, "not json", "[]", "",
    ])
    func aMissingPromptSaysSo(arguments: String) {
        #expect(problem(arguments)?.contains("prompt") == true)
    }

    @Test(arguments: [#""16-9""#, #""0:9""#, #""16:""#, #""wide""#, #""""#, #"" 16:9""#, #""16:9:1""#, "1.5", "[16, 9]"])
    func aBadAspectRatioNamesTheFieldAndTheForm(value: String) {
        let message = problem(#"{"prompt":"x","aspect_ratio":\#(value)}"#)
        #expect(message?.contains("aspect_ratio") == true && message?.contains("16:9") == true)
    }

    @Test(arguments: [#""255""#, #""4097""#, #""3k""#, #""big""#, #""""#, #""2k,""#, "255", "4097", "1024.5", "true"])
    func aBadResolutionNamesTheFieldAndTheRange(value: String) {
        let message = problem(#"{"prompt":"x","resolution":\#(value)}"#)
        #expect(message?.contains("resolution") == true && message?.contains("4096") == true)
    }

    @Test(arguments: [#"["a"]"#, "[1.5]", #""1""#, "1", "[null]", "[true]", #"["1"]"#])
    func sourceImagesMustBeWholeNumbers(value: String) {
        #expect(problem(#"{"prompt":"x","source_images":\#(value)}"#)?.contains("source_images") == true)
    }

    @Test func theParsersFollowTheRulesTheFieldsDo() {
        #expect(ImageRequest.parseAspect("16:9") == .init(16, 9))
        #expect(ImageRequest.parseAspect("0:9") == nil)
        #expect(ImageRequest.parseLongEdge("2K") == 2048)
        #expect(ImageRequest.parseLongEdge("1500") == 1500)
        #expect(ImageRequest.parseLongEdge("99") == nil)
    }

    @Test(arguments: [
        (nil as (Int, Int)?, nil as Int?, nil as (Int, Int)?, nil as String?),
        (nil, nil, (1000, 600), "1008x608"),
        (nil, nil, (1280, 720), "1280x720"),
        (nil, nil, (600, 1000), "608x1008"),
        ((16, 9), nil, nil, "1024x576"),
        (nil, 2048, nil, "2048x2048"),
        ((16, 9), 1280, nil, "1280x720"),
        ((3, 2), 1536, nil, "1536x1024"),
        ((9, 16), 1024, nil, "576x1024"),
        ((1, 1), nil, (1000, 600), "1008x1008"),
        (nil, 512, (1000, 600), "512x304"),
        ((1, 1000), 256, nil, "16x256"),
    ])
    func sizeFollowsTheRequestThenTheSourceThenDefaults(aspect: (Int, Int)?, longEdge: Int?, source: (Int, Int)?, size: String?) {
        let request = ImageRequest(prompt: "a fox", aspect: aspect.map { .init($0.0, $0.1) }, longEdge: longEdge)
        #expect(request.size(source: source.map { (width: $0.0, height: $0.1) }) == size)
    }

    @Test func theToolIsCalledGenerateImageAndRequiresAPrompt() {
        let spec = ImageRequest.toolSpec
        #expect(spec.name == "generate_image")
        #expect(spec.parameters["required"] == .array([.string("prompt")]))
        guard case .object(let properties)? = spec.parameters["properties"] else {
            Issue.record("no properties")
            return
        }
        #expect(Set(properties.keys) == ["prompt", "source_images", "aspect_ratio", "resolution"])
        #expect(properties["source_images"]?["type"]?.string == "array")
    }
}
