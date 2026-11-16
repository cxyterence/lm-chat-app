import ChatCore
import Foundation

struct Options {
    var base: String?
    var key = ""
    var model: String?
    var listModels = false
    var titleOnly = false
    var listEfforts = false
    var effort: ReasoningEffort?
    var prompt: String?
    var images: [String] = []
    var imageOut: String?
    var aspect: ImageRequest.Aspect?
    var longEdge: Int?
}

func write(_ text: String, to handle: FileHandle) {
    handle.write(Data(text.utf8))
}

func fail(_ message: String) -> Never {
    write("error: \(message)\n", to: .standardError)
    exit(1)
}

let usage = "usage: chatcli --base <url> [--key K] [--model M] [--models] [--efforts] [--title] [--effort <\(ReasoningEffort.allCases.map(\.rawValue).joined(separator: "|"))>] [--image <file>]... [--image-out <file> [--ar W:H] [--res N]] \"prompt\"\n  --image-out writes a picture from an image model, to probe the server. With --image it edits those photos. --ar picks the shape, such as 16:9. --res picks the long edge: 1k, 2k, 4k or 256 to 4096 pixels."

func parseOptions(_ args: [String]) -> Options {
    var options = Options()
    var iterator = args.makeIterator()
    func value(for flag: String) -> String {
        guard let next = iterator.next() else { fail("\(flag) needs a value\n\(usage)") }
        return next
    }
    while let arg = iterator.next() {
        switch arg {
        case "--base": options.base = value(for: arg)
        case "--key": options.key = value(for: arg)
        case "--model": options.model = value(for: arg)
        case "--effort":
            let raw = value(for: arg)
            guard let effort = ReasoningEffort(rawValue: raw) else {
                fail("invalid --effort \(raw). valid: \(ReasoningEffort.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            options.effort = effort
        case "--image": options.images.append(value(for: arg))
        case "--image-out": options.imageOut = value(for: arg)
        case "--ar":
            let raw = value(for: arg)
            guard let aspect = ImageRequest.parseAspect(raw) else { fail("invalid --ar \(raw). expected W:H, such as 16:9") }
            options.aspect = aspect
        case "--res":
            let raw = value(for: arg)
            guard let longEdge = ImageRequest.parseLongEdge(raw) else {
                fail("invalid --res \(raw). expected 1k, 2k, 4k or 256 to 4096")
            }
            options.longEdge = longEdge
        case "--models": options.listModels = true
        case "--title": options.titleOnly = true
        case "--efforts": options.listEfforts = true
        case "-h", "--help": print(usage); exit(0)
        default: options.prompt = arg
        }
    }
    return options
}

func run(_ options: Options) async throws {
    guard let base = options.base else { fail("--base is required\n\(usage)") }
    let client = ChatClient(config: try ServerConfig.parse(baseURL: base, apiKey: options.key))

    let models = try await client.models()
    if options.listModels {
        models.forEach { print($0.makesImages ? "\($0.id)  (image)" : $0.id) }
        return
    }
    guard let model = options.model ?? models.first?.id else { fail("server lists no models; pass --model") }
    if options.listEfforts {
        let levels = try await client.reasoningEfforts(model: model)
        print(levels.isEmpty ? "(not adjustable)" : levels.map(\.rawValue).joined(separator: " "))
        return
    }
    guard let prompt = options.prompt else { fail("a prompt is required\n\(usage)") }
    if options.titleOnly {
        guard let title = try await client.title(model: model, for: prompt) else { fail("model gave no usable title") }
        print(title)
        return
    }

    let store = ImageStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("chatcli-\(UUID())"))
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let jpegs = try options.images.map { path in
        guard let jpeg = ImageAttachment.jpeg(from: try Data(contentsOf: URL(fileURLWithPath: path))) else {
            fail("\(path) is not an image")
        }
        return jpeg
    }

    if let path = options.imageOut {
        let request = ImageRequest(prompt: prompt, aspect: options.aspect, longEdge: options.longEdge)
        try await client.image(model: model, prompt: prompt, sources: jpegs,
                               size: client.imageSize(for: request, source: jpegs.first))
            .write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        return
    }

    let images = try jpegs.map { try store.save($0) }

    var wroteReasoning = false
    for try await event in client.stream(
        model: model,
        messages: [ChatMessage(role: .user, content: prompt, images: images)],
        reasoningEffort: options.effort,
        images: store
    ) {
        switch event {
        case .reasoning(let text):
            write("\u{1B}[2m\(text)\u{1B}[0m", to: .standardError)
            wroteReasoning = true
        case .content(let text):
            if wroteReasoning { write("\n", to: .standardError); wroteReasoning = false }
            write(text, to: .standardOutput)
        case .done:
            write("\n", to: .standardOutput)
        case .toolCall:
            break
        }
    }
}

do {
    try await run(parseOptions(Array(CommandLine.arguments.dropFirst())))
} catch {
    fail(error.localizedDescription)
}
