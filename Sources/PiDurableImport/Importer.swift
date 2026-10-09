import DurableCore
import DurableStore
import Foundation
import GRDB

public struct ImportLoss: Sendable, Equatable {
    public var code: String
    public var detail: String

    public init(code: String, detail: String) {
        self.code = code
        self.detail = detail
    }
}

public struct ImportReport: Sendable, Equatable {
    public var conversations: Int
    public var entries: Int
    public var tasks: Int
    public var submissions: Int
    public var documents: Int
    public var eventsWritten: Int
    public var losses: [ImportLoss]

    public init(
        conversations: Int,
        entries: Int,
        tasks: Int,
        submissions: Int,
        documents: Int,
        eventsWritten: Int,
        losses: [ImportLoss]
    ) {
        self.conversations = conversations
        self.entries = entries
        self.tasks = tasks
        self.submissions = submissions
        self.documents = documents
        self.eventsWritten = eventsWritten
        self.losses = losses
    }

    public var text: String {
        var lines = [
            "conversations \(conversations)",
            "entries \(entries)",
            "tasks \(tasks)",
            "submissions \(submissions)",
            "documents \(documents)",
            "events \(eventsWritten)",
            "losses \(losses.count)",
        ]
        for loss in losses {
            lines.append("\(loss.code): \(loss.detail)")
        }
        return lines.joined(separator: "\n")
    }
}

public enum ImportError: Error, Sendable, Equatable, CustomStringConvertible {
    case schema(String)

    public var description: String {
        switch self {
        case .schema(let detail):
            return detail
        }
    }
}

/// One-way copy of a pi-durable SQLite file into a DurableAgents event log.
///
/// The source schema is `@earendil-works/pi-durable` version 1 (`packages/durable/src/storage/sqlite/migrations.ts`):
/// `durable_metadata`, `record_ids`, `conversations`, `entries`, `tasks`, `submissions`,
/// `documents`, `document_revisions`, plus the `durable_schema` version row.
public enum PiDurableImporter {
    public static let supportedSchemaVersion = 1
    public static let domainTables = [
        "durable_metadata",
        "record_ids",
        "conversations",
        "entries",
        "tasks",
        "submissions",
        "documents",
        "document_revisions",
    ]

    public static func importDatabase(source path: String, into store: any EventStore) async throws -> ImportReport {
        let snapshot = try load(path)
        let lease = try await store.acquireLease(
            owner: UUID(),
            pid: ProcessInfo.processInfo.processIdentifier,
            ttl: .seconds(120)
        )
        var written = 0
        do {
            for conversation in snapshot.conversations {
                let drafts = drafts(for: conversation, snapshot: snapshot)
                if drafts.isEmpty { continue }
                let committed = try await store.commit(
                    fence: lease.fence,
                    stream: .conversation(ConversationID(raw: streamID(conversation.id))),
                    events: drafts
                )
                written += committed.count
            }
            try await store.releaseLease(fence: lease.fence)
        } catch {
            try? await store.releaseLease(fence: lease.fence)
            throw error
        }
        return ImportReport(
            conversations: snapshot.conversations.count,
            entries: snapshot.entries.count,
            tasks: snapshot.tasks.count,
            submissions: snapshot.submissions.count,
            documents: snapshot.documents.count,
            eventsWritten: written,
            losses: snapshot.losses
        )
    }

    static func streamID(_ id: Int64) -> String { "pi:\(id)" }

    private static func load(_ path: String) throws -> SourceSnapshot {
        let database = try DatabaseQueue(path: path)
        return try database.read { db in
            try readSnapshot(db)
        }
    }

    /// Checkpoints and memos can hold provider headers. They stay out of the log.
    static func publicTaskRecord(_ record: JSONValue) -> JSONValue {
        guard var object = record.objectValue else { return .object([:]) }
        object.removeValue(forKey: "memos")
        if var state = object["state"]?.objectValue {
            state.removeValue(forKey: "checkpoint")
            object["state"] = .object(state)
        }
        return .object(object)
    }

