import Foundation

/// What a model asked the image tool for, decoded from the tool call's JSON arguments.
public struct ImageRequest: Equatable, Sendable {
    public struct Aspect: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
    }

    /// A message for the model that made the call, which reads it and tries again.
    public struct Invalid: Error, Equatable, LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public static let longEdges = 256...4096

    public let prompt: String
    public let aspect: Aspect?
    public let longEdge: Int?
    /// 1-based labels of the chat's pictures to edit, as `ImageLabels` numbers them. Empty draws from scratch.
    public let sources: [Int]

    public init(prompt: String, aspect: Aspect? = nil, longEdge: Int? = nil, sources: [Int] = []) {
        self.prompt = prompt
        self.aspect = aspect
        self.longEdge = longEdge
        self.sources = sources
    }

    public static func parse(arguments: String) throws -> ImageRequest {
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)), case .object = decoded else {
            throw Invalid("The arguments must be a JSON object with a prompt.")
        }
        guard let prompt = decoded["prompt"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw Invalid("prompt is required. Describe the whole picture in words.")
        }

        var aspect: Aspect?
        if let value = decoded["aspect_ratio"], value != .null {
            guard let parsed = value.string.flatMap(parseAspect) else { throw Invalid("aspect_ratio must look like 16:9.") }
            aspect = parsed
        }

        var longEdge: Int?
        if let value = decoded["resolution"], value != .null {
            guard let parsed = (value.string ?? whole(value).map(String.init)).flatMap(parseLongEdge) else {
                throw Invalid("resolution must be 1k, 2k, 4k or a pixel count from \(longEdges.lowerBound) to \(longEdges.upperBound).")
            }
            longEdge = parsed
        }

        var sources: [Int] = []
        if let value = decoded["source_images"], value != .null {
            guard case .array(let labels) = value else { throw Invalid(sourcesMessage) }
            sources = try labels.map { label in
                guard let number = whole(label) else { throw Invalid(sourcesMessage) }
                return number
            }
        }
        return ImageRequest(prompt: prompt, aspect: aspect, longEdge: longEdge, sources: sources)
    }

    private static let sourcesMessage = "source_images must be a list of picture numbers such as [1, 2]."

    private static func whole(_ value: JSONValue) -> Int? {
        if case .number(let number) = value { Int(exactly: number) } else { nil }
    }

    /// `W:H` with both sides positive, as in `16:9`.
    public static func parseAspect(_ value: String) -> Aspect? {
        guard let match = value.wholeMatch(of: /(\d+):(\d+)/), let w = Int(match.1), let h = Int(match.2), w > 0, h > 0
        else { return nil }
        return Aspect(w, h)
    }

    /// `1k`, `2k` or `4k`, or a pixel count within `longEdges`.
    public static func parseLongEdge(_ value: String) -> Int? {
        switch value.lowercased() {
        case "1k": return 1024
        case "2k": return 2048
        case "4k": return 4096
        case let digits:
            return Int(digits).flatMap { longEdges.contains($0) ? $0 : nil }
        }
    }

    /// The `WxH` to ask for, both edges a multiple of 16. The request's shape and size win over the first source
    /// picture's own, which win over a 1:1 picture 1024 on a side. Nil when there is nothing to go on.
    public func size(source: (width: Int, height: Int)?) -> String? {
        guard aspect != nil || longEdge != nil || source != nil else { return nil }
        let ratio = aspect.map { Double($0.width) / Double($0.height) }
            ?? source.map { Double($0.width) / Double($0.height) } ?? 1
        let long = Double(longEdge ?? source.map { max($0.width, $0.height) } ?? 1024)
        let (width, height) = ratio >= 1 ? (long, long / ratio) : (long * ratio, long)
        func snap(_ edge: Double) -> Int { max(16, Int((edge / 16).rounded()) * 16) }
        return "\(snap(width))x\(snap(height))"
    }
}

extension ImageRequest {
    public static let toolName = "generate_image"

    /// The tool as the model sees it. `parse(arguments:)` reads what it sends back.
    public static let toolSpec = ToolSpec(
        name: toolName,
        description: """
            Draws a new picture, or edits pictures already in the chat, and shows the result to the user. \
            Write a detailed prompt that describes the whole picture you want: subject, setting, style, \
            lighting, colours and composition. The image model sees only the prompt, not the conversation, \
            so make it complete by itself. To edit, say what to change and what to keep. \
            Every picture in the chat, whether the user attached it or one was drawn earlier, is labelled \
            "image 1", "image 2" and so on in order of appearance. Put the numbers of the pictures to edit or \
            draw from in source_images. Leave source_images out to draw from scratch.
            """,
        parameters: try! JSONDecoder().decode(JSONValue.self, from: Data("""
            {"type": "object",
             "properties": {
               "prompt": {"type": "string", "description": "A detailed, self-contained description of the whole picture."},
               "source_images": {"type": "array", "items": {"type": "integer"},
                                 "description": "Numbers of the chat's pictures to edit or use as references, such as [1]."},
               "aspect_ratio": {"type": "string", "description": "Width:height of the picture, such as 16:9, 1:1 or 9:16. Leave out unless the user asked for a shape."},
               "resolution": {"type": "string", "description": "Length of the picture's longer edge: 1k, 2k, 4k, or a pixel count from 256 to 4096. Leave out unless the user asked for a size."}
             },
             "required": ["prompt"]}
            """.utf8))
    )
}
