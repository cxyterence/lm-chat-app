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
}

func write(_ text: String, to handle: FileHandle) {
    handle.write(Data(text.utf8))
}

func fail(_ message: String) -> Never {
    write("error: \(message)\n", to: .standardError)
    exit(1)
}

let usage = "usage: chatcli --base <url> [--key K] [--model M] [--models] [--efforts] [--title] [--effort <\(ReasoningEffort.allCases.map(\.rawValue).joined(separator: "|"))>] [--image <file>]... \"prompt\""

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
        models.forEach { print($0) }
        return
    }
    guard let model = options.model ?? models.first else { fail("server lists no models; pass --model") }
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

    let images = try options.images.map { path in
        guard let jpeg = ImageAttachment.jpeg(from: try Data(contentsOf: URL(fileURLWithPath: path))) else {
            fail("\(path) is not an image")
        }
        return jpeg
    }

    var wroteReasoning = false
    for try await event in client.stream(
        model: model,
        messages: [ChatMessage(role: .user, content: prompt, images: images)],
        reasoningEffort: options.effort
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
        }
    }
}

do {
    try await run(parseOptions(Array(CommandLine.arguments.dropFirst())))
} catch {
    fail(error.localizedDescription)
}
