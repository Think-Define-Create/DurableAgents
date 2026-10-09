import Foundation

public enum SpanAttribute: Sendable, Equatable {
    case string(String)
    case int(Int)
}

public struct SpanHandle: Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// OpenTelemetry-style hook. Attributes must be ids and kinds, not message text or secrets.
public protocol RunTracing: Sendable {
    func begin(name: String, attributes: [String: SpanAttribute]) async -> SpanHandle
    func end(_ span: SpanHandle, attributes: [String: SpanAttribute]) async
}

public struct NoOpTracing: RunTracing {
    public init() {}

    public func begin(name: String, attributes: [String: SpanAttribute]) async -> SpanHandle {
        SpanHandle(id: "0", name: name)
    }

    public func end(_ span: SpanHandle, attributes: [String: SpanAttribute]) async {}
}

/// Drops attribute keys that look like message text or secrets, and redacts secret-shaped values.
public enum SpanScrub {
    private static let blocked = [
        "argument", "authorization", "apikey", "body", "content", "email",
        "message", "password", "payload", "prompt", "secret", "ssn", "text", "token",
    ]

    public static func scrub(_ attributes: [String: SpanAttribute]) -> [String: SpanAttribute] {
        var kept: [String: SpanAttribute] = [:]
        kept.reserveCapacity(attributes.count)
        for (key, value) in attributes {
            let folded = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
            if blocked.contains(where: { folded.contains($0) }) {
                continue
            }
            switch value {
            case .string(let raw):
                kept[key] = .string(redact(raw))
            case .int:
                kept[key] = value
            }
        }
        return kept
    }

    public static func render(_ value: SpanAttribute) -> String {
        switch value {
        case .string(let raw):
            return raw
        case .int(let raw):
            return String(raw)
        }
    }

    public static func redact(_ raw: String) -> String {
        let folded = raw.lowercased()
        if folded.contains("bearer ") || raw.contains("sk-") || folded.contains("x-api-key") {
            return "[redacted]"
        }
        if raw.contains("@"), raw.contains(".") {
            return "[redacted]"
        }
        return raw
    }
}

struct ScrubbingTracer: RunTracing {
    var inner: any RunTracing

    func begin(name: String, attributes: [String: SpanAttribute]) async -> SpanHandle {
        await inner.begin(name: name, attributes: SpanScrub.scrub(attributes))
    }

    func end(_ span: SpanHandle, attributes: [String: SpanAttribute]) async {
        await inner.end(span, attributes: SpanScrub.scrub(attributes))
    }
}

/// Tamper-evident chain over the stored envelopes, in global sequence order.
public enum EventHashChain {
    public static let genesis = "genesis"

    public static func link(_ event: EventEnvelope, previous: String) -> String {
        let line = [
            previous,
            String(event.globalSeq),
            event.stream.raw,
            String(event.streamSeq),
            event.type,
            String(event.schemaVersion),
            String(event.recordedAt.timeIntervalSince1970),
            event.payload.canonicalJSON(),
        ].joined(separator: "\n")
        return SHA256Hash.hex(line)
    }

    public static func tip(_ events: [EventEnvelope]) -> String {
        var previous = genesis
        for event in events.sorted(by: { $0.globalSeq < $1.globalSeq }) {
            previous = link(event, previous: previous)
        }
        return previous
    }

    public static func verify(_ events: [EventEnvelope], expectedTip: String) -> Bool {
        tip(events) == expectedTip
    }

