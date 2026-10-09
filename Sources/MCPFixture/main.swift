import Foundation
import MCP

@main
struct MCPFixture {
    static func main() async throws {
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
