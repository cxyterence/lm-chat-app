import ChatUI
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: uisnapshot <output-directory>\n".utf8))
    exit(2)
}

do {
    try await UISnapshot.render(to: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
} catch {
    FileHandle.standardError.write(Data("uisnapshot: \(error.localizedDescription)\n".utf8))
    exit(1)
}
