import DurableCore
import Foundation

/// Protocol constants for MCP 2026-07-28 and the legacy fallback.
public enum MCPProtocol {
    /// The modern (stateless, per-request `_meta`) revision this package speaks natively.
    public static let modern = "2026-07-28"
    /// The legacy revision the official Swift SDK speaks with an `initialize` handshake.
    public static let legacy = "2025-11-25"
    /// Modern revisions this package can send and serve.
    public static let modernVersions = [modern]

    /// `_meta` keys defined by the spec.
    public static let protocolVersionKey = "io.modelcontextprotocol/protocolVersion"
    public static let clientInfoKey = "io.modelcontextprotocol/clientInfo"
    public static let clientCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    public static let serverInfoKey = "io.modelcontextprotocol/serverInfo"
    public static let subscriptionIDKey = "io.modelcontextprotocol/subscriptionId"
    /// The tasks extension identifier.
    public static let tasksExtension = "io.modelcontextprotocol/tasks"

    /// The spec has no idempotency field, so this key carries one under our own `_meta` prefix.
    /// It is derived from the effect key and is sent unchanged on every retry of the same call.
    public static let idempotencyKeyMeta = "dev.durableagents/idempotencyKey"

    /// JSON-RPC error codes from the 2026-07-28 allocation.
    public static let headerMismatch = -32020
    public static let missingRequiredClientCapability = -32021
    public static let unsupportedProtocolVersion = -32022
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let invalidRequest = -32600
    public static let internalError = -32603

    /// Codes that only a modern server returns. Anything else on a probe means a legacy server.
    static let modernErrorCodes: Set<Int> = [headerMismatch, missingRequiredClientCapability, unsupportedProtocolVersion]

    /// The idempotency key for one engine effect. Hashed so the store id in the effect key does not leave the device.
    public static func idempotencyKey(for effect: EffectKey) -> String {
        "dak-" + String(ContentSHA256.hex(effect.raw).prefix(40))
    }
}

/// Which MCP revision a server config asks for.
public enum MCPProtocolChoice: String, Codable, Sendable, Equatable, CaseIterable {
    /// Try 2026-07-28 first and fall back to the SDK's `initialize` handshake for an older server.
    case automatic
    /// Only 2026-07-28. A legacy server fails to connect.
    case modern = "2026-07-28"
    /// Only the SDK's 2025-11-25 handshake.
    case legacy = "2025-11-25"
}

/// A JSON-RPC error from the server. The message is not journaled; callers rethrow `MCPCallError`.
struct MCPRPCError: Error, Sendable {
    var code: Int
    var message: String
    var data: JSONValue?
    var httpStatus: Int?

    var isModern: Bool {
        MCPProtocol.modernErrorCodes.contains(code)
    }

    init(code: Int, message: String, data: JSONValue? = nil, httpStatus: Int? = nil) {
        self.code = code
        self.message = message
        self.data = data
        self.httpStatus = httpStatus
    }

    init?(_ error: JSONValue?, httpStatus: Int?) {
        guard let error, let code = error["code"]?.intValue else { return nil }
        self.init(
            code: Int(code),
            message: error["message"]?.stringValue ?? "",
            data: error["data"],
            httpStatus: httpStatus
        )
    }
}

/// The server could not be spoken to as a modern server. The client falls back to the SDK.
struct MCPLegacyServer: Error {}

enum MCPWire {
    static func parse(_ data: Data) throws -> JSONValue {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPCallError("mcp response is not utf-8")
        }
        do {
            return try JSONValue.parse(text)
        } catch {
            throw MCPCallError("mcp response is not json")
        }
    }

    static func data(_ value: JSONValue) -> Data {
        Data(value.canonicalJSON().utf8)
    }

    static func request(id: JSONValue, method: String, params: [String: JSONValue]) -> JSONValue {
        .object([
            "id": id,
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": .object(params),
        ])
    }

    static func notification(method: String, params: [String: JSONValue]) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": .object(params),
        ])
    }

    static func result(id: JSONValue, _ fields: [String: JSONValue]) -> JSONValue {
        var fields = fields
        if fields["resultType"] == nil {
            fields["resultType"] = .string("complete")
        }
        return .object([
            "id": id,
            "jsonrpc": .string("2.0"),
            "result": .object(fields),
        ])
    }

    static func error(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
        var error: [String: JSONValue] = [
            "code": .int(Int64(code)),
            "message": .string(message),
        ]
        if let data {
            error["data"] = data
        }
        return .object([
            "error": .object(error),
            "id": id,
            "jsonrpc": .string("2.0"),
        ])
    }

    /// `resultType`, treating an absent field as `complete` as the spec requires for older servers.
    static func resultType(_ result: JSONValue) -> String {
        result["resultType"]?.stringValue ?? "complete"
    }

    /// A header value, using the `=?base64?…?=` sentinel when the raw value is not safe plain ASCII.
    static func headerValue(_ raw: String) -> String {
        let safe = raw.unicodeScalars.allSatisfy { scalar in
            scalar == " " || scalar == "\t" || (scalar.value >= 0x21 && scalar.value <= 0x7E)
        }
        let padded = raw.first == " " || raw.first == "\t" || raw.last == " " || raw.last == "\t"
        let sentinel = raw.hasPrefix("=?base64?") && raw.hasSuffix("?=")
        if safe && !padded && !sentinel {
            return raw
        }
        return "=?base64?" + Data(raw.utf8).base64EncodedString() + "?="
    }

    /// Reverses `headerValue`.
    static func decodeHeader(_ value: String) -> String? {
        guard value.hasPrefix("=?base64?"), value.hasSuffix("?="), value.count >= 11 else {
            return value
        }
        let body = String(value.dropFirst(9).dropLast(2))
        guard let data = Data(base64Encoded: body) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let item):
            return Double(item)
        case .double(let item):
            return item
        default:
            return nil
        }
    }
}

/// Parses `text/event-stream` bytes into the `data` payload of each event.
struct MCPSSEParser {
    private var buffer = Data()
    private var dataLines: [String] = []

    /// Feeds bytes and returns the data payloads of events that finished in them.
    mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var events: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            let line = String(decoding: lineData, as: UTF8.self)
            if let event = take(line) {
                events.append(event)
            }
        }
        return events
    }

    /// Flushes an event that was not followed by a blank line before the stream ended.
    mutating func finish() -> String? {
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            if let event = take(line) {
                return event
            }
        }
        if dataLines.isEmpty {
            return nil
        }
        let event = dataLines.joined(separator: "\n")
        dataLines.removeAll()
        return event
    }

    private mutating func take(_ line: String) -> String? {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let event = dataLines.joined(separator: "\n")
            dataLines.removeAll()
            return event
        }
        if line.hasPrefix(":") {
            return nil
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") {
                value.removeFirst()
            }
            dataLines.append(value)
        }
        return nil
    }
}
