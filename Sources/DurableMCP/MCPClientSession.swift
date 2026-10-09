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

/// One MCP client. Tool calls check cancellation, time out in the bridge, and open one new connection after `connectionClosed`.
public actor MCPClientSession: MCPToolCaller {
    private var client: Client
    private let redial: @Sendable () async throws -> Client
    private let shutdown: @Sendable () async -> Void

    init(client: Client, redial: @escaping @Sendable () async throws -> Client, shutdown: @escaping @Sendable () async -> Void) {
        self.client = client
        self.redial = redial
        self.shutdown = shutdown
    }

    public func listTools() async throws -> [MCPListedTool] {
        do {
            var cursor: String?
            var listed: [MCPListedTool] = []
            repeat {
                try Task.checkCancellation()
                let page = try await client.listTools(cursor: cursor)
                listed.append(contentsOf: page.tools.map(MCPJSON.listed))
                cursor = page.nextCursor
            } while cursor != nil
            return listed
        } catch is CancellationError {
            throw MCPCallError("mcp call cancelled")
        } catch is SimulatedProcessCrash {
            throw SimulatedProcessCrash()
        } catch let error as MCPCallError {
            throw error
        } catch {
            throw MCPCallError("mcp list failed")
        }
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> MCPToolOutput {
        try Task.checkCancellation()
        do {
            return try await perform(name: name, arguments: arguments)
        } catch let error as MCPError where MCPReconnect.shouldRetry(
            connectionClosed: isConnectionClosed(error),
            alreadyRetried: false
        ) {
            do {
                await client.disconnect()
                client = try await redial()
            } catch is SimulatedProcessCrash {
                throw SimulatedProcessCrash()
            } catch {
                throw MCPCallError("mcp reconnect failed")
            }
            do {
                return try await perform(name: name, arguments: arguments)
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

    public func close() async {
        await client.disconnect()
        await shutdown()
    }

    public static func connect(_ config: MCPServerConfig, secrets: any MCPSecretStore) async throws -> MCPClientSession {
        try config.validate()
        switch config.transport {
        case "stdio":
            #if os(macOS) || os(Linux)
            let extra = try await resolve(config.envSecrets, secrets: secrets)
            return try await stdio(
                command: config.command ?? "",
                arguments: config.args,
                extraEnvironment: extra
            )
            #else
            throw MCPCallError("stdio mcp transport is unavailable on this platform")
            #endif
        case "http":
            guard let raw = config.url, let endpoint = URL(string: raw), endpoint.scheme != nil else {
                throw MCPCallError("invalid mcp url")
            }
            let headers = try await resolve(config.headerSecrets, secrets: secrets)
            return try await http(endpoint: endpoint, headers: headers, timeoutSeconds: config.timeoutSeconds)
        default:
            throw MCPCallError("unknown mcp transport")
        }
    }

    public static func http(
        endpoint: URL,
        headers: [String: String],
        timeoutSeconds: Double = 30
    ) async throws -> MCPClientSession {
        let streaming = false
        let timeout = timeoutSeconds
        let headerFields = headers
        let redial: @Sendable () async throws -> Client = {
            let configuration = URLSessionConfiguration.ephemeral
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
        return MCPClientSession(client: client, redial: redial, shutdown: {})
    }

    /// In-process client. `redial` is a no-op connect on the same transport, which the SDK may refuse.
    public static func connected(_ transport: any Transport) async throws -> MCPClientSession {
        let redial: @Sendable () async throws -> Client = {
            try await Self.open(transport)
        }
        let client = try await redial()
        return MCPClientSession(client: client, redial: redial, shutdown: {})
    }

    private static func open(_ transport: any Transport) async throws -> Client {
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

    private func perform(name: String, arguments: JSONValue) async throws -> MCPToolOutput {
        let encoded = try MCPJSON.arguments(arguments)
        let result = try await client.callTool(name: name, arguments: encoded)
        return MCPToolOutput(texts: MCPJSON.texts(result.content), isError: result.isError ?? false)
    }

    private func isConnectionClosed(_ error: MCPError) -> Bool {
        if case .connectionClosed = error {
            return true
        }
        return false
    }

    private static func resolve(_ accounts: [String: String], secrets: any MCPSecretStore) async throws -> [String: String] {
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
        extraEnvironment: [String: String] = [:]
    ) async throws -> MCPClientSession {
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
            }
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
