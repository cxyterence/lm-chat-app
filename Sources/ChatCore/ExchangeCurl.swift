import Foundation

extension Exchange {
    /// A `curl` command that repeats the request. The key is `$API_KEY`, so set it first. Photos can't be
    /// repeated from here, so a request that held some starts with a comment saying where they go.
    public var curl: String { curl(using: placeholders) }

    /// The same, from `placeholders` already read from this request. Reading them decodes the whole body, which holds
    /// megabytes when there are photos, so a view that has them should not make this read them again.
    public func curl(using placeholders: ImagePlaceholders) -> String {
        let form = ImagePlaceholders.boundary(in: requestHeader("Content-Type")).flatMap { MultipartBody(requestBody, boundary: $0) }

        var words = ["curl" + (requestHeader("Accept") == "text/event-stream" ? " -N" : "")
                     + (method == "GET" ? "" : " -X \(method)") + " " + Self.singleQuoted(url.absoluteString)]
        for header in requestHeaders where !(form != nil && header.name.caseInsensitiveCompare("Content-Type") == .orderedSame) {
            let line = "\(header.name): \(header.value)"
            words.append("-H " + (line.contains("$API_KEY") ? Self.doubleQuoted(line) : Self.singleQuoted(line)))
        }
        if let form {
            for part in form.parts {
                let name = part.name ?? ""
                if let filename = part.filename {
                    words.append("-F " + Self.singleQuoted("\(name)=@\(filename)" + (part.contentType.map { ";type=\($0)" } ?? "")))
                } else {
                    words.append("--form-string " + Self.singleQuoted("\(name)=" + String(decoding: part.data, as: UTF8.self)))
                }
            }
        } else if !requestBody.isEmpty {
            words.append("-d " + Self.singleQuoted(placeholders.text))
        }

        let note = placeholders.isEmpty ? "" : form != nil
            ? "# Photos were left out. Point each @file at a photo of your own.\n"
            : "# Photos were left out. Replace each <image> placeholder with a data:image URL of your own.\n"
        return note + words.joined(separator: " \\\n  ")
    }

    private static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Double quotes, so the shell fills in `$API_KEY`. Nothing else in the text gets to be special.
    private static func doubleQuoted(_ text: String) -> String {
        var escaped = text
        for special in ["\\", "\"", "`", "$"] { escaped = escaped.replacingOccurrences(of: special, with: "\\" + special) }
        return "\"" + escaped.replacingOccurrences(of: "\\$API_KEY", with: "$API_KEY") + "\""
    }
}
