import DurableCore
import Foundation
import Logging
import MCP

/// One HTTP reply from the dual-era server. Carries a full JSON-RPC error body with `data`,
/// which the SDK's `HTTPResponse.error` cannot.
public struct MCPHTTPReply: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data?
    /// Set for `subscriptions/listen`: SSE bytes until the subscription ends.
    public var stream: AsyncThrowingStream<Data, Error>?

    public init(status: Int, headers: [String: String] = [:], body: Data? = nil, stream: AsyncThrowingStream<Data, Error>? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.stream = stream
    }
}

/// Answers 2026-07-28 requests for `DurableMCPServer`: `server/discover`, stateless `tools/list`
/// and `tools/call` with per-request `_meta`, header validation, and `subscriptions/listen`.
/// Legacy `initialize` traffic stays with the SDK server.
final class MCPModernResponder: Sendable {
    private let operations: MCPServerOperations
    private let instructions: String
    private let listeners = MCPListenerSet()

    init(operations: MCPServerOperations, instructions: String) {
        self.operations = operations
        self.instructions = instructions
    }

    /// True when the message uses the modern era: `server/discover`, or a protocol version in `_meta`.
    static func isModern(_ message: JSONValue) -> Bool {
        if message["method"]?.stringValue == "server/discover" {
            return true
        }
        return message["params"]?["_meta"]?[MCPProtocol.protocolVersionKey] != nil
    }

    /// One HTTP POST. `headers` are matched case-insensitively.
    func respond(_ message: JSONValue, headers: [String: String]) async -> MCPHTTPReply {
        let id = message["id"] ?? .null
        let method = message["method"]?.stringValue ?? ""
        if message["id"] == nil {
            return MCPHTTPReply(status: 202)
        }
        if let failure = validateHeaders(message, method: method, headers: headers) {
            return json(400, MCPWire.error(id: id, code: MCPProtocol.headerMismatch, message: failure))
        }
        if method == "subscriptions/listen" {
            if let refused = versionError(message, id: id) {
                return json(400, refused)
            }
            return MCPHTTPReply(
                status: 200,
                headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache", "X-Accel-Buffering": "no"],
                stream: listeners.open(id: id)
            )
        }
        let response = await handle(message)
        let status: Int
        switch response["error"]?["code"]?.intValue.map(Int.init) {
        case MCPProtocol.headerMismatch, MCPProtocol.unsupportedProtocolVersion, MCPProtocol.missingRequiredClientCapability:
            status = 400
        case MCPProtocol.methodNotFound:
            status = 404
        default:
            status = 200
        }
        return json(status, response)
    }

    /// One JSON-RPC request without a transport. Used for stdio and in-process channels.
    func handle(_ message: JSONValue) async -> JSONValue {
        let id = message["id"] ?? .null
        let method = message["method"]?.stringValue ?? ""
        let params = message["params"] ?? .object([:])
        if let refused = versionError(message, id: id) {
            return refused
        }
        switch method {
        case "server/discover":
            return MCPWire.result(id: id, [
                "_meta": serverMeta,
                "cacheScope": .string("public"),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "instructions": .string(instructions),
                "supportedVersions": .array((MCPProtocol.modernVersions + [MCPProtocol.legacy]).map { .string($0) }),
                "ttlMs": .int(300_000),
            ])
        case "tools/list":
            let tools = operations.definitions().map { MCPClientSession.json($0) }
            return MCPWire.result(id: id, [
                "_meta": serverMeta,
                "cacheScope": .string("public"),
                "tools": .array(tools),
                "ttlMs": .int(300_000),
            ])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return MCPWire.error(id: id, code: MCPProtocol.invalidParams, message: "tools/call needs a name")
            }
            let arguments = params["arguments"]?.objectValue?.mapValues(MCPJSON.value)
            let result = await operations.call(CallTool.Parameters(name: name, arguments: arguments))
            var fields = MCPClientSession.json(result).objectValue ?? [:]
            fields["_meta"] = serverMeta
            return MCPWire.result(id: id, fields)
        default:
            return MCPWire.error(id: id, code: MCPProtocol.methodNotFound, message: "Method not found")
        }
    }

    /// Ends every open subscription with the graceful-closure result.
    func closeSubscriptions() {
        listeners.closeAll()
    }

    private var serverMeta: JSONValue {
        .object([MCPProtocol.serverInfoKey: .object(["name": .string("DurableAgents"), "version": .string("1.0.0")])])
    }

    private func versionError(_ message: JSONValue, id: JSONValue) -> JSONValue? {
        let requested = message["params"]?["_meta"]?[MCPProtocol.protocolVersionKey]?.stringValue
        if let requested, MCPProtocol.modernVersions.contains(requested) {
            return nil
        }
        return MCPWire.error(
            id: id,
            code: MCPProtocol.unsupportedProtocolVersion,
            message: "Unsupported protocol version",
            data: .object([
                "requested": .string(requested ?? ""),
                "supported": .array((MCPProtocol.modernVersions + [MCPProtocol.legacy]).map { .string($0) }),
            ])
        )
    }

    private func validateHeaders(_ message: JSONValue, method: String, headers: [String: String]) -> String? {
        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
        let bodyVersion = message["params"]?["_meta"]?[MCPProtocol.protocolVersionKey]?.stringValue
        guard let version = header("MCP-Protocol-Version") else {
            return "Header mismatch: MCP-Protocol-Version is missing"
        }
        if let bodyVersion, bodyVersion != version {
            return "Header mismatch: MCP-Protocol-Version does not match the body"
        }
        guard header("Mcp-Method") == method else {
            return "Header mismatch: Mcp-Method does not match the body"
        }
        if ["tools/call", "resources/read", "prompts/get"].contains(method) {
            let params = message["params"]
            let bodyName = params?["name"]?.stringValue ?? params?["uri"]?.stringValue
            guard let raw = header("Mcp-Name"), let decoded = MCPWire.decodeHeader(raw), decoded == bodyName else {
                return "Header mismatch: Mcp-Name does not match the body"
            }
        }
        return nil
    }

    private func json(_ status: Int, _ body: JSONValue) -> MCPHTTPReply {
        MCPHTTPReply(status: status, headers: ["Content-Type": "application/json"], body: MCPWire.data(body))
    }
}

