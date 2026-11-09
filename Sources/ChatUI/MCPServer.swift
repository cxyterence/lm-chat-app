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
    static func offer(_ servers: [(MCPServer, MCPClient, [MCPTool])]) -> [OfferedTool] {
        var taken = Set<String>()
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
