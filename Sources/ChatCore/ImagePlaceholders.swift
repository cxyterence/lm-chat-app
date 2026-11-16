import Foundation

/// A request body made fit to read and edit. Every photo, which would fill the screen with base64, is swapped
/// for a short token such as `<image 1: 312 KB>`, and the tokens are kept so `restore` can put them back.
///
/// A JSON body is pretty-printed with its keys in order. A multipart body keeps its wire layout, with fields as
/// text and each file as `<file image1.jpg: 312 KB>`. Any other body is shown as text.
public struct ImagePlaceholders: Equatable, Sendable {
    enum Layout: Equatable, Sendable {
        case plain, json
        case multipart(boundary: String)
    }

    /// The body as the user sees and edits it.
    public let text: String
    let layout: Layout
    /// What each token stands for: a whole data URL in JSON, a file's bytes in a form.
    private let originals: [String: Data]

    /// True when the body holds no photos, so `text` is the whole body.
    public var isEmpty: Bool { originals.isEmpty }

    public init(body: Data, contentType: String?) {
        var originals: [String: Data] = [:]
        if let boundary = Self.boundary(in: contentType), let form = MultipartBody(body, boundary: boundary) {
            var text = ""
            for part in form.parts {
                text += "--\(boundary)\r\n" + part.headers.joined(separator: "\r\n") + "\r\n\r\n"
                if let filename = part.filename {
                    let token = Self.unique("<file \(filename): \(BodyCapture.sizeLabel(part.data.count))>", in: originals)
                    originals[token] = part.data
                    text += token
                } else {
                    text += String(decoding: part.data, as: UTF8.self)
                }
                text += "\r\n"
            }
            self.init(text: text + "--\(boundary)--\r\n", layout: .multipart(boundary: boundary), originals: originals)
        } else if let json = try? JSONDecoder().decode(JSONValue.self, from: body), json.isContainer {
            let redacted = Self.redact(json, into: &originals)
            self.init(text: Self.render(redacted), layout: .json, originals: originals)
        } else {
            self.init(text: String(decoding: body, as: UTF8.self), layout: .plain, originals: [:])
        }
    }

    private init(text: String, layout: Layout, originals: [String: Data]) {
        self.text = text
        self.layout = layout
        self.originals = originals
    }

