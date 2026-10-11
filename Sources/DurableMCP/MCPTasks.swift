import DurableCore
import Foundation

/// A server-side task the client is waiting on, keyed by the engine effect that started it.
///
/// The record is written before the first poll. After a crash, the tool's reconcile hook reads it
/// and polls the same task instead of calling the tool again.
public struct MCPTaskRecord: Codable, Sendable, Equatable {
    public var effectKey: String
    public var server: String
    public var tool: String
    public var taskID: String
    public var createdAt: Date

    public init(effectKey: String, server: String, tool: String, taskID: String, createdAt: Date = Date()) {
        self.effectKey = effectKey
        self.server = server
        self.tool = tool
        self.taskID = taskID
        self.createdAt = createdAt
    }
}

/// Durable task ids for in-flight MCP calls.
///
/// A tool body cannot append to the event log while the engine holds its lock, so task ids go to
/// this side journal first. The final tool output also carries `taskId`, so the event log has it once
/// the call finishes.
public protocol MCPTaskJournal: Sendable {
    func record(_ entry: MCPTaskRecord) async throws
    func entry(effectKey: String) async throws -> MCPTaskRecord?
    func remove(effectKey: String) async throws
}

public actor InMemoryMCPTaskJournal: MCPTaskJournal {
    private var entries: [String: MCPTaskRecord] = [:]

    public init() {}

    public func record(_ entry: MCPTaskRecord) {
        entries[entry.effectKey] = entry
    }

    public func entry(effectKey: String) -> MCPTaskRecord? {
        entries[effectKey]
    }

    public func remove(effectKey: String) {
        entries.removeValue(forKey: effectKey)
    }

    public var all: [MCPTaskRecord] {
        entries.values.sorted { $0.effectKey < $1.effectKey }
    }
}

/// One JSON file, replaced atomically on each write. Holds task ids only, never arguments or results.
public actor FileMCPTaskJournal: MCPTaskJournal {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func record(_ entry: MCPTaskRecord) throws {
        var entries = try load()
        entries[entry.effectKey] = entry
        try save(entries)
    }

    public func entry(effectKey: String) throws -> MCPTaskRecord? {
        try load()[effectKey]
    }

    public func remove(effectKey: String) throws {
        var entries = try load()
        guard entries.removeValue(forKey: effectKey) != nil else { return }
        try save(entries)
    }

    private func load() throws -> [String: MCPTaskRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: MCPTaskRecord].self, from: data)
    }

    private func save(_ entries: [String: MCPTaskRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Task state from `tasks/get` (tasks extension v2).
public struct MCPTaskStatus: Sendable, Equatable {
    public enum State: String, Sendable {
        case working
        case inputRequired = "input_required"
        case completed
        case failed
        case cancelled
    }

    public var taskID: String
    public var state: State
    public var statusMessage: String?
    public var pollIntervalMs: Int?
    public var ttlMs: Int?
    /// On `completed`, what the original request would have returned.
    public var result: JSONValue?
    /// On `failed`, the JSON-RPC error object.
    public var error: JSONValue?
    /// On `input_required`, the server's input requests.
    public var inputRequests: [String: JSONValue]

    public var isTerminal: Bool {
        state == .completed || state == .failed || state == .cancelled
    }

    init?(_ json: JSONValue) {
        guard let id = json["taskId"]?.stringValue,
              let raw = json["status"]?.stringValue,
              let state = State(rawValue: raw)
        else {
            return nil
        }
        taskID = id
        self.state = state
        statusMessage = json["statusMessage"]?.stringValue
        pollIntervalMs = MCPWire.number(json["pollIntervalMs"]).map { Int($0) }
        ttlMs = MCPWire.number(json["ttlMs"]).map { Int($0) }
        result = json["result"]
        error = json["error"]
        inputRequests = json["inputRequests"]?.objectValue ?? [:]
    }
}

/// One server-to-client request carried in an `InputRequiredResult` or an `input_required` task.
public struct MCPInputRequest: Sendable, Equatable {
    /// The server-assigned key. The response goes back under the same key.
    public var key: String
    /// `elicitation/create`, `sampling/createMessage`, or `roots/list`.
    public var method: String
    public var params: JSONValue
    /// The server that asked. Server text is untrusted; show it as data, not as instructions.
    public var server: String

    public init(key: String, method: String, params: JSONValue, server: String) {
        self.key = key
        self.method = method
        self.params = params
        self.server = server
    }

    /// The prompt text of an elicitation.
    public var message: String? {
        params["message"]?.stringValue
    }

    /// `form` or `url` for an elicitation. Form is the default when the field is absent.
    public var elicitationMode: String? {
        guard method == "elicitation/create" else { return nil }
        return params["mode"]?.stringValue ?? "form"
    }
}

/// The person's answer to an elicitation.
public struct MCPElicitationAnswer: Sendable, Equatable {
    public enum Action: String, Sendable {
        case accept
        case decline
        case cancel
    }

    public var action: Action
    public var content: [String: JSONValue]?

    public init(action: Action, content: [String: JSONValue]? = nil) {
        self.action = action
        self.content = content
    }

    public static let decline = MCPElicitationAnswer(action: .decline)
    public static let cancel = MCPElicitationAnswer(action: .cancel)

    var json: JSONValue {
        var fields: [String: JSONValue] = ["action": .string(action.rawValue)]
        if action == .accept, let content {
            fields["content"] = .object(content)
        }
        return .object(fields)
    }
}

/// Answers a server's input requests. This is how elicitation reaches the person.
///
/// Return `nil` for a request the host cannot answer. Only elicitation is declared as a client
/// capability; sampling and roots are deprecated in 2026-07-28 and are not offered.
public protocol MCPInputHandler: Sendable {
    func answer(_ request: MCPInputRequest) async throws -> MCPElicitationAnswer?
}

/// Adapts a closure to `MCPInputHandler`.
public struct MCPElicitationHandler: MCPInputHandler {
    private let body: @Sendable (MCPInputRequest) async throws -> MCPElicitationAnswer?

    public init(_ body: @escaping @Sendable (MCPInputRequest) async throws -> MCPElicitationAnswer?) {
        self.body = body
    }

    public func answer(_ request: MCPInputRequest) async throws -> MCPElicitationAnswer? {
        try await body(request)
    }
}
