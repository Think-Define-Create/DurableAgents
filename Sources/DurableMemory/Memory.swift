import DurableCore
import DurableRetrieval
import Foundation
import GRDB

public enum MemoryRedaction {
    public static func redact(_ text: String) -> String {
        var output = text
        if let email = try? NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: [.caseInsensitive]) {
            output = email.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "[redacted-email]")
        }
        if let secret = try? NSRegularExpression(pattern: "sk-[A-Za-z0-9]+", options: []) {
            output = secret.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "[redacted-secret]")
        }
        return output
    }
}

public struct MemoryRecord: Sendable, Equatable {
    public var id: String
    public var kind: String
    public var text: String
    public var conversationID: String?
    public var importance: Double
    public var modelID: String
}

public struct MemoryEntity: Sendable, Equatable {
    public var name: String
    public var type: String
    public var observations: [String]
}

public struct MemoryEdge: Sendable, Equatable {
    public var from: String
    public var to: String
    public var relation: String
}

/// Derived GRDB graph. The event log is the source of truth. Rebuild drops the tables and folds the log again.
/// The sqlite file is not a second ciphertext. Put it in the same container as the encrypted event store.
public actor MemoryIndex {
    private let path: String
    private let embedder: any Embedder
    private let db: DatabaseQueue

    public init(path: String, embedder: any Embedder) throws {
        self.path = path
        self.embedder = embedder
        db = try DatabaseQueue(path: path)
        try db.write { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS memory_item (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    text TEXT NOT NULL,
                    conversation_id TEXT,
                    importance REAL NOT NULL,
                    model_id TEXT NOT NULL,
                    vector BLOB NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS memory_entity (
                    name TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    observations TEXT NOT NULL
                )
                """)
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS memory_edge (
                    id TEXT PRIMARY KEY,
                    from_name TEXT NOT NULL,
                    to_name TEXT NOT NULL,
                    relation TEXT NOT NULL
                )
                """)
            try database.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(item_id UNINDEXED, text)")
        }
    }

    public func rebuild(from store: any EventStore) async throws {
        let events = try await store.readAll()
        let embedder = self.embedder
        var items: [String: MemoryRecord] = [:]
        var vectors: [String: [Float]] = [:]
        var entities: [String: MemoryEntity] = [:]
        var edges: [String: MemoryEdge] = [:]
        var goneItems: Set<String> = []
        var goneEntities: Set<String> = []
        for event in events where event.type == EventType.stateWrote {
            let namespace = event.payload["namespace"]?.stringValue ?? ""
            let key = event.payload["key"]?.stringValue ?? ""
            let value = event.payload["value"] ?? .null
            switch namespace {
            case "memory.item":
                guard let text = value["text"]?.stringValue else { continue }
                let record = MemoryRecord(
                    id: key,
                    kind: value["kind"]?.stringValue ?? "fact",
                    text: text,
                    conversationID: value["conversationID"]?.stringValue,
                    importance: (try? jsonDouble(value["importance"])) ?? 0.5,
                    modelID: embedder.id
                )
                let vector = try await embedder.embed([text])
                items[key] = record
                vectors[key] = vector.first ?? []
                goneItems.remove(key)
            case "memory.tombstone":
                goneItems.insert(key)
            case "memory.entity":
                guard let name = value["name"]?.stringValue else { continue }
                let observations = value["observations"]?.arrayValue?.compactMap(\.stringValue) ?? []
                entities[name] = MemoryEntity(name: name, type: value["type"]?.stringValue ?? "thing", observations: observations)
                goneEntities.remove(name)
            case "memory.entity.gone":
                goneEntities.insert(key)
            case "memory.edge":
                guard let from = value["from"]?.stringValue, let to = value["to"]?.stringValue else { continue }
                edges[key] = MemoryEdge(from: from, to: to, relation: value["relation"]?.stringValue ?? "related_to")
            case "memory.edge.gone":
                edges.removeValue(forKey: key)
            default:
                break
            }
        }
        for id in goneItems { items.removeValue(forKey: id) }
        for name in goneEntities {
            entities.removeValue(forKey: name)
            edges = edges.filter { $0.value.from != name && $0.value.to != name }
        }
        let itemRows = items
        let vectorRows = vectors
        let entityRows = entities
        let edgeRows = edges
        try await db.write { database in
            try database.execute(sql: "DELETE FROM memory_item")
            try database.execute(sql: "DELETE FROM memory_entity")
            try database.execute(sql: "DELETE FROM memory_edge")
            try database.execute(sql: "DELETE FROM memory_fts")
            for (id, record) in itemRows {
                let vector = vectorRows[id] ?? []
                let blob = Self.blob(vector)
                try database.execute(
                    sql: "INSERT INTO memory_item (id, kind, text, conversation_id, importance, model_id, vector) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    arguments: [id, record.kind, record.text, record.conversationID, record.importance, record.modelID, blob]
                )
                try database.execute(
                    sql: "INSERT INTO memory_fts (item_id, text) VALUES (?, ?)",
                    arguments: [id, record.text]
                )
            }
            for entity in entityRows.values {
                let observations = entity.observations.joined(separator: "\n")
                try database.execute(
                    sql: "INSERT INTO memory_entity (name, type, observations) VALUES (?, ?, ?)",
                    arguments: [entity.name, entity.type, observations]
                )
            }
            for (id, edge) in edgeRows {
                try database.execute(
                    sql: "INSERT INTO memory_edge (id, from_name, to_name, relation) VALUES (?, ?, ?, ?)",
                    arguments: [id, edge.from, edge.to, edge.relation]
                )
            }
        }
    }

    public func search(_ query: String, limit: Int = 5) async throws -> [MemoryRecord] {
        let redacted = MemoryRedaction.redact(query)
        let queryVector = try await embedder.embed([redacted]).first ?? []
        return try await db.read { database in
            let fts = try Row.fetchAll(database, sql: """
                SELECT item_id FROM memory_fts WHERE memory_fts MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [Self.ftsQuery(redacted), limit])
            let lexical = fts.compactMap { $0["item_id"] as String? }
            var rows: [(String, [Float])] = []
            let all = try Row.fetchAll(database, sql: "SELECT id, vector FROM memory_item")
            for row in all {
                guard let id: String = row["id"], let blob: Data = row["vector"] else { continue }
                rows.append((id, Self.floats(blob)))
            }
            let vectors = BruteForceVectors(modelID: embedder.id, rows: Dictionary(uniqueKeysWithValues: rows))
            let nearest = vectors.nearest(queryVector, limit: limit).map(\.id)
            let fused = RetrievalMath.fuse([lexical, nearest]).prefix(limit)
            var found: [MemoryRecord] = []
            for hit in fused {
                if let record = try Self.record(database, id: hit.id) {
                    found.append(record)
                }
            }
            return found
        }
    }

    public func open(_ id: String) async throws -> MemoryRecord? {
        try await db.read { database in try Self.record(database, id: id) }
    }

    public func items() async throws -> [MemoryRecord] {
        try await db.read { database in
            let rows = try Row.fetchAll(database, sql: "SELECT id FROM memory_item ORDER BY id")
            return try rows.compactMap { row in
                guard let id: String = row["id"] else { return nil }
                return try Self.record(database, id: id)
            }
        }
    }

    public func readGraph() async throws -> (entities: [MemoryEntity], edges: [MemoryEdge]) {
        try await db.read { database in
            let entityRows = try Row.fetchAll(database, sql: "SELECT name, type, observations FROM memory_entity ORDER BY name")
            let entities = entityRows.map { row in
                MemoryEntity(
                    name: row["name"] as String? ?? "",
                    type: row["type"] as String? ?? "",
                    observations: (row["observations"] as String? ?? "").split(separator: "\n").map(String.init)
                )
            }
            let edgeRows = try Row.fetchAll(database, sql: "SELECT from_name, to_name, relation FROM memory_edge ORDER BY id")
            let edges = edgeRows.map { row in
                MemoryEdge(
                    from: row["from_name"] as String? ?? "",
                    to: row["to_name"] as String? ?? "",
                    relation: row["relation"] as String? ?? ""
                )
            }
            return (entities, edges)
        }
    }

    public func searchNodes(_ query: String) async throws -> [MemoryEntity] {
        let graph = try await readGraph()
        let needle = query.lowercased()
        return graph.entities.filter { entity in
            entity.name.lowercased().contains(needle)
                || entity.type.lowercased().contains(needle)
                || entity.observations.contains { $0.lowercased().contains(needle) }
        }
    }

    public func openNodes(_ names: [String]) async throws -> [MemoryEntity] {
        let wanted = Set(names)
        return try await readGraph().entities.filter { wanted.contains($0.name) }
    }

    public func shred(conversationID: String, engine: Engine, store: any EventStore) async throws {
        try await rebuild(from: store)
        let doomed = try await items().filter { $0.conversationID == conversationID }
        if doomed.isEmpty { return }
        try await engine.record(
            doomed.map { Self.tombstoneDraft(namespace: "memory.tombstone", key: $0.id) },
            stream: StreamID("memory")
        )
        try await rebuild(from: store)
    }

    public func decay(importanceBelow: Double, engine: Engine, store: any EventStore) async throws {
        try await rebuild(from: store)
        let doomed = try await items().filter { $0.importance < importanceBelow }
        if doomed.isEmpty { return }
        try await engine.record(
            doomed.map { Self.tombstoneDraft(namespace: "memory.tombstone", key: $0.id) },
            stream: StreamID("memory")
        )
        try await rebuild(from: store)
    }

    /// Tools for an agent. They do not call the engine. `memory.remember` is transactional.
    /// `memory.search` and `memory.open` are pure. Rebuild from the log before searching.
    public nonisolated func tools(store: any EventStore) -> [Tool] {
        let index = self
        return [
            Tool(
                name: "memory.remember",
                effect: .transactional,
                summary: "Remember a redacted fact. The write commits with the tool result.",
                parametersJSON: #"{"type":"object","properties":{"text":{"type":"string"},"kind":{"type":"string"},"id":{"type":"string"}},"required":["text"]}"#
            ) { input, context in
                let text = MemoryRedaction.redact(input["text"]?.stringValue ?? "")
                let id = input["id"]?.stringValue ?? context.callID.raw
                let value = JSONValue.object([
                    "text": .string(text),
                    "kind": .string(input["kind"]?.stringValue ?? "fact"),
                    "conversationID": .string(context.conversationID.raw),
                    "importance": .double(input["importance"].flatMap { try? jsonDouble($0) } ?? 0.5),
                ])
                return ToolReturn(output: value, writes: [StateWrite(namespace: "memory.item", key: id, value: value)])
            },
            Tool(
                name: "memory.search",
                effect: .pure,
                summary: "Search memory with full text and vectors.",
                parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#
            ) { input, _ in
                try await index.rebuild(from: store)
                let hits = try await index.search(input["query"]?.stringValue ?? "")
                return ToolReturn(output: .array(hits.map { record in
                    .object(["id": .string(record.id), "text": .string(record.text), "kind": .string(record.kind)])
                }))
            },
            Tool(
                name: "memory.open",
                effect: .pure,
                summary: "Open one memory item by id.",
                parametersJSON: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#
            ) { input, _ in
                try await index.rebuild(from: store)
                let id = input["id"]?.stringValue ?? ""
                guard let record = try await index.open(id) else {
                    return ToolReturn(output: .null)
                }
                return ToolReturn(output: .object(["id": .string(record.id), "text": .string(record.text)]))
            },
            Tool(
                name: "memory.forget",
                effect: .transactional,
                summary: "Forget one memory item.",
                parametersJSON: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#
            ) { input, _ in
                let id = input["id"]?.stringValue ?? ""
                return ToolReturn(
                    output: .object(["forgot": .string(id)]),
                    writes: [StateWrite(namespace: "memory.tombstone", key: id, value: .bool(true))]
                )
            },
        ]
    }

    public static func rememberDraft(id: String, text: String, kind: String, conversationID: String, importance: Double) -> EventDraft {
        let redacted = MemoryRedaction.redact(text)
        return EventDraft(
            type: EventType.stateWrote,
            payload: .object([
                "namespace": .string("memory.item"),
                "key": .string(id),
                "value": .object([
                    "text": .string(redacted),
                    "kind": .string(kind),
                    "conversationID": .string(conversationID),
                    "importance": .double(importance),
                ]),
            ])
        )
    }

    public static func entityDraft(name: String, type: String, observations: [String]) -> EventDraft {
        EventDraft(
            type: EventType.stateWrote,
            payload: .object([
                "namespace": .string("memory.entity"),
                "key": .string(name),
                "value": .object([
                    "name": .string(name),
                    "type": .string(type),
                    "observations": .array(observations.map(JSONValue.string)),
                ]),
            ])
        )
    }

    public static func edgeDraft(from: String, to: String, relation: String) -> EventDraft {
        let id = "\(from)|\(relation)|\(to)"
        return EventDraft(
            type: EventType.stateWrote,
            payload: .object([
                "namespace": .string("memory.edge"),
                "key": .string(id),
                "value": .object([
                    "from": .string(from),
                    "to": .string(to),
                    "relation": .string(relation),
                ]),
            ])
        )
    }

    public static func tombstoneDraft(namespace: String, key: String) -> EventDraft {
        EventDraft(
            type: EventType.stateWrote,
            payload: .object([
                "namespace": .string(namespace),
                "key": .string(key),
                "value": .bool(true),
            ])
        )
    }

    private static func record(_ database: Database, id: String) throws -> MemoryRecord? {
        guard let row = try Row.fetchOne(database, sql: "SELECT id, kind, text, conversation_id, importance, model_id FROM memory_item WHERE id = ?", arguments: [id]) else {
            return nil
        }
        return MemoryRecord(
            id: row["id"] as String? ?? "",
            kind: row["kind"] as String? ?? "",
            text: row["text"] as String? ?? "",
            conversationID: row["conversation_id"] as String?,
            importance: row["importance"] as Double? ?? 0,
            modelID: row["model_id"] as String? ?? ""
        )
    }

    private static func blob(_ vector: [Float]) -> Data {
        var copy = vector
        return Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size)
    }

    private static func floats(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        var vector = [Float](repeating: 0, count: count)
        _ = vector.withUnsafeMutableBytes { raw in
            data.copyBytes(to: raw)
        }
        return vector
    }

    private static func ftsQuery(_ text: String) -> String {
        let tokens = text.split { !$0.isLetter && !$0.isNumber }.map { "\"\($0)\"" }
        if tokens.isEmpty { return "\"\"" }
        return tokens.joined(separator: " OR ")
    }
}

private func jsonDouble(_ value: JSONValue?) throws -> Double {
    guard let value else { throw MemoryError.notANumber }
    switch value {
    case .double(let number):
        return number
    case .int(let number):
        return Double(number)
    default:
        throw MemoryError.notANumber
    }
}

public enum MemoryError: Error, Equatable {
    case notANumber
}
