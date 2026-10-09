import Foundation

/// One MCP server the host is willing to call.
///
/// `envSecrets` and `headerSecrets` map a variable or header name to a secret-account name.
/// The file must not contain the secret value. `allow` is the remote tool allowlist.
/// An empty allowlist exposes no tools.
public struct MCPServerConfig: Codable, Sendable, Equatable {
    public var name: String
    /// `stdio` or `http`.
    public var transport: String
    public var command: String?
    public var args: [String]
    public var url: String?
    public var envSecrets: [String: String]
    public var headerSecrets: [String: String]
    public var allow: [String]
    public var timeoutSeconds: Double
    public var tools: [String: MCPToolOverride]

    public init(
        name: String,
        transport: String,
        command: String? = nil,
        args: [String] = [],
        url: String? = nil,
        envSecrets: [String: String] = [:],
        headerSecrets: [String: String] = [:],
        allow: [String] = [],
        timeoutSeconds: Double = 30,
        tools: [String: MCPToolOverride] = [:]
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.envSecrets = envSecrets
        self.headerSecrets = headerSecrets
        self.allow = allow
        self.timeoutSeconds = timeoutSeconds
        self.tools = tools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        transport = try container.decode(String.self, forKey: .transport)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        url = try container.decodeIfPresent(String.self, forKey: .url)
        envSecrets = try container.decodeIfPresent([String: String].self, forKey: .envSecrets) ?? [:]
        headerSecrets = try container.decodeIfPresent([String: String].self, forKey: .headerSecrets) ?? [:]
        allow = try container.decodeIfPresent([String].self, forKey: .allow) ?? []
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 30
        tools = try container.decodeIfPresent([String: MCPToolOverride].self, forKey: .tools) ?? [:]
    }

    public static func parse(_ json: String) throws -> MCPServerConfig {
        guard let data = json.data(using: .utf8) else {
            throw MCPCallError("mcp config is not utf-8")
        }
        do {
            return try JSONDecoder().decode(MCPServerConfig.self, from: data)
        } catch let error as MCPCallError {
            throw error
        } catch {
            throw MCPCallError("mcp config is invalid")
        }
    }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPCallError("mcp config is not utf-8")
        }
        return text
    }

    public func validate() throws {
        let scalars = name.unicodeScalars
        let named = !scalars.isEmpty && scalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }
        if !named {
            throw MCPCallError("invalid mcp server name")
        }
        switch transport {
        case "stdio":
            if command?.isEmpty != false {
                throw MCPCallError("stdio mcp server needs a command")
            }
        case "http":
            if url?.isEmpty != false {
                throw MCPCallError("http mcp server needs a url")
            }
        default:
            throw MCPCallError("unknown mcp transport")
        }
    }
}