    private static func drafts(for conversation: SourceConversation, snapshot: SourceSnapshot) -> [EventDraft] {
        var drafts: [EventDraft] = []
        var opened: [String: JSONValue] = [
            "conversationID": .string(streamID(conversation.id)),
            "source": .string("pi-durable"),
        ]
        if let owner = conversation.ownerConversationID {
            opened["forkedFrom"] = .string(streamID(owner))
        }
        if let ownerTask = conversation.ownerTaskID {
            opened["ownerTaskID"] = .string(String(ownerTask))
        }
        drafts.append(EventDraft(type: EventType.conversationOpened, payload: .object(opened)))

        let entries = snapshot.entries.filter { $0.conversationID == conversation.id }.sorted {
            if $0.commitSeq == $1.commitSeq { return $0.id < $1.id }
            return $0.commitSeq < $1.commitSeq
        }
        for entry in entries {
            drafts.append(contentsOf: entryDrafts(entry))
        }
        for task in snapshot.tasks where task.conversationID == conversation.id {
            drafts.append(note(
                subject: "task",
                fields: [
                    "taskID": .string(String(task.id)),
                    "kind": .string(task.kind),
                    "status": .string(task.status),
                    "record": Self.publicTaskRecord(task.record),
                ]
            ))
        }
        for submission in snapshot.submissions where submission.conversationID == conversation.id {
            var fields: [String: JSONValue] = [
                "submissionID": .string(String(submission.id)),
                "status": .string(submission.status),
            ]
            if let requestID = submission.requestID {
                fields["requestID"] = .string(requestID)
            }
            drafts.append(note(subject: "submission", fields: fields))
        }
        let firstID = snapshot.conversations.first?.id
        for document in snapshot.documents where document.include(in: conversation.id, first: firstID) {
            var fields: [String: JSONValue] = [
                "documentID": .string(String(document.id)),
                "kind": .string(document.kind),
                "key": .string(document.key),
            ]
            if let base = document.base {
                fields["base"] = base
            }
            drafts.append(note(subject: "document", fields: fields))
        }
        return drafts
    }

    private static func entryDrafts(_ entry: SourceEntry) -> [EventDraft] {
        let messageID = "pi:\(entry.id)"
        guard let record = entry.record.objectValue else {
            return [note(subject: "entry", fields: [
                "entryID": .string(String(entry.id)),
                "detail": .string("entry record was not an object"),
            ])]
        }
        let kind = record["kind"]?.stringValue ?? ""
        switch kind {
        case "pi.user":
            return [message(messageID, role: "user", text: text(from: record))]
        case "pi.assistant":
            var drafts = [message(messageID, role: "assistant", text: text(from: record))]
            for call in toolCalls(in: record) {
                drafts.append(note(subject: "toolCall", fields: [
                    "entryID": .string(String(entry.id)),
                    "callID": .string(call.id),
                    "tool": .string(call.name),
                    "arguments": call.arguments,
                ]))
            }
            return drafts
        case "pi.tool-result":
            let model = firstMessage(in: record)
            return [
                message(messageID, role: "tool", text: text(from: record), callID: model?["toolCallId"]?.stringValue),
                note(subject: "toolResult", fields: [
                    "entryID": .string(String(entry.id)),
                    "callID": .string(model?["toolCallId"]?.stringValue ?? ""),
                    "tool": .string(model?["toolName"]?.stringValue ?? ""),
                    "isError": .bool(model?["isError"]?.boolValue ?? false),
                ]),
            ]
        case "pi.compaction":
            let through = record["head"]?.stringValue ?? record["head"]?.intValue.map(String.init) ?? String(entry.id)
            return [EventDraft(
                type: EventType.contextCompacted,
                payload: .object([
                    "summary": .string(text(from: record)),
                    "throughMessageID": .string(through.hasPrefix("pi:") ? through : "pi:\(through)"),
                    "source": .string("pi-durable"),
                ])
            )]
        case "pi.reset":
            return [
                message(messageID, role: "system", text: "Context reset."),
                note(subject: "reset", fields: ["entryID": .string(String(entry.id))]),
            ]
        case "pi.system":
            return [note(subject: "system", fields: [
                "entryID": .string(String(entry.id)),
                "detail": .string("positional system entry was not added to the prompt"),
            ])]
        default:
            return [
                message(messageID, role: "system", text: kind.isEmpty ? "Imported entry \(entry.id)." : kind),
                note(subject: "entry", fields: [
                    "entryID": .string(String(entry.id)),
                    "kind": .string(kind),
                ]),
            ]
        }
    }

    private static func message(_ id: String, role: String, text: String, callID: String? = nil) -> EventDraft {
        var payload: [String: JSONValue] = [
            "messageID": .string(id),
            "role": .string(role),
            "text": .string(text),
        ]
        if let callID {
            payload["callID"] = .string(callID)
        }
        return EventDraft(
            type: EventType.messageAppended,
            schemaVersion: EventType.messageAppendedCurrentVersion,
            payload: .object(payload)
        )
    }

