import DurableCore
import DurableMemory
import Foundation
import MCP

/// Exposes one engine as an MCP server.
///
/// Tools: `start_run`, `send_message`, `get_run_status`, `list_pending_approvals`,
/// `approve`, `reject`, `export_audit`. When `memory` is set, the knowledge-graph tools
/// `create_entities`, `create_relations`, `add_observations`, `delete_entities`,
/// `delete_observations`, `delete_relations`, `read_graph`, `search_nodes`, and `open_nodes`
/// are installed as well.
///
/// `approve` and `reject` require `approverId` and `authLevel`. An empty approver allowlist
/// refuses every approval. The engine still checks that the auth level meets the approval.
/// Do not call this server from a tool on the same engine; that deadlocks the single-owner actor.
///
/// The server is dual-era. A request with 2026-07-28 `_meta`, or `server/discover`, is served
/// statelessly by this package. An `initialize` request is served by the SDK under 2025-11-25.
public actor DurableMCPServer {
    private static let instructions = "Drive a durable run. approve and reject require approverId and authLevel. An empty approver allowlist refuses every approval."
    private let operations: MCPServerOperations
    private let modern: MCPModernResponder
    private let server: Server
    private let http: StatelessHTTPServerTransport
    private var started = false

    public init(engine: Engine, store: any EventStore, approverIDs: Set<String>, memory: MemoryIndex? = nil) {
        operations = MCPServerOperations(engine: engine, store: store, approverIDs: approverIDs, memory: memory)
        modern = MCPModernResponder(operations: operations, instructions: Self.instructions)
        server = Server(
            name: "DurableAgents",
            version: "1.0.0",
            instructions: Self.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        http = StatelessHTTPServerTransport()
    }

    /// stdio on macOS and Linux. The caller keeps this task alive with `waitUntilCompleted` on a real process.
    public func startStdio() async throws {
        #if os(macOS) || os(Linux)
        try await start(transport: StdioTransport())
        #else
        throw MCPCallError("stdio mcp transport is unavailable on this platform")
        #endif
    }

    /// Streamable HTTP without sessions or SSE. `handleHTTP` answers one POST at a time.
    public func prepareHTTP() async throws {
        try await start(transport: http)
    }

    public func start(transport: any Transport) async throws {
        try await install()
        if started {
            throw MCPCallError("mcp server is already started")
        }
        try await server.start(transport: MCPDualEraTransport(inner: transport, responder: modern))
        started = true
    }

    /// Starts the server on an in-memory transport and returns a client connected to it.
    /// For in-app diagnostics and tests, where no process can be spawned and no port opened.
    public func loopbackClient() async throws -> MCPClientSession {
        let (client, server) = await InMemoryTransport.createConnectedPair()
        try await start(transport: server)
        return try await MCPClientSession.connected(client)
    }

    /// A 2026-07-28 client on an in-process channel. No SDK handshake, process, or port.
    public func modernLoopbackClient(inputHandler: (any MCPInputHandler)? = nil) async throws -> MCPClientSession {
        let connection = MCPModernConnection(
            channel: MCPInProcessChannel(responder: modern),
            server: "loopback",
            inputHandler: inputHandler,
            timeout: 30
        )
        try await connection.discover()
        return MCPClientSession(modern: connection, server: "loopback", timeoutSeconds: 30)
    }

    /// Dual-era Streamable HTTP with full-fidelity modern error bodies (`data.supported` and so on).
    public func respond(_ request: HTTPRequest) async -> MCPHTTPReply {
        if let message = modernMessage(request) {
            return await modern.respond(message, headers: request.headers)
        }
        let response = await http.handleRequest(request)
        switch response {
        case .stream(let stream, let headers):
            return MCPHTTPReply(status: response.statusCode, headers: headers, stream: stream)
        default:
            return MCPHTTPReply(status: response.statusCode, headers: response.headers, body: response.bodyData)
        }
    }

    /// Dual-era Streamable HTTP in the SDK's response type. A modern error keeps its code and
    /// message; `data` does not fit `HTTPResponse.error`, so use `respond` when that matters.
    public func handleHTTP(_ request: HTTPRequest) async -> HTTPResponse {
        guard let message = modernMessage(request) else {
            return await http.handleRequest(request)
        }
        let reply = await modern.respond(message, headers: request.headers)
        if reply.status == 202 {
            return .accepted()
        }
        if let stream = reply.stream {
            return .stream(stream, headers: reply.headers)
        }
        let body = reply.body ?? Data()
        if reply.status >= 400, let parsed = try? MCPWire.parse(body), let error = MCPRPCError(parsed["error"], httpStatus: reply.status) {
            return .error(statusCode: reply.status, .serverError(code: error.code, message: error.message))
        }
        return .data(body, headers: reply.headers)
    }

    public func stop() async {
        modern.closeSubscriptions()
        await server.stop()
        started = false
    }

    private func modernMessage(_ request: HTTPRequest) -> JSONValue? {
        guard request.method.uppercased() == "POST",
              let body = request.body,
              let message = try? MCPWire.parse(body),
              message["method"]?.stringValue != "initialize"
        else {
            return nil
        }
        if MCPModernResponder.isModern(message) {
            return message
        }
        if let version = request.header("MCP-Protocol-Version"), MCPProtocol.modernVersions.contains(version) {
            return message
        }
        return nil
    }

    private func install() async throws {
        let operations = self.operations
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: operations.definitions())
        }
        await server.withMethodHandler(CallTool.self) { params in
            await operations.call(params)
        }
    }
}

