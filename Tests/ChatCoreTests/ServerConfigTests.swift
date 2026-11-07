import Testing
@testable import ChatCore

struct ServerConfigTests {
    @Test(arguments: [
        ("192.168.1.5:1234", "http://192.168.1.5:1234/v1"),
        ("http://host:11434", "http://host:11434/v1"),
        ("http://host:8080/v1/", "http://host:8080/v1"),
        ("https://box.ts.net/custom/v1", "https://box.ts.net/custom/v1"),
        ("  https://api.example.com  ", "https://api.example.com/v1"),
        ("HTTP://Host:1/", "http://host:1/v1"),
    ])
    func normalizes(input: String, expected: String) throws {
        let config = try ServerConfig.parse(baseURL: input, apiKey: "")
        #expect(config.baseURL.absoluteString.lowercased() == expected.lowercased())
    }

    @Test(arguments: ["", "   ", "not a url", "ftp://x"])
    func rejects(input: String) {
        #expect(throws: ServerConfig.ParseError.self) {
            try ServerConfig.parse(baseURL: input, apiKey: "")
        }
    }

    @Test func blankKeyIsNil() throws {
        #expect(try ServerConfig.parse(baseURL: "h:1", apiKey: "  ").apiKey == nil)
        #expect(try ServerConfig.parse(baseURL: "h:1", apiKey: " sk-1 ").apiKey == "sk-1")
    }
}
