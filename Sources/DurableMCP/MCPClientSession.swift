import DurableCore
import Foundation
import MCP

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS) || os(Linux)
#if canImport(System)
import System
#else
import SystemPackage
#endif
#endif

/// What this process can actually open.
public enum MCPPlatform {
    /// `Foundation.Process` stdio. Available on macOS and Linux, not on iOS.
    public static var stdioAvailable: Bool {
        #if os(macOS) || os(Linux)
        true
        #else
        false
        #endif
    }

    /// The MCP SDK compiles SSE only off Linux. DurableAgents still posts JSON and does not open an SSE stream.
    /// This flag is true on Apple, where that SDK code exists and was not executed in the Linux test run.
    public static var sseStreamingCompiled: Bool {
        #if os(Linux)
        false
        #else
        true
        #endif
    }
}

/// One MCP client. Speaks 2026-07-28 natively and falls back to the official SDK's 2025-11-25
/// handshake for an older server. Tool calls check cancellation, time out per request, and open one
/// new connection after a legacy `connectionClosed`.
public actor MCPClientSession: MCPToolCaller {
    private enum Backend {
        case modern(MCPModernConnection)
        case legacy(Client)
    }

    private var backend: Backend
    private let redial: @Sendable () async throws -> Client
    private let shutdown: @Sendable () async -> Void
    private let timeoutSeconds: Double
    private let serverName: String
    private var legacyDescription: MCPServerDescription?

    init(client: Client, redial: @escaping @Sendable () async throws -> Client, shutdown: @escaping @Sendable () async -> Void) {
        self.backend = .legacy(client)
        self.redial = redial
        self.shutdown = shutdown
        self.timeoutSeconds = 30
        self.serverName = ""
    }

    init(modern: MCPModernConnection, server: String, timeoutSeconds: Double) {
        self.backend = .modern(modern)
        self.redial = { throw MCPCallError("mcp reconnect failed") }
        self.shutdown = {}
        self.timeoutSeconds = timeoutSeconds
        self.serverName = server
    }

    /// On a modern server the session times out each request itself, so a task-backed call can
    /// outlive one request. The bridge then does not cap the whole call.
    public var timesOutPerRequest: Bool {
        if case .modern = backend {
            return true
        }
        return false
    }

    /// The negotiated revision: `2026-07-28` for a modern server, otherwise the SDK's legacy revision.
    public var protocolVersion: String {
        get async {
            switch backend {
            case .modern(let connection):
                return await connection.protocolVersion
            case .legacy:
                return MCPProtocol.legacy
            }
        }
    }

    /// The server's identity, versions, and capabilities.
    public func describe() async throws -> MCPServerDescription {
        switch backend {
        case .modern(let connection):
            if let described = await connection.description {
                return described
            }
            return try await guarded { try await connection.discover() }
        case .legacy(let client):
            if let legacyDescription {
                return legacyDescription
            }
            let described = Self.describeLegacy(client)
            legacyDescription = described
            return described
        }
    }

    public func listTools() async throws -> [MCPListedTool] {
        try await guarded {
            switch backend {
            case .modern(let connection):
                return try await connection.listTools()
            case .legacy(let client):
                var cursor: String?
                var listed: [MCPListedTool] = []
                repeat {
                    try Task.checkCancellation()
                    let page = try await client.listTools(cursor: cursor)
                    listed.append(contentsOf: page.tools.map(MCPJSON.listed))
                    cursor = page.nextCursor
                } while cursor != nil
                return listed
            }
        } failure: { "mcp list failed" }
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> MCPToolOutput {
        try await callTool(name: name, arguments: arguments, context: MCPCallContext(server: serverName))
    }

    /// Calls a remote tool with the effect's idempotency key. On a modern server a task result is
    /// polled to its end, and its id is journaled first so a crash resumes polling.
    public func callTool(name: String, arguments: JSONValue, context: MCPCallContext) async throws -> MCPToolOutput {
        try Task.checkCancellation()
        switch backend {
        case .modern(let connection):
            return try await guarded {
                let (output, taskID) = try await connection.callTool(name: name, arguments: arguments, context: context)
                guard let taskID else { return output }
                return MCPToolOutput(texts: output.texts, isError: output.isError, taskID: taskID)
            } failure: { "mcp call failed" }
        case .legacy:
            return try await legacyCall(name: name, arguments: arguments, context: context)
        }
    }

    /// Polls a journaled server task after a crash. Throws `MCPTaskNeedsInput` when it waits on a person.
    public func resumeTask(_ record: MCPTaskRecord, context: MCPCallContext) async throws -> MCPToolOutput {
        guard case .modern(let connection) = backend else {
            throw MCPCallError("mcp tasks need a 2026-07-28 server")
        }
        return try await guarded {
            let output = try await connection.finishTask(record.taskID, context: context)
            return MCPToolOutput(texts: output.texts, isError: output.isError, taskID: record.taskID)
        } failure: { "mcp task failed" }
    }

    public func taskStatus(_ taskID: String) async throws -> MCPTaskStatus {
        let connection = try modern("mcp tasks need a 2026-07-28 server")
        return try await guarded { try await connection.getTask(taskID) } failure: { "mcp task failed" }
    }

    /// Cooperative cancel. The server may still finish the task.
    public func cancelTask(_ taskID: String) async throws {
        let connection = try modern("mcp tasks need a 2026-07-28 server")
        try await guarded { try await connection.cancelTask(taskID) } failure: { "mcp task cancel failed" }
    }

    public func listResources() async throws -> [MCPResource] {
        try await guarded {
            switch backend {
            case .modern(let connection):
                return try await connection.listResources()
            case .legacy(let client):
                var cursor: String?
                var items: [MCPResource] = []
                repeat {
                    let page = try await client.listResources(cursor: cursor)
                    items.append(contentsOf: page.resources.compactMap { MCPResource(Self.json($0)) })
                    cursor = page.nextCursor
                } while cursor != nil
                return items
            }
        } failure: { "mcp list failed" }
    }

    public func listResourceTemplates() async throws -> [MCPResourceTemplate] {
        try await guarded {
            switch backend {
            case .modern(let connection):
                return try await connection.listResourceTemplates()
            case .legacy(let client):
                var cursor: String?
                var items: [MCPResourceTemplate] = []
                repeat {
                    let page = try await client.listResourceTemplates(cursor: cursor)
                    items.append(contentsOf: page.templates.compactMap { MCPResourceTemplate(Self.json($0)) })
                    cursor = page.nextCursor
                } while cursor != nil
                return items
            }
        } failure: { "mcp list failed" }
    }

    public func readResource(uri: String) async throws -> [MCPResourceContent] {
        try await guarded {
            switch backend {
            case .modern(let connection):
                return try await connection.readResource(uri: uri)
            case .legacy(let client):
                return try await client.readResource(uri: uri).compactMap { MCPResourceContent(Self.json($0)) }
            }
        } failure: { "mcp read failed" }
    }

    public func listPrompts() async throws -> [MCPPrompt] {
        try await guarded {
            switch backend {
            case .modern(let connection):
                return try await connection.listPrompts()
            case .legacy(let client):
                var cursor: String?
                var items: [MCPPrompt] = []
                repeat {
                    let page = try await client.listPrompts(cursor: cursor)
                    items.append(contentsOf: page.prompts.compactMap { MCPPrompt(Self.json($0)) })
                    cursor = page.nextCursor
                } while cursor != nil
                return items
            }
        } failure: { "mcp list failed" }
    }

    public func getPrompt(name: String, arguments: [String: String] = [:]) async throws -> MCPPromptMessages {
        try await guarded {
            switch backend {
            case .modern(let connection):
                return try await connection.getPrompt(name: name, arguments: arguments)
            case .legacy(let client):
                let result = try await client.getPrompt(name: name, arguments: arguments.isEmpty ? nil : arguments)
                return MCPPromptMessages(.object([
                    "description": result.description.map { .string($0) } ?? .null,
                    "messages": Self.json(result.messages),
                ]))
            }
        } failure: { "mcp prompt failed" }
    }

    /// Opens a 2026-07-28 `subscriptions/listen` stream. Change events also invalidate cached lists.
    public func listen(_ filter: MCPSubscriptionFilter) async throws -> AsyncThrowingStream<MCPServerEvent, Error> {
        let connection = try modern("mcp subscriptions need a 2026-07-28 server")
        return try await guarded { try await connection.listen(filter) } failure: { "mcp subscription failed" }
    }

    public func close() async {
        switch backend {
        case .modern(let connection):
            await connection.close()
        case .legacy(let client):
            await client.disconnect()
        }
        await shutdown()
    }

    // MARK: Connecting

    /// Connects by config. `automatic` probes with `server/discover` and falls back to the SDK
    /// handshake when the server is legacy.
    public static func connect(
        _ config: MCPServerConfig,
        secrets: any MCPSecretStore,
        inputHandler: (any MCPInputHandler)? = nil,
        urlSessionConfiguration: URLSessionConfiguration? = nil
    ) async throws -> MCPClientSession {
        try config.validate()
        switch config.transport {
        case "stdio":
            #if os(macOS) || os(Linux)
            let extra = try await resolve(config.envSecrets, secrets: secrets)
            return try await stdio(
                command: config.command ?? "",
                arguments: config.args,
                extraEnvironment: extra,
                protocolChoice: config.protocolVersion,
                server: config.name,
                timeoutSeconds: config.timeoutSeconds,
                inputHandler: inputHandler
            )
            #else
            throw MCPCallError("stdio mcp transport is unavailable on this platform")
            #endif
        case "http":
            guard let raw = config.url, let endpoint = URL(string: raw), endpoint.scheme != nil else {
                throw MCPCallError("invalid mcp url")
            }
            let headers = try await resolve(config.headerSecrets, secrets: secrets)
            return try await http(
                endpoint: endpoint,
                headers: headers,
                timeoutSeconds: config.timeoutSeconds,
                protocolChoice: config.protocolVersion,
                server: config.name,
                inputHandler: inputHandler,
                urlSessionConfiguration: urlSessionConfiguration
            )
        default:
            throw MCPCallError("unknown mcp transport")
        }
    }

    public static func http(
        endpoint: URL,
        headers: [String: String],
        timeoutSeconds: Double = 30,
        protocolChoice: MCPProtocolChoice = .automatic,
        server: String = "",
        inputHandler: (any MCPInputHandler)? = nil,
        urlSessionConfiguration: URLSessionConfiguration? = nil
    ) async throws -> MCPClientSession {
        if protocolChoice != .legacy {
            let channel = MCPHTTPChannel(endpoint: endpoint, headers: headers, configuration: urlSessionConfiguration)
            let connection = MCPModernConnection(channel: channel, server: server, inputHandler: inputHandler, timeout: timeoutSeconds)
            do {
                try await connection.discover()
                return MCPClientSession(modern: connection, server: server, timeoutSeconds: timeoutSeconds)
            } catch is MCPLegacyServer {
                await connection.close()
                if protocolChoice == .modern {
                    throw MCPCallError("mcp server does not speak \(MCPProtocol.modern)")
                }
            } catch {
                await connection.close()
                throw error
            }
        }
        let streaming = false
        let timeout = timeoutSeconds
        let headerFields = headers
        let base = urlSessionConfiguration
        let redial: @Sendable () async throws -> Client = {
            let configuration = (base?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = max(timeout, 1)
            let transport = HTTPClientTransport(
                endpoint: endpoint,
                configuration: configuration,
                streaming: streaming,
                requestModifier: { request in
                    var copy = request
                    for (name, value) in headerFields {
                        copy.setValue(value, forHTTPHeaderField: name)
                    }
                    return copy
                }
            )
            return try await Self.open(transport)
        }
        let client = try await redial()
        return MCPClientSession(client: client, redial: redial, shutdown: {}, timeoutSeconds: timeoutSeconds, server: server)
    }

    /// In-process legacy client on an SDK transport. `redial` is a no-op connect on the same transport, which the SDK may refuse.
    public static func connected(_ transport: any Transport) async throws -> MCPClientSession {
        let redial: @Sendable () async throws -> Client = {
            try await Self.open(transport)
        }
        let client = try await redial()
        return MCPClientSession(client: client, redial: redial, shutdown: {})
    }

    init(
        client: Client,
        redial: @escaping @Sendable () async throws -> Client,
        shutdown: @escaping @Sendable () async -> Void,
        timeoutSeconds: Double,
        server: String
    ) {
        self.backend = .legacy(client)
        self.redial = redial
        self.shutdown = shutdown
        self.timeoutSeconds = timeoutSeconds
        self.serverName = server
    }

    static func open(_ transport: any Transport) async throws -> Client {
        let client = Client(name: "DurableAgents", version: "1.0.0")
        do {
            _ = try await client.connect(transport: transport)
        } catch is CancellationError {
            throw MCPCallError("mcp call cancelled")
        } catch {
            throw MCPCallError("mcp connect failed")
        }
        return client
    }

    // MARK: Internals

    private func legacyCall(name: String, arguments: JSONValue, context: MCPCallContext) async throws -> MCPToolOutput {
        do {
            return try await performLegacy(name: name, arguments: arguments, context: context)
        } catch let error as MCPError where MCPReconnect.shouldRetry(
            connectionClosed: isConnectionClosed(error),
            alreadyRetried: false
        ) {
            do {
                if case .legacy(let client) = backend {
                    await client.disconnect()
                }
                backend = .legacy(try await redial())
            } catch is SimulatedProcessCrash {
                throw SimulatedProcessCrash()
            } catch {
                throw MCPCallError("mcp reconnect failed")
            }
            do {
                // The retry sends the same idempotency key.
                return try await performLegacy(name: name, arguments: arguments, context: context)
            } catch is SimulatedProcessCrash {
                throw SimulatedProcessCrash()
            } catch {
                throw MCPCallError("mcp call failed")
            }
        } catch is SimulatedProcessCrash {
            throw SimulatedProcessCrash()
        } catch let error as MCPCallError {
            throw error
        } catch is CancellationError {
            throw MCPCallError("mcp call cancelled")
        } catch {
            throw MCPCallError("mcp call failed")
        }
    }

    private func performLegacy(name: String, arguments: JSONValue, context: MCPCallContext) async throws -> MCPToolOutput {
        guard case .legacy(let client) = backend else {
            throw MCPCallError("mcp call failed")
        }
        let encoded = try MCPJSON.arguments(arguments)
        var meta: Metadata?
        if let key = context.idempotencyKey {
            meta = Metadata(additionalFields: [MCPProtocol.idempotencyKeyMeta: .string(key)])
        }
        let result = try await client.callTool(name: name, arguments: encoded, meta: meta)
        return MCPToolOutput(texts: MCPJSON.texts(result.content), isError: result.isError ?? false)
    }

    private func modern(_ message: String) throws -> MCPModernConnection {
        guard case .modern(let connection) = backend else {
            throw MCPCallError(message)
        }
        return connection
    }

    /// Maps every failure to a fixed sentence so a URL, token, or server text cannot reach the journal.
    private func guarded<T: Sendable>(
        _ body: () async throws -> T,
        failure: () -> String = { "mcp call failed" }
    ) async throws -> T {
        do {
            return try await body()
        } catch is SimulatedProcessCrash {
            throw SimulatedProcessCrash()
        } catch let error as MCPCallError {
            throw error
        } catch let error as MCPTaskNeedsInput {
            throw error
        } catch is CancellationError {
            throw MCPCallError("mcp call cancelled")
        } catch let error as MCPRPCError {
            throw MCPCallError("\(failure()) (\(error.code))")
        } catch {
            throw MCPCallError(failure())
        }
    }

    private func isConnectionClosed(_ error: MCPError) -> Bool {
        if case .connectionClosed = error {
            return true
        }
        return false
    }

    private static func describeLegacy(_ client: Client) -> MCPServerDescription {
        MCPServerDescription(
            era: .legacy,
            protocolVersion: MCPProtocol.legacy,
            supportedVersions: [MCPProtocol.legacy],
            capabilities: .object([:])
        )
    }

    /// SDK values are Codable. Round-trip them into `JSONValue` so both eras share one parser.
    static func json<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8),
              let parsed = try? JSONValue.parse(text)
        else {
            return .null
        }
        return parsed
    }

    static func resolve(_ accounts: [String: String], secrets: any MCPSecretStore) async throws -> [String: String] {
        var resolved: [String: String] = [:]
        for (name, account) in accounts {
            let value: String?
            do {
                value = try await secrets.secret(account: account)
            } catch is SimulatedProcessCrash {
                throw SimulatedProcessCrash()
            } catch {
                throw MCPCallError("secret store unavailable")
            }
            guard let value, !value.isEmpty else {
                throw MCPCallError("missing secret account \(account)")
            }
            resolved[name] = value
        }
        return resolved
    }
}

