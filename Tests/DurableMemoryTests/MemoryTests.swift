import DurableCore
import DurableMemory
import DurableRetrieval
import DurableStore
import Foundation
import Testing

@Test func searchFindsARedactedFactAndForgetRemovesIt() async throws {
    let harness = try await open()
    let result = try await harness.engine.submit(Submission(
        requestID: "mem",
        text: "remember",
        script: Script(steps: [
            .tool(name: "memory.remember", callID: "m1", arguments: .object([
                "id": .string("tea"),
                "text": .string("Ada likes tea ada@example.com and sk-secretvalue"),
            ])),
            .tool(name: "memory.search", callID: "m2", arguments: .object(["query": .string("tea")])),
            .tool(name: "memory.forget", callID: "m3", arguments: .object(["id": .string("tea")])),
            .tool(name: "memory.search", callID: "m4", arguments: .object(["query": .string("tea")])),
            .finish("done"),
        ])
    ))
    #expect(result.runStatus == .completed)
    let events = try await harness.engine.events(for: result.conversationID)
    let searches = events.filter { $0.type == EventType.effectResult && $0.payload["callID"]?.stringValue == "m2" }
    let hit = try #require(searches.first?.payload["output"]?.arrayValue?.first)
    #expect(hit["text"]?.stringValue?.contains("tea") == true)
    #expect(hit["text"]?.stringValue?.contains("ada@example.com") == false)
    #expect(hit["text"]?.stringValue?.contains("sk-secretvalue") == false)
    let after = events.filter { $0.type == EventType.effectResult && $0.payload["callID"]?.stringValue == "m4" }
    #expect(after.first?.payload["output"]?.arrayValue?.isEmpty == true)
    await harness.engine.close()
}

@Test func aCrashBeforeTheMemoryWriteDoesNotDuplicateTheFact() async throws {
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let index = try MemoryIndex(path: tempDB(), embedder: HashEmbedder())
    let once = Once()
    let tool = Tool(name: "memory.remember", effect: .transactional, summary: "remember") { input, context in
        if await once.consume() { throw SimulatedProcessCrash() }
        return ToolReturn(
            output: .object(["text": .string("kept")]),
            writes: [StateWrite(
                namespace: "memory.item",
                key: "kept",
                value: .object([
                    "text": .string("kept"),
                    "kind": .string("fact"),
                    "conversationID": .string(context.conversationID.raw),
                    "importance": .double(0.5),
                ])
            )]
        )
    }
    let first = try await Engine(store: store, tools: [tool], clock: clock, leaseTTL: .seconds(3600))
    do {
        _ = try await first.submit(Submission(
            requestID: "crash",
            text: "remember",
            script: Script(steps: [
                .tool(name: "memory.remember", callID: "m1", arguments: .object(["text": .string("kept")])),
                .finish("done"),
            ])
        ))
        Issue.record("expected a crash")
    } catch is SimulatedProcessCrash {}
    await first.close()
    let second = try await Engine(store: store, tools: [tool], clock: clock, leaseTTL: .seconds(3600))
    let actions = try await second.recover()
    #expect(actions.first?.runStatus == .completed)
    try await index.rebuild(from: store)
    let items = try await index.items()
    #expect(items.map(\.id) == ["kept"])
    let writes = try await store.readAll().filter { $0.type == EventType.stateWrote && $0.payload["namespace"]?.stringValue == "memory.item" }
    #expect(writes.count == 1)
    await second.close()
}

@Test func graphSearchAndShredFollowTheLog() async throws {
    let harness = try await open()
    try await harness.engine.record([
        MemoryIndex.entityDraft(name: "Ada", type: "person", observations: ["likes tea"]),
        MemoryIndex.entityDraft(name: "Tea", type: "drink", observations: []),
        MemoryIndex.edgeDraft(from: "Ada", to: "Tea", relation: "likes"),
        MemoryIndex.rememberDraft(id: "note", text: "Ada drinks tea", kind: "episode", conversationID: "conv-a", importance: 0.1),
        MemoryIndex.rememberDraft(id: "keep", text: "other", kind: "fact", conversationID: "conv-b", importance: 0.9),
    ], stream: StreamID("memory"))
    try await harness.index.rebuild(from: harness.store)
    let nodes = try await harness.index.searchNodes("tea")
    #expect(nodes.map(\.name) == ["Ada", "Tea"])
    let opened = try await harness.index.openNodes(["Tea"])
    #expect(opened.map(\.name) == ["Tea"])
    let graph = try await harness.index.readGraph()
    #expect(graph.edges.map(\.relation) == ["likes"])
    try await harness.index.decay(importanceBelow: 0.2, engine: harness.engine, store: harness.store)
    #expect(try await harness.index.items().map(\.id) == ["keep"])
    try await harness.index.shred(conversationID: "conv-b", engine: harness.engine, store: harness.store)
    #expect(try await harness.index.items().isEmpty)
    await harness.engine.close()
}

@Test func memoryGraphToolsCreateSearchAndRead() async throws {
    let harness = try await open()
    let created = try await MemoryMCP.handle(
        "create_entities",
        arguments: .object([
            "entities": .array([
                .object([
                    "name": .string("Ada"),
                    "entityType": .string("person"),
                    "observations": .array([.string("likes tea")]),
                ]),
                .object([
                    "name": .string("Harbor"),
                    "entityType": .string("place"),
                    "observations": .array([]),
                ]),
            ]),
        ]),
        index: harness.index,
        engine: harness.engine,
        store: harness.store
    )
    #expect(created["created"]?.intValue == 2)
    _ = try await MemoryMCP.handle(
        "create_relations",
        arguments: .object([
            "relations": .array([
                .object([
                    "from": .string("Ada"),
                    "to": .string("Harbor"),
                    "relationType": .string("visits"),
                ]),
            ]),
        ]),
        index: harness.index,
        engine: harness.engine,
        store: harness.store
    )
    let nodes = try await MemoryMCP.handle(
        "search_nodes",
        arguments: .object(["query": .string("tea")]),
        index: harness.index,
        engine: harness.engine,
        store: harness.store
    )
    #expect(nodes.arrayValue?.compactMap { $0["name"]?.stringValue } == ["Ada"])
    let graph = try await MemoryMCP.handle(
        "read_graph",
        arguments: .object([:]),
        index: harness.index,
        engine: harness.engine,
        store: harness.store
    )
    #expect(graph["entities"]?.arrayValue?.count == 2)
    #expect(graph["relations"]?.arrayValue?.first?["relationType"]?.stringValue == "visits")
    let opened = try await MemoryMCP.handle(
        "open_nodes",
        arguments: .object(["names": .array([.string("Harbor")])]),
        index: harness.index,
        engine: harness.engine,
        store: harness.store
    )
    #expect(opened.arrayValue?.compactMap { $0["name"]?.stringValue } == ["Harbor"])
    await harness.engine.close()
}

private struct Harness {
    var store: InMemoryEventStore
    var clock: ManualClock
    var engine: Engine
    var index: MemoryIndex
}

private func open() async throws -> Harness {
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let index = try MemoryIndex(path: tempDB(), embedder: HashEmbedder())
    let engine = try await Engine(
        store: store,
        tools: index.tools(store: store),
        clock: clock,
        leaseTTL: .seconds(3600)
    )
    return Harness(store: store, clock: clock, engine: engine, index: index)
}

private func tempDB() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("memory-\(UUID().uuidString).sqlite")
        .path
}

private actor Once {
    private var armed = true
    func consume() -> Bool {
        if armed {
            armed = false
            return true
        }
        return false
    }
}
