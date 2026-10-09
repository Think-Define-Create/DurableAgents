import DurableCore
import MCP

enum MCPJSON {
    static func value(_ json: JSONValue) -> Value {
        switch json {
        case .null:
            return .null
        case .bool(let item):
            return .bool(item)
        case .int(let item):
            return .int(Int(item))
        case .double(let item):
            return .double(item)
        case .string(let item):
            return .string(item)
        case .array(let items):
            return .array(items.map(value))
        case .object(let fields):
            return .object(fields.mapValues(value))
        }
    }

    static func json(_ value: Value) -> JSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let item):
            return .bool(item)
        case .int(let item):
            return .int(Int64(item))
        case .double(let item):
            return .double(item)
        case .string(let item):
            return .string(item)
        case .data(_, let data):
            return .string("[data \(data.count) bytes]")
        case .array(let items):
            return .array(items.map(json))
        case .object(let fields):
            return .object(fields.mapValues(json))
        }
    }

    static func arguments(_ json: JSONValue) throws -> [String: Value]? {
        switch json {
        case .null:
            return nil
        case .object(let fields):
            return fields.mapValues(value)
        default:
            throw MCPCallError("mcp arguments must be an object")
        }
    }

    static func schemaString(_ value: Value) -> String {
        json(value).canonicalJSON()
    }

    static func listed(_ tool: MCP.Tool) -> MCPListedTool {
        MCPListedTool(
            name: tool.name,
            summary: tool.description ?? "",
            inputSchemaJSON: schemaString(tool.inputSchema),
            hints: MCPToolHints(
                readOnlyHint: tool.annotations.readOnlyHint,
                destructiveHint: tool.annotations.destructiveHint,
                idempotentHint: tool.annotations.idempotentHint,
                openWorldHint: tool.annotations.openWorldHint
            )
        )
    }

    static func texts(_ content: [MCP.Tool.Content]) -> [String] {
        content.map { item in
            switch item {
            case .text(let text, _, _):
                return text
            case .image(_, let mimeType, _, _):
                return "[image \(mimeType)]"
            case .audio(_, let mimeType, _, _):
                return "[audio \(mimeType)]"
            case .resource:
                return "[resource]"
            case .resourceLink(let uri, let name, _, _, _, _):
                return "[resource_link \(name) \(uri)]"
            }
        }
    }
}

/// A tool returned by `tools/list`, reduced to the fields DurableAgents uses.
public struct MCPListedTool: Sendable, Equatable {
    public var name: String
    public var summary: String
    public var inputSchemaJSON: String
    public var hints: MCPToolHints

    public init(name: String, summary: String, inputSchemaJSON: String, hints: MCPToolHints) {
        self.name = name
        self.summary = summary
        self.inputSchemaJSON = inputSchemaJSON
        self.hints = hints
    }
}

/// Text parts of a `tools/call` result. Image and audio bytes are not copied into the journal.
public struct MCPToolOutput: Sendable, Equatable {
    public var texts: [String]
    public var isError: Bool

    public init(texts: [String], isError: Bool) {
        self.texts = texts
        self.isError = isError
    }

    public var journaled: JSONValue {
        .object([
            "content": .array(texts.map { text in
                .object([
                    "text": .string(text),
                    "type": .string("text"),
                ])
            }),
            "isError": .bool(isError),
        ])
    }
}

public protocol MCPToolCaller: Sendable {
    func callTool(name: String, arguments: JSONValue) async throws -> MCPToolOutput
}