final class MCPServerOperations: Sendable {
    private let engine: Engine
    private let store: any EventStore
    private let approverIDs: Set<String>
    private let memory: MemoryIndex?

    init(engine: Engine, store: any EventStore, approverIDs: Set<String>, memory: MemoryIndex?) {
        self.engine = engine
        self.store = store
        self.approverIDs = approverIDs
        self.memory = memory
    }

    func definitions() -> [MCP.Tool] {
        [
            tool(
                "start_run",
                "Start a model-driven run. Arguments: requestId, text.",
                required: ["requestId", "text"],
                properties: [("requestId", "string"), ("text", "string")]
            ),
            tool(
                "send_message",
                "Append a turn to an existing conversation. Arguments: conversationId, requestId, text.",
                required: ["conversationId", "requestId", "text"],
                properties: [("conversationId", "string"), ("requestId", "string"), ("text", "string")]
            ),
            tool(
                "get_run_status",
                "Read one conversation. Argument: conversationId.",
                required: ["conversationId"],
                properties: [("conversationId", "string")]
            ),
            tool(
                "list_pending_approvals",
                "List runs that are suspended for approval.",
                required: [],
                properties: []
            ),
            tool(
                "approve",
                "Approve a suspended run. Requires approverId and authLevel. Optional output resumes a reconciliation.",
                required: ["conversationId", "approvalId", "approverId", "authLevel"],
                properties: [
                    ("conversationId", "string"),
                    ("approvalId", "string"),
                    ("approverId", "string"),
                    ("authLevel", "string"),
                    ("output", "object"),
                ]
            ),
            tool(
                "reject",
                "Reject a suspended run. Requires approverId and authLevel.",
                required: ["conversationId", "approvalId", "approverId", "authLevel"],
                properties: [
                    ("conversationId", "string"),
                    ("approvalId", "string"),
                    ("approverId", "string"),
                    ("authLevel", "string"),
                    ("reason", "string"),
                ]
            ),
            tool(
                "export_audit",
                "Export the audit JSONL. It omits message text and tool arguments.",
                required: [],
                properties: []
            ),
        ] + memoryTools()
    }

    private func memoryTools() -> [MCP.Tool] {
        guard memory != nil else { return [] }
        return MemoryMCP.names.map { name in
            tool(name, "Memory graph tool \(name).", required: [], properties: [])
        }
    }