    /// The bytes to send for `edited`, which started as `text`. Each token that is still there turns back into
    /// its photo, so an edit anywhere else is kept and a token the user deleted drops its photo.
    public func restore(_ edited: String) -> Data {
        guard case .multipart(let boundary) = layout else { return splice(edited) }

        // Editors may turn the form's CRLF line breaks into LF, so the structure is rebuilt from lines.
        let crlf = Data("\r\n".utf8)
        var out = Data()
        var headers: [String] = [], value: [String] = []
        var inPart = false, inValue = false
        func flush() {
            guard inPart else { return }
            out += Data("--\(boundary)\r\n\(headers.joined(separator: "\r\n"))\r\n\r\n".utf8) + splice(value.joined(separator: "\n")) + crlf
        }
        for line in edited.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "--\(boundary)" || line == "--\(boundary)--" {
                flush()
                (headers, value, inPart, inValue) = ([], [], line == "--\(boundary)", false)
                if !inPart { break }
            } else if inPart && inValue {
                value.append(String(line))
            } else if inPart {
                if line.isEmpty { inValue = true } else { headers.append(String(line)) }
            }
        }
        flush()
        return out + Data("--\(boundary)--\r\n".utf8)
    }

    private func splice(_ text: String) -> Data {
        var out = Data()
        var rest = Substring(text)
        while let (range, token) = originals.keys.compactMap({ token in rest.range(of: token).map { ($0, token) } })
            .min(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            out += Data(rest[..<range.lowerBound].utf8) + originals[token]!
            rest = rest[range.upperBound...]
        }
        return out + Data(rest.utf8)
    }

    static func boundary(in contentType: String?) -> String? {
        guard let contentType, contentType.lowercased().hasPrefix("multipart/"),
              let match = contentType.firstMatch(of: /boundary="?([^";\s]+)"?/)
        else { return nil }
        return String(match.1)
    }

    private static func unique(_ token: String, in originals: [String: Data]) -> String {
        var candidate = token, copy = 1
        while originals[candidate] != nil {
            copy += 1
            candidate = token.dropLast() + " #\(copy)>"
        }
        return candidate
    }

    private static func redact(_ value: JSONValue, into originals: inout [String: Data]) -> JSONValue {
        switch value {
        case .string(let text):
            guard let size = photoSize(text) else { return value }
            let token = unique("<image \(originals.count + 1): \(BodyCapture.sizeLabel(size))>", in: originals)
            originals[token] = Data(text.utf8)
            return .string(token)
        case .array(let items):
            var redacted: [JSONValue] = []
            for item in items { redacted.append(redact(item, into: &originals)) }
            return .array(redacted)
        case .object(let fields):
            var redacted: [String: JSONValue] = [:]
            for key in fields.keys.sorted() { redacted[key] = redact(fields[key]!, into: &originals) }
            return .object(redacted)
        case .null, .bool, .number:
            return value
        }
    }

    /// The decoded size of an inline `data:image/...;base64,` URL, nil for any other text.
    private static func photoSize(_ text: String) -> Int? {
        guard text.hasPrefix("data:image/"), let marker = text.range(of: ";base64,") else { return nil }
        let payload = text[marker.upperBound...]
        let padding = payload.hasSuffix("==") ? 2 : payload.hasSuffix("=") ? 1 : 0
        return payload.utf8.count * 3 / 4 - padding
    }

    private static func render(_ value: JSONValue, depth: Int = 0) -> String {
        let inner = String(repeating: "  ", count: depth + 1), outer = String(repeating: "  ", count: depth)
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return Int(exactly: number).map(String.init) ?? "\(number)"
        case .string(let text): return quoted(text)
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { inner + render($0, depth: depth + 1) }.joined(separator: ",\n") + "\n\(outer)]"
        case .object(let fields):
            guard !fields.isEmpty else { return "{}" }
            return "{\n" + fields.keys.sorted().map { "\(inner)\(quoted($0)): \(render(fields[$0]!, depth: depth + 1))" }
                .joined(separator: ",\n") + "\n\(outer)}"
        }
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension Exchange {
    public var placeholders: ImagePlaceholders {
        ImagePlaceholders(body: requestBody, contentType: requestHeader("Content-Type"))
    }

    /// The request body to show and edit. Keep `placeholders` while editing, to `restore` the result.
    public var displayBody: String { placeholders.text }
}

private extension JSONValue {
    var isContainer: Bool {
        switch self {
        case .array, .object: true
        default: false
        }
    }
}

/// The parts of a `multipart/form-data` body.
struct MultipartBody {
    struct Part {
        var headers: [String]
        var data: Data

        var name: String? { disposition(of: /;\s*name="([^"]*)"/) }
        var filename: String? { disposition(of: /;\s*filename="([^"]*)"/) }
        var contentType: String? {
            headers.first { $0.lowercased().hasPrefix("content-type:") }
                .map { $0.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces) }
        }

        private func disposition(of pattern: Regex<(Substring, Substring)>) -> String? {
            headers.first { $0.lowercased().hasPrefix("content-disposition:") }
                .flatMap { $0.firstMatch(of: pattern) }.map { String($0.1) }
        }
    }

    var parts: [Part] = []

    /// Nil unless the body starts with the boundary and every part is closed, as `MultipartForm` writes them.
    init?(_ body: Data, boundary: String) {
        let body = Data(body)
        let opening = Data("--\(boundary)".utf8), separator = Data("\r\n--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8), blank = Data("\r\n\r\n".utf8)
        guard body.starts(with: opening) else { return nil }
        var cursor = opening.count
        while !body[cursor...].starts(with: Data("--".utf8)) {
            guard body[cursor...].starts(with: crlf),
                  let end = body.range(of: separator, in: (cursor + 2)..<body.endIndex)
            else { return nil }
            let content = Data(body[(cursor + 2)..<end.lowerBound])
            // With an empty value the blank line is the content's last CRLF plus the separator's.
            if let split = (content + crlf).range(of: blank) {
                let head = String(decoding: content[..<min(split.lowerBound, content.endIndex)], as: UTF8.self)
                parts.append(Part(headers: head.components(separatedBy: "\r\n"),
                                  data: split.upperBound < content.endIndex ? Data(content[split.upperBound...]) : Data()))
            } else {
                parts.append(Part(headers: [], data: content))
            }
            cursor = end.upperBound
        }
    }
}
