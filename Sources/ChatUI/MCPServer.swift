import ChatCore
import Foundation

/// A saved MCP server. Its token lives in `Secrets` under `secretAccount`.
struct MCPServer: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: URL
    var enabled = true

    var secretAccount: String { "mcp.\(id.uuidString)" }

    /// GitHub's hosted server, read-only so the model can look but not change anything until asked for more.
    static func github() -> MCPServer {
        MCPServer(name: "GitHub", url: URL(string: "https://api.githubcopilot.com/mcp/readonly")!)
    }

    var isGitHub: Bool { url.host() == "api.githubcopilot.com" }
}

enum MCPStatus: Equatable {
    case connecting
    case ready([MCPTool])
    case failed(String)
}

/// A tool as offered to the model. Its name is unique across servers and safe for the wire.
struct OfferedTool {
    let name: String
    let tool: MCPTool
    let server: MCPServer
    let client: MCPClient

    var spec: ToolSpec { ToolSpec(name: name, description: tool.description, parameters: tool.inputSchema) }

    /// OpenAI allows letters, digits, `_` and `-`, up to 64 characters. Clashes take the server's name as a prefix.
    /// The app's own tools' names are always taken, so no server's tool can answer to them.
    static func offer(_ servers: [(MCPServer, MCPClient, [MCPTool])]) -> [OfferedTool] {
        var taken: Set = [ImageRequest.toolName, FetchRequest.toolName, WebSearch.toolName]
        var offered: [OfferedTool] = []
        for (server, client, tools) in servers {
            for tool in tools {
                var name = wireName(tool.name)
                if taken.contains(name) { name = wireName(server.name + "_" + tool.name) }
                guard taken.insert(name).inserted else { continue }
                offered.append(OfferedTool(name: name, tool: tool, server: server, client: client))
            }
        }
        return offered
    }

    private static func wireName(_ raw: String) -> String {
        String(String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" ? Character($0) : "_" })
            .prefix(64))
    }
}

/// A tool offered with one reply, by what runs it.
enum ReplyTool {
    case mcp(OfferedTool)
    /// `generate_image`, which the app runs itself against the image model's own connection.
    case image(connection: String, config: ServerConfig, model: String)
    /// `fetch_url`, which the app runs itself from this device.
    case fetch
    /// `web_search`, which the app runs through Serper with the user's key.
    case search(SerperClient)

    var name: String {
        switch self {
        case .mcp(let tool): tool.name
        case .image: ImageRequest.toolName
        case .fetch: FetchRequest.toolName
        case .search: WebSearch.toolName
        }
    }

    var spec: ToolSpec {
        switch self {
        case .mcp(let tool): tool.spec
        case .image: ImageRequest.toolSpec
        case .fetch: FetchRequest.toolSpec
        case .search: WebSearch.toolSpec
        }
    }

    /// Shown beside `call`: the MCP server's name, the image connection's, the address of the page, or the query.
    func serverName(for call: ToolCall) -> String {
        switch self {
        case .mcp(let tool): tool.server.name
        case .image(let connection, _, _): connection
        case .fetch: FetchRequest.address(in: call.arguments)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .search: WebSearch.query(in: call.arguments) ?? ""
        }
    }
}

extension ToolCall {
    /// What to ask before running this call, and the address it would read when it is a fetch. The address is
    /// shown whole, since a page can hide what it wants sent away at the end of one.
    var approval: (question: String, address: String?) {
        guard name == FetchRequest.toolName else { return ("This tool can make changes. Run it?", nil) }
        return ("The model wants to read a page you didn't mention. Read it?", FetchRequest.address(in: arguments) ?? server)
    }
}