    /// Sequence integrity of the log as stored. A matching tip is a separate check: deleting the tail keeps sequences contiguous and changes the tip.
    public static func inspect(_ events: [EventEnvelope]) -> ChainReport {
        let sorted = events.sorted { $0.globalSeq < $1.globalSeq }
        var problems: [String] = []
        var expectedGlobal: UInt64 = 1
        var streamSeq: [String: UInt64] = [:]
        var previous = genesis
        for event in sorted {
            if event.globalSeq != expectedGlobal {
                problems.append("global sequence \(event.globalSeq) does not follow \(expectedGlobal - 1)")
            }
            expectedGlobal = event.globalSeq &+ 1
            let expectedStream = (streamSeq[event.stream.raw] ?? 0) &+ 1
            if event.streamSeq != expectedStream {
                problems.append("stream \(event.stream.raw) sequence \(event.streamSeq) does not follow \(expectedStream - 1)")
            }
            streamSeq[event.stream.raw] = event.streamSeq
            previous = link(event, previous: previous)
        }
        return ChainReport(
            tip: previous,
            eventCount: sorted.count,
            intact: problems.isEmpty,
            problems: problems
        )
    }
}

public struct ChainReport: Sendable, Equatable {
    public var tip: String
    public var eventCount: Int
    public var intact: Bool
    public var problems: [String]

    public init(tip: String, eventCount: Int, intact: Bool, problems: [String]) {
        self.tip = tip
        self.eventCount = eventCount
        self.intact = intact
        self.problems = problems
    }
}

public struct AuditRow: Sendable, Equatable {
    public var globalSeq: UInt64
    public var recordedAt: Date
    public var type: String
    public var stream: String
    public var runID: String
    public var subject: String
    public var tool: String
    public var ok: String
    public var actor: String

    public init(
        globalSeq: UInt64,
        recordedAt: Date,
        type: String,
        stream: String,
        runID: String,
        subject: String,
        tool: String,
        ok: String,
        actor: String
    ) {
        self.globalSeq = globalSeq
        self.recordedAt = recordedAt
        self.type = type
        self.stream = stream
        self.runID = runID
        self.subject = subject
        self.tool = tool
        self.ok = ok
        self.actor = actor
    }
}

/// Exports intents, results, and approvals. Payloads other than those columns are omitted.
public enum AuditExport {
    public static let types: Set<String> = [
        EventType.effectIntent,
        EventType.effectResult,
        EventType.approvalRequested,
        EventType.approvalResolved,
    ]

    public static func rows(_ events: [EventEnvelope]) -> [AuditRow] {
        events.filter { types.contains($0.type) }.sorted { $0.globalSeq < $1.globalSeq }.map { event in
            AuditRow(
                globalSeq: event.globalSeq,
                recordedAt: event.recordedAt,
                type: event.type,
                stream: event.stream.raw,
                runID: event.payload["runID"]?.stringValue ?? "",
                subject: event.payload["callID"]?.stringValue ?? event.payload["approvalID"]?.stringValue ?? "",
                tool: event.payload["tool"]?.stringValue ?? "",
                ok: AuditExport.flag(event.payload["ok"]) ?? AuditExport.flag(event.payload["approved"]) ?? "",
                actor: event.payload["approver"]?.stringValue ?? ""
            )
        }
    }

    public static func jsonl(_ events: [EventEnvelope]) -> String {
        rows(events).map { row in
            let fields: [String: JSONValue] = [
                "actor": .string(row.actor),
                "globalSeq": .int(Int64(row.globalSeq)),
                "ok": .string(row.ok),
                "recordedAt": .string(iso(row.recordedAt)),
                "runID": .string(row.runID),
                "stream": .string(row.stream),
                "subject": .string(row.subject),
                "tool": .string(row.tool),
                "type": .string(row.type),
            ]
            return JSONValue.object(fields).canonicalJSON()
        }.joined(separator: "\n")
    }

    public static func csv(_ events: [EventEnvelope]) -> String {
        var lines = ["globalSeq,recordedAt,type,stream,runID,subject,tool,ok,actor"]
        for row in rows(events) {
            let columns = [
                String(row.globalSeq),
                iso(row.recordedAt),
                row.type,
                row.stream,
                row.runID,
                row.subject,
                row.tool,
                row.ok,
                row.actor,
            ].map(csvField)
            lines.append(columns.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func flag(_ value: JSONValue?) -> String? {
        guard let value, let bool = value.boolValue else { return nil }
        return bool ? "true" : "false"
    }

    private static func iso(_ date: Date) -> String {
        String(date.timeIntervalSince1970)
    }

    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