/// Open `subscriptions/listen` streams. This server's tool list does not change, so each stream
/// carries the acknowledgment and then stays quiet until the server stops.
final class MCPListenerSet: @unchecked Sendable {
    private let lock = NSLock()
    private var open: [String: (JSONValue, AsyncThrowingStream<Data, Error>.Continuation)] = [:]

    func open(id: JSONValue) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let key = id.canonicalJSON()
        let ack = MCPWire.notification(method: "notifications/subscriptions/acknowledged", params: [
            "_meta": .object([MCPProtocol.subscriptionIDKey: id]),
            "notifications": .object([:]),
        ])
        continuation.yield(Self.event(ack))
        lock.withLock { open[key] = (id, continuation) }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.open.removeValue(forKey: key) }
        }
        return stream
    }

    func closeAll() {
        let streams = lock.withLock {
            let taken = open
            open = [:]
            return taken
        }
        for (_, (id, continuation)) in streams {
            let closing = MCPWire.result(id: id, ["_meta": .object([MCPProtocol.subscriptionIDKey: id])])
            continuation.yield(Self.event(closing))
            continuation.finish()
        }
    }

    static func event(_ message: JSONValue) -> Data {
        Data(("data: " + message.canonicalJSON() + "\n\n").utf8)
    }
}

/// Wraps an SDK transport so one stdio process serves both eras: modern requests are answered here,
/// everything else reaches the SDK server, which still answers `initialize`.
actor MCPDualEraTransport: Transport {
    nonisolated let logger: Logger
    private let inner: any Transport
    private let responder: MCPModernResponder

    init(inner: any Transport, responder: MCPModernResponder) {
        self.inner = inner
        self.responder = responder
        self.logger = Logger(label: "durableagents.mcp.dual-era")
    }

    func connect() async throws {
        try await inner.connect()
    }

    func disconnect() async {
        await inner.disconnect()
    }

    func send(_ data: Data) async throws {
        try await inner.send(data)
    }

    nonisolated func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        let task = Task {
            do {
                let incoming = await inner.receive()
                for try await data in incoming {
                    guard let message = try? MCPWire.parse(data), MCPModernResponder.isModern(message) else {
                        continuation.yield(data)
                        continue
                    }
                    try await answer(message)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    private func answer(_ message: JSONValue) async throws {
        guard message["id"] != nil else { return }
        if message["method"]?.stringValue == "subscriptions/listen" {
            let id = message["id"] ?? .null
            let ack = MCPWire.notification(method: "notifications/subscriptions/acknowledged", params: [
                "_meta": .object([MCPProtocol.subscriptionIDKey: id]),
                "notifications": .object([:]),
            ])
            try await inner.send(MCPWire.data(ack))
            return
        }
        let response = await responder.handle(message)
        try await inner.send(MCPWire.data(response))
    }
}

/// In-process modern channel: requests go straight to a responder. No process, port, or URLSession.
struct MCPInProcessChannel: MCPChannel {
    let responder: MCPModernResponder

    func send(_ message: JSONValue, headers: [String: String], timeout: Double) async throws -> MCPReply {
        let reply = await responder.respond(message, headers: headers)
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        if let body = reply.body, let value = try? MCPWire.parse(body) {
            continuation.yield(value)
            continuation.finish()
        } else if let bytes = reply.stream {
            let pump = Task {
                var parser = MCPSSEParser()
                do {
                    for try await chunk in bytes {
                        for event in parser.feed(chunk) {
                            if let value = try? JSONValue.parse(event) {
                                continuation.yield(value)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
            }
        } else {
            continuation.finish()
        }
        return MCPReply(status: reply.status, messages: stream)
    }

    func close() async {}
}
