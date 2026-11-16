import ChatCore
import Foundation

struct Options {
    var base: String?
    var key = ""
    var model: String?
    var listModels = false
    var titleOnly = false
    var listEfforts = false
    var capabilities = false
    var inspect = false
    var api = WireAPI.chatCompletions
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

/// Every request made this run, for `--inspect`. Empty without it.
final class ExchangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [Exchange] = []

    func add(_ exchange: Exchange) { lock.withLock { exchanges.append(exchange) } }
    var all: [Exchange] { lock.withLock { exchanges } }
}

let exchangeLog = ExchangeLog()

func fail(_ message: String) -> Never {
    printExchanges()
    write("error: \(message)\n", to: .standardError)
    exit(1)
}

func seconds(_ interval: TimeInterval) -> String { String(format: "%.3f s", interval) }

/// Each request in the order it finished: status, timing, tokens, then the curl command that repeats it.
/// The key is never in an exchange, so none of this shows it.
func printExchanges() {
    let all = exchangeLog.all
    for (index, exchange) in all.enumerated() {
        var lines = ["", "=== request \(index + 1) of \(all.count): \(exchange.purpose.rawValue) ===",
                     "\(exchange.method) \(exchange.url.absoluteString)",
                     "status: \(exchange.status.map(String.init) ?? "no response")"]
        if let error = exchange.error { lines.append("error: \(error)") }
        if let byte = exchange.firstByteAt { lines.append("time to first byte: \(seconds(byte.timeIntervalSince(exchange.startedAt)))") }
        let stats = exchange.stats
        if let first = stats.timeToFirstToken { lines.append("time to first token: \(seconds(first))") }
        if let total = stats.totalTime { lines.append("total time: \(seconds(total))") }
        if let rate = stats.tokensPerSecond { lines.append(String(format: "speed: %.1f tokens/s", rate)) }
        if let usage = exchange.usage {
            let counts = [usage.promptTokens.map { "\($0) prompt" }, usage.completionTokens.map { "\($0) completion" },
                          usage.reasoningTokens.map { "\($0) reasoning" }].compactMap { $0 }
            lines.append("tokens: \(counts.joined(separator: ", "))")
        } else if exchange.purpose == .chat || exchange.purpose == .title {
            lines.append("tokens: not reported")
        }
        if let status = exchange.status, !(200..<300).contains(status) {
            lines.append("response: \(exchange.responseBody.prefix(1000))")
        }
        lines += ["curl:", exchange.curl]
        print(lines.joined(separator: "\n"))
    }
}

func printReport(_ report: CapabilityReport, model: String) {
    func describe(_ tools: ToolSupport) -> String {
        switch tools {
        case .yes: "yes"
        case .onlyWithReasoningOff: "only with reasoning off"
        case .no(let reason): "no (\(reason))"
        case .unknown(let reason): "unknown (\(reason))"
        }
    }
    func describe(_ support: Support) -> String {
        switch support {
        case .yes: "yes"
        case .no(let reason): "no (\(reason))"
        case .unknown(let reason): "unknown (\(reason))"
        }
    }
    print("model: \(model)")
    print("tools: \(describe(report.tools))")
    print("vision: \(describe(report.vision))")
    print("reasoning efforts: \(report.efforts.isEmpty ? "not adjustable" : report.efforts.map(\.rawValue).joined(separator: " "))")
    print("context length: \(report.contextLength.map(String.init) ?? "not reported")")
    print(report.server.isEmpty ? "server: nothing reported" : "server:")
    report.server.forEach { print("  \($0.name): \($0.value)") }
}

let usage = "usage: chatcli --base <url> [--key K] [--model M] [--models] [--efforts] [--capabilities] [--inspect] [--api chat-completions|responses] [--title] [--effort <\(ReasoningEffort.allCases.map(\.rawValue).joined(separator: "|"))>] [--image <file>]... [--image-out <file> [--ar W:H] [--res N]] \"prompt\"\n  --api picks the wire format: chat-completions (the default) or responses. --capabilities checks what --model supports: tools, vision, reasoning levels, context length. --inspect prints every request made, with status, timing, tokens and a curl command, after the reply.\n  --image-out writes a picture from an image model, to probe the server. With --image it edits those photos. --ar picks the shape, such as 16:9. --res picks the long edge: 1k, 2k, 4k or 256 to 4096 pixels."

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
        case "--api":
            switch value(for: arg) {
            case "chat-completions": options.api = .chatCompletions
            case "responses": options.api = .responses
            case let other: fail("invalid --api \(other). valid: chat-completions, responses")
            }
        case "--models": options.listModels = true
        case "--title": options.titleOnly = true
        case "--efforts": options.listEfforts = true
        case "--capabilities": options.capabilities = true
        case "--inspect": options.inspect = true
        case "-h", "--help": print(usage); exit(0)
        default: options.prompt = arg
        }
    }
    return options
}

func run(_ options: Options) async throws {
    guard let base = options.base else { fail("--base is required\n\(usage)") }
    var record: (@Sendable (Exchange) -> Void)?
    if options.inspect { record = { exchangeLog.add($0) } }
    var config = try ServerConfig.parse(baseURL: base, apiKey: options.key)
    config.api = options.api
    let client = ChatClient(config: config, record: record)

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
    if options.capabilities {
        printReport(try await client.capabilities(model: model), model: model)
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
        case .adapted(let adaptation):
            write("note: \(adaptation.note)\n", to: .standardError)
        case .toolCall, .usage:
            break
        }
    }
}

do {
    try await run(parseOptions(Array(CommandLine.arguments.dropFirst())))
    printExchanges()
} catch {
    fail(error.localizedDescription)
}