    private static func note(subject: String, fields: [String: JSONValue]) -> EventDraft {
        var payload = fields
        payload["source"] = .string("pi-durable")
        payload["subject"] = .string(subject)
        return EventDraft(type: EventType.importNote, payload: .object(payload))
    }

    private static func firstMessage(in record: [String: JSONValue]) -> [String: JSONValue]? {
        record["model"]?.arrayValue?.first?.objectValue
    }

    private static func text(from record: [String: JSONValue]) -> String {
        guard let message = firstMessage(in: record) else { return "" }
        if let content = message["content"]?.stringValue {
            return content
        }
        guard let blocks = message["content"]?.arrayValue else { return "" }
        return blocks.compactMap { block -> String? in
            guard let fields = block.objectValue, fields["type"]?.stringValue == "text" else { return nil }
            return fields["text"]?.stringValue
        }.joined(separator: "\n")
    }

    private static func toolCalls(in record: [String: JSONValue]) -> [(id: String, name: String, arguments: JSONValue)] {
        guard let blocks = firstMessage(in: record)?["content"]?.arrayValue else { return [] }
        return blocks.compactMap { block in
            guard let fields = block.objectValue, fields["type"]?.stringValue == "toolCall" else { return nil }
            return (
                fields["id"]?.stringValue ?? "",
                fields["name"]?.stringValue ?? "",
                fields["arguments"] ?? .object([:])
            )
        }
    }
}

private struct SourceSnapshot: Sendable {
    var conversations: [SourceConversation]
    var entries: [SourceEntry]
    var tasks: [SourceTask]
    var submissions: [SourceSubmission]
    var documents: [SourceDocument]
    var losses: [ImportLoss]
}

private struct SourceConversation: Sendable {
    var id: Int64
    var ownerConversationID: Int64?
    var ownerTaskID: Int64?
}

private struct SourceEntry: Sendable {
    var id: Int64
    var conversationID: Int64
    var commitSeq: Int64
    var record: JSONValue
}

private struct SourceTask: Sendable {
    var id: Int64
    var conversationID: Int64
    var kind: String
    var status: String
    var record: JSONValue
}

private struct SourceSubmission: Sendable {
    var id: Int64
    var conversationID: Int64
    var requestID: String?
    var status: String
}

private struct SourceDocument: Sendable {
    var id: Int64
    var kind: String
    var key: String
    var scopeKind: String
    var ownerID: Int64
    var base: JSONValue?

    func include(in conversationID: Int64, first: Int64?) -> Bool {
        switch scopeKind {
        case "conversation":
            return ownerID == conversationID
        case "session", "task":
            return conversationID == first
        default:
            return false
        }
    }
}

