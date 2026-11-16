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
    /// The image tool's name is always taken, so no server's tool can answer to it.
    static func offer(_ servers: [(MCPServer, MCPClient, [MCPTool])]) -> [OfferedTool] {
        var taken: Set = [ImageRequest.toolName]
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

    var name: String {
        switch self {
        case .mcp(let tool): tool.name
        case .image: ImageRequest.toolName
        }
    }

    var spec: ToolSpec {
        switch self {
        case .mcp(let tool): tool.spec
        case .image: ImageRequest.toolSpec
        }
    }

    /// Shown beside the call: the MCP server's name, or the image connection's.
    var serverName: String {
        switch self {
        case .mcp(let tool): tool.server.name
        case .image(let connection, _, _): connection
        }
    }
}
