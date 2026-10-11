import Foundation
import MCP

@main
struct MCPFixture {
    static func main() async throws {
        if CommandLine.arguments.contains("--modern") {
            ModernFixture.run()
            return
        }
        let server = Server(
            name: "mcp-fixture",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        let schema = Value.object([
            "properties": .object([
                "text": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("text")]),
            "type": .string("object"),
        ])
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [
                Tool(
                    name: "echo",
                    description: "Return the text. Does not return environment values.",
                    inputSchema: schema,
                    annotations: .init(readOnlyHint: true)
                ),
            ])
        }
        await server.withMethodHandler(CallTool.self) { params in
            guard params.name == "echo" else {
                return CallTool.Result(
                    content: [.text(text: "unknown tool", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
            let text = params.arguments?["text"]?.stringValue ?? ""
            let token = ProcessInfo.processInfo.environment["FIXTURE_TOKEN"]
            let flag = token == nil || token?.isEmpty == true ? "absent" : "present"
            return CallTool.Result(
                content: [.text(text: text + " " + flag, annotations: nil, _meta: nil)],
                isError: false
            )
        }
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}

/// A 2026-07-28-only stdio server: `server/discover`, `tools/list`, and `tools/call` with `_meta`.
/// It refuses `initialize`, the way a modern-only server does.
enum ModernFixture {
    static func run() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = message["id"]
            else {
                continue
            }
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            let meta = params["_meta"] as? [String: Any] ?? [:]
            let version = meta["io.modelcontextprotocol/protocolVersion"] as? String
            guard version == "2026-07-28" else {
                reply(["id": id, "jsonrpc": "2.0", "error": [
                    "code": -32022,
                    "message": "Unsupported protocol version",
                    "data": ["supported": ["2026-07-28"], "requested": version ?? ""],
                ]])
                continue
            }
            switch method {
            case "server/discover":
                reply(["id": id, "jsonrpc": "2.0", "result": [
                    "resultType": "complete",
                    "supportedVersions": ["2026-07-28"],
                    "capabilities": ["tools": [:]],
                    "ttlMs": 60000,
                    "cacheScope": "public",
                    "_meta": ["io.modelcontextprotocol/serverInfo": ["name": "mcp-fixture-modern", "version": "1.0.0"]],
                ]])
            case "tools/list":
                reply(["id": id, "jsonrpc": "2.0", "result": [
                    "resultType": "complete",
                    "ttlMs": 0,
                    "cacheScope": "public",
                    "tools": [[
                        "name": "echo",
                        "description": "Return the text and the idempotency key.",
                        "inputSchema": ["type": "object", "properties": ["text": ["type": "string"]]],
                        "annotations": ["readOnlyHint": true],
                    ]],
                ]])
            case "tools/call":
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let text = arguments["text"] as? String ?? ""
                let key = meta["dev.durableagents/idempotencyKey"] as? String ?? "none"
                reply(["id": id, "jsonrpc": "2.0", "result": [
                    "resultType": "complete",
                    "content": [["type": "text", "text": "\(text) modern key=\(key)"]],
                ]])
            default:
                reply(["id": id, "jsonrpc": "2.0", "error": ["code": -32601, "message": "Method not found"]])
            }
        }
    }

    private static func reply(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        print(text)
        fflush(stdout)
    }
}