    func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            switch params.name {
            case "start_run":
                let requestID = try required("requestId", params.arguments)
                let text = try required("text", params.arguments)
                let result = try await engine.submitTurn(text, requestID: requestID)
                return ok(statusJSON(result))
            case "send_message":
                let conversation = try required("conversationId", params.arguments)
                let requestID = try required("requestId", params.arguments)
                let text = try required("text", params.arguments)
                let result = try await engine.submitTurn(text, requestID: requestID, to: ConversationID(raw: conversation))
                return ok(statusJSON(result))
            case "get_run_status":
                let conversation = try required("conversationId", params.arguments)
                let snapshot = try await engine.snapshot(ConversationID(raw: conversation))
                return ok(snapshotJSON(snapshot))
            case "list_pending_approvals":
                let ids = try await engine.listConversations()
                var rows: [JSONValue] = []
                for id in ids {
                    let snapshot = try await engine.snapshot(id)
                    guard let token = snapshot.run?.resumeToken else { continue }
                    rows.append(.object([
                        "approvalId": .string(token.approvalID),
                        "conversationId": .string(id.raw),
                        "resumeToken": .string(token.raw),
                    ]))
                }
                return ok(["approvals": .array(rows)])
            case "approve":
                return try await resolve(params, approved: true)
            case "reject":
                return try await resolve(params, approved: false)
            case "export_audit":
                let events = try await store.readAll()
                return ok(["jsonl": .string(AuditExport.jsonl(events))])
            default:
                if MemoryMCP.names.contains(params.name), let memory {
                    let arguments = MCPJSON.json(.object(params.arguments ?? [:]))
                    let result = try await MemoryMCP.handle(params.name, arguments: arguments, index: memory, engine: engine, store: store)
                    return ok(["result": result])
                }
                return fail("unknown tool")
            }
        } catch let error as MCPCallError {
            return fail(error.message)
        } catch let error as DurableError {
            return fail(String(describing: error))
        } catch {
            return fail("mcp tool failed")
        }
    }

    private func resolve(_ params: CallTool.Parameters, approved: Bool) async throws -> CallTool.Result {
        let conversation = try required("conversationId", params.arguments)
        let approvalID = try required("approvalId", params.arguments)
        let approverID = try required("approverId", params.arguments)
        let auth = try required("authLevel", params.arguments)
        guard approverIDs.contains(approverID) else {
            return fail("approver is not allowed")
        }
        guard let level = AuthenticationLevel(rawValue: auth) else {
            return fail("unknown auth level")
        }
        let token = ResumeToken(conversationID: ConversationID(raw: conversation), approvalID: approvalID)
        let decision: ApprovalDecision
        if approved {
            if let output = params.arguments?["output"] {
                decision = .approvedWithOutput(MCPJSON.json(output))
            } else {
                decision = .approved
            }
        } else {
            let reason = params.arguments?["reason"]?.stringValue ?? "rejected"
            decision = .denied(reason)
        }
        let result = try await engine.resume(
            token: token,
            decision: decision,
            approver: Approver(id: approverID, authLevel: level)
        )
        return ok([
            "conversationId": .string(result.conversationID.raw),
            "failure": jsonString(result.failure),
            "finalText": jsonString(result.finalText),
            "resumeToken": jsonString(result.resumeToken?.raw),
            "runStatus": .string(result.runStatus.rawValue),
        ])
    }

    private func required(_ name: String, _ arguments: [String: Value]?) throws -> String {
        guard let value = arguments?[name]?.stringValue, !value.isEmpty else {
            throw MCPCallError("missing \(name)")
        }
        return value
    }

    private func statusJSON(_ result: SubmitResult) -> [String: JSONValue] {
        [
            "conversationId": .string(result.conversationID.raw),
            "duplicate": .bool(result.duplicate),
            "failure": jsonString(result.failure),
            "requestId": .string(result.requestID),
            "resumeToken": jsonString(result.resumeToken?.raw),
            "runStatus": result.runStatus.map { .string($0.rawValue) } ?? .null,
        ]
    }

    private func snapshotJSON(_ snapshot: ConversationSnapshot) -> [String: JSONValue] {
        [
            "conversationId": .string(snapshot.id.raw),
            "failure": jsonString(snapshot.run?.failure),
            "finalText": jsonString(snapshot.run?.finalText),
            "resumeToken": jsonString(snapshot.run?.resumeToken?.raw),
            "runStatus": snapshot.run.map { .string($0.status.rawValue) } ?? .null,
        ]
    }

    private func jsonString(_ value: String?) -> JSONValue {
        if let value {
            return .string(value)
        }
        return .null
    }

    private func ok(_ fields: [String: JSONValue]) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: JSONValue.object(fields).canonicalJSON(), annotations: nil, _meta: nil)],
            isError: false
        )
    }

    private func fail(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private func tool(
        _ name: String,
        _ description: String,
        required: [String],
        properties: [(String, String)]
    ) -> MCP.Tool {
        var fields: [String: Value] = [:]
        for (key, type) in properties {
            fields[key] = .object(["type": .string(type)])
        }
        let schema = Value.object([
            "properties": .object(fields),
            "required": .array(required.map { .string($0) }),
            "type": .string("object"),
        ])
        return MCP.Tool(
            name: name,
            description: description,
            inputSchema: schema,
            annotations: .init(readOnlyHint: name == "get_run_status" || name == "list_pending_approvals" || name == "export_audit")
        )
    }
}