#if os(macOS) || os(Linux)
extension MCPClientSession {
    public static func stdio(
        command: String,
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        protocolChoice: MCPProtocolChoice = .automatic,
        server: String = "",
        timeoutSeconds: Double = 30,
        inputHandler: (any MCPInputHandler)? = nil
    ) async throws -> MCPClientSession {
        if protocolChoice != .legacy {
            let channel = try MCPStdioChannel(command: command, arguments: arguments, environment: extraEnvironment)
            let connection = MCPModernConnection(channel: channel, server: server, inputHandler: inputHandler, timeout: timeoutSeconds)
            do {
                // A legacy server answers an unknown pre-initialize request with an error, or not at all.
                try await connection.discover(probeTimeout: min(max(timeoutSeconds, 0.5), 5))
                return MCPClientSession(modern: connection, server: server, timeoutSeconds: timeoutSeconds)
            } catch let error as MCPCallError where error.message == "mcp call timed out" {
                await connection.close()
                if protocolChoice == .modern {
                    throw MCPCallError("mcp server does not speak \(MCPProtocol.modern)")
                }
            } catch is MCPLegacyServer {
                // The legacy process saw a request before initialize. Start a clean one for the SDK.
                await connection.close()
                if protocolChoice == .modern {
                    throw MCPCallError("mcp server does not speak \(MCPProtocol.modern)")
                }
            } catch {
                await connection.close()
                throw error
            }
        }
        let box = MCPProcessBox()
        let redial: @Sendable () async throws -> Client = {
            box.stop()
            let pipes = try box.launch(command: command, arguments: arguments, extraEnvironment: extraEnvironment)
            let transport = StdioTransport(input: pipes.output, output: pipes.input)
            return try await Self.open(transport)
        }
        let client = try await redial()
        return MCPClientSession(
            client: client,
            redial: redial,
            shutdown: {
                box.stop()
            },
            timeoutSeconds: timeoutSeconds,
            server: server
        )
    }
}

private struct MCPPipeEnds: Sendable {
    var input: FileDescriptor
    var output: FileDescriptor
}

private final class MCPProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var pipes: [Pipe] = []
    private var drain: Task<Void, Never>?

    func launch(command: String, arguments: [String], extraEnvironment: [String: String]) throws -> MCPPipeEnds {
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for (name, value) in extraEnvironment {
            environment[name] = value
        }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw MCPCallError("mcp process failed to start")
        }
        lock.lock()
        self.process = process
        self.pipes = [input, output, errors]
        lock.unlock()
        drain = Task.detached {
            _ = errors.fileHandleForReading.readDataToEndOfFile()
        }
        return MCPPipeEnds(
            input: FileDescriptor(rawValue: input.fileHandleForWriting.fileDescriptor),
            output: FileDescriptor(rawValue: output.fileHandleForReading.fileDescriptor)
        )
    }

    func stop() {
        drain?.cancel()
        drain = nil
        lock.lock()
        let process = self.process
        self.process = nil
        self.pipes = []
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }
}
#endif