private func readSnapshot(_ db: Database) throws -> SourceSnapshot {
    guard try tableExists(db, "durable_schema") else {
        throw ImportError.schema("missing durable_schema")
    }
    guard let version = try Int.fetchOne(db, sql: "SELECT version FROM durable_schema WHERE singleton = 1") else {
        throw ImportError.schema("durable_schema has no version row")
    }
    guard version == PiDurableImporter.supportedSchemaVersion else {
        throw ImportError.schema(
            "schema version \(version) is not supported (this importer reads version \(PiDurableImporter.supportedSchemaVersion))"
        )
    }
    for name in PiDurableImporter.domainTables {
        guard try tableExists(db, name) else {
            throw ImportError.schema("missing table \(name)")
        }
    }
    var losses: [ImportLoss] = [
        ImportLoss(
            code: "allocator",
            detail: "durable_metadata.next_id and record_ids are not imported"
        ),
        ImportLoss(
            code: "fork-pointer",
            detail: "a pi-durable fork sees the parent transcript by pointer; this copy records forkedFrom and does not duplicate those entries"
        ),
        ImportLoss(
            code: "effects",
            detail: "tool calls become import.note events, not effect.intent rows, so recovery will not rerun them"
        ),
    ]
    let names = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    let known = Set(PiDurableImporter.domainTables + ["durable_schema"])
    let extra = names.filter { !known.contains($0) && !$0.hasPrefix("sqlite_") }
    if !extra.isEmpty {
        losses.append(ImportLoss(code: "extra-tables", detail: extra.joined(separator: ", ")))
    }

    let conversations = try Row.fetchAll(db, sql: """
        SELECT id, owner_conversation_id, owner_task_id FROM conversations ORDER BY id
        """).map { row in
        SourceConversation(
            id: row["id"],
            ownerConversationID: row["owner_conversation_id"],
            ownerTaskID: row["owner_task_id"]
        )
    }
    var entries: [SourceEntry] = []
    for row in try Row.fetchAll(db, sql: "SELECT id, conversation_id, head, commit_seq, record FROM entries ORDER BY commit_seq, id") {
        let id: Int64 = row["id"]
        let raw: String = row["record"]
        let record = try JSONValue.parse(raw)
        if let model = record["model"]?.arrayValue {
            for message in model {
                if message["content"]?.arrayValue?.contains(where: { $0["type"]?.stringValue == "image" }) == true {
                    losses.append(ImportLoss(code: "image", detail: "entry \(id) image content was dropped"))
                }
                if message["content"]?.arrayValue?.contains(where: { $0["type"]?.stringValue == "thinking" }) == true {
                    losses.append(ImportLoss(code: "thinking", detail: "entry \(id) thinking blocks were not copied into the prompt"))
                }
            }
        }
        if record["edits"] != nil {
            losses.append(ImportLoss(code: "context-edit", detail: "entry \(id) context edits were not applied"))
        }
        entries.append(SourceEntry(
            id: id,
            conversationID: row["conversation_id"],
            commitSeq: row["commit_seq"],
            record: record
        ))
    }
    var tasks: [SourceTask] = []
    for row in try Row.fetchAll(db, sql: "SELECT id, conversation_id, kind, status, record FROM tasks ORDER BY id") {
        let id: Int64 = row["id"]
        let status: String = row["status"]
        let record = try JSONValue.parse(row["record"])
        if status != "terminal" {
            losses.append(ImportLoss(
                code: "live-task",
                detail: "task \(id) status \(status) was not resumed"
            ))
        }
        if record["memos"] != nil || record.objectValue?["state"]?["checkpoint"] != nil {
            losses.append(ImportLoss(code: "checkpoint", detail: "task \(id) checkpoint or memos were not imported"))
        }
        tasks.append(SourceTask(
            id: id,
            conversationID: row["conversation_id"],
            kind: row["kind"],
            status: status,
            record: record
        ))
    }
    let submissions = try Row.fetchAll(db, sql: "SELECT id, conversation_id, request_id, status FROM submissions ORDER BY id").map { row in
        SourceSubmission(
            id: row["id"],
            conversationID: row["conversation_id"],
            requestID: row["request_id"],
            status: row["status"]
        )
    }
    if !submissions.isEmpty {
        losses.append(ImportLoss(code: "inbox", detail: "submissions are notes, not a queued inbox"))
    }
    var documents: [SourceDocument] = []
    let documentRows = try Row.fetchAll(db, sql: """
        SELECT id, kind, key_value, scope_kind, owner_id FROM documents ORDER BY id
        """)
    for row in documentRows {
        let id: Int64 = row["id"]
        let revisions = try Row.fetchAll(
            db,
            sql: "SELECT seq, kind, content FROM document_revisions WHERE document_id = ? ORDER BY seq",
            arguments: [id]
        )
        var base: JSONValue?
        var sawDelta = false
        for revision in revisions {
            let kind: String = revision["kind"]
            let content: String = revision["content"]
            if kind == "delta" {
                sawDelta = true
                continue
            }
            if kind == "base" {
                base = (try? JSONValue.parse(content)) ?? .string(content)
            }
        }
        if sawDelta {
            losses.append(ImportLoss(code: "chord-delta", detail: "document \(id) deltas were not replayed"))
        }
        if base == nil {
            losses.append(ImportLoss(code: "missing-base", detail: "document \(id) has no base revision"))
        }
        let scopeKind: String = row["scope_kind"]
        if scopeKind == "task" {
            losses.append(ImportLoss(
                code: "task-document",
                detail: "document \(id) is task-scoped and was attached to the first conversation"
            ))
        }
        documents.append(SourceDocument(
            id: id,
            kind: row["kind"],
            key: row["key_value"],
            scopeKind: row["scope_kind"],
            ownerID: row["owner_id"],
            base: base
        ))
    }
    return SourceSnapshot(
        conversations: conversations,
        entries: entries,
        tasks: tasks,
        submissions: submissions,
        documents: documents,
        losses: losses
    )
}

private func tableExists(_ db: Database, _ name: String) throws -> Bool {
    try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
        arguments: [name]
    ) ?? 0 > 0
}
