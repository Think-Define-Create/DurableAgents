import DurableCore
import Foundation

/// MCP memory-server tool names. The durable server installs these when a `MemoryIndex` is attached.
public enum MemoryMCP {
    public static let names = [
        "create_entities",
        "create_relations",
        "add_observations",
        "delete_entities",
        "delete_observations",
        "delete_relations",
        "read_graph",
        "search_nodes",
        "open_nodes",
    ]

    public static func handle(
        _ name: String,
        arguments: JSONValue,
        index: MemoryIndex,
        engine: Engine,
        store: any EventStore
    ) async throws -> JSONValue {
        switch name {
        case "create_entities":
            let drafts = (arguments["entities"]?.arrayValue ?? []).compactMap { entity -> EventDraft? in
                guard let title = entity["name"]?.stringValue, !title.isEmpty else { return nil }
                let observations = entity["observations"]?.arrayValue?.compactMap(\.stringValue) ?? []
                return MemoryIndex.entityDraft(
                    name: title,
                    type: entity["entityType"]?.stringValue ?? "thing",
                    observations: observations
                )
            }
            try await commit(drafts, engine: engine, index: index, store: store)
            return .object(["created": .int(Int64(drafts.count))])
        case "create_relations":
            let drafts = (arguments["relations"]?.arrayValue ?? []).compactMap { relation -> EventDraft? in
                guard let from = relation["from"]?.stringValue, let to = relation["to"]?.stringValue else { return nil }
                return MemoryIndex.edgeDraft(from: from, to: to, relation: relation["relationType"]?.stringValue ?? "related_to")
            }
            try await commit(drafts, engine: engine, index: index, store: store)
            return .object(["created": .int(Int64(drafts.count))])
        case "add_observations":
            let graph = try await index.readGraph()
            var drafts: [EventDraft] = []
            for item in arguments["observations"]?.arrayValue ?? [] {
                guard let title = item["entityName"]?.stringValue else { continue }
                let extra = item["contents"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let existing = graph.entities.first { $0.name == title }
                let merged = (existing?.observations ?? []) + extra
                drafts.append(MemoryIndex.entityDraft(name: title, type: existing?.type ?? "thing", observations: merged))
            }
            try await commit(drafts, engine: engine, index: index, store: store)
            return .object(["updated": .int(Int64(drafts.count))])
        case "delete_entities":
            let names = arguments["entityNames"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let drafts = names.map { MemoryIndex.tombstoneDraft(namespace: "memory.entity.gone", key: $0) }
            try await commit(drafts, engine: engine, index: index, store: store)
            return .object(["deleted": .int(Int64(names.count))])
        case "delete_relations":
            let drafts = (arguments["relations"]?.arrayValue ?? []).map { relation in
                let from = relation["from"]?.stringValue ?? ""
                let to = relation["to"]?.stringValue ?? ""
                let kind = relation["relationType"]?.stringValue ?? "related_to"
                return MemoryIndex.tombstoneDraft(namespace: "memory.edge.gone", key: "\(from)|\(kind)|\(to)")
            }
            try await commit(drafts, engine: engine, index: index, store: store)
            return .object(["deleted": .int(Int64(drafts.count))])
        case "delete_observations":
            let graph = try await index.readGraph()
            var drafts: [EventDraft] = []
            for item in arguments["deletions"]?.arrayValue ?? [] {
                guard let title = item["entityName"]?.stringValue,
                      var entity = graph.entities.first(where: { $0.name == title })
                else { continue }
                let drop = Set(item["observations"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                entity.observations.removeAll { drop.contains($0) }
                drafts.append(MemoryIndex.entityDraft(name: entity.name, type: entity.type, observations: entity.observations))
            }
            try await commit(drafts, engine: engine, index: index, store: store)
            return .object(["updated": .int(Int64(drafts.count))])
        case "read_graph":
            let graph = try await index.readGraph()
            return .object([
                "entities": .array(graph.entities.map { entity in
                    .object([
                        "name": .string(entity.name),
                        "entityType": .string(entity.type),
                        "observations": .array(entity.observations.map(JSONValue.string)),
                    ])
                }),
                "relations": .array(graph.edges.map { edge in
                    .object([
                        "from": .string(edge.from),
                        "to": .string(edge.to),
                        "relationType": .string(edge.relation),
                    ])
                }),
            ])
        case "search_nodes":
            let nodes = try await index.searchNodes(arguments["query"]?.stringValue ?? "")
            return .array(nodes.map { .object(["name": .string($0.name), "entityType": .string($0.type)]) })
        case "open_nodes":
            let names = arguments["names"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let nodes = try await index.openNodes(names)
            return .array(nodes.map { .object(["name": .string($0.name)]) })
        default:
            throw MemoryError.notANumber
        }
    }

    private static func commit(_ drafts: [EventDraft], engine: Engine, index: MemoryIndex, store: any EventStore) async throws {
        if !drafts.isEmpty {
            try await engine.record(drafts, stream: StreamID("memory"))
        }
        try await index.rebuild(from: store)
    }
}
