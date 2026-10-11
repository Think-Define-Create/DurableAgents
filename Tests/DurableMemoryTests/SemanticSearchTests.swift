import DurableCore
import DurableMemory
import DurableRetrieval
import DurableStore
import Foundation
import Testing

@Test func searchRanksTheExactWordFirstAndACloseMeaningNext() async throws {
    let harness = try await openIndex(ConceptEmbedder(id: "concepts"))
    try await harness.engine.record([
        MemoryIndex.rememberDraft(id: "keys", text: "Car keys are in the drawer", kind: "fact", conversationID: "c", importance: 0.5),
        MemoryIndex.rememberDraft(id: "commute", text: "I drive an automobile to work", kind: "fact", conversationID: "c", importance: 0.5),
        MemoryIndex.rememberDraft(id: "tea", text: "Ada likes tea", kind: "fact", conversationID: "c", importance: 0.5),
    ], stream: StreamID("memory"))
    try await harness.index.rebuild(from: harness.store)
    let hits = try await harness.index.search("car", limit: 3).map(\.id)
    // "keys" matches the word and the meaning. "commute" matches only the meaning. "tea" matches neither.
    #expect(hits.prefix(2) == ["keys", "commute"])
    #expect(hits.last == "tea")
    await harness.engine.close()
}

@Test func aNewEmbedderReembedsTheIndexAndAnUnchangedOneDoesNot() async throws {
    let first = ConceptEmbedder(id: "concepts-a")
    let harness = try await openIndex(first)
    try await harness.engine.record([
        MemoryIndex.rememberDraft(id: "pet", text: "The puppy sleeps all day", kind: "fact", conversationID: "c", importance: 0.5),
        MemoryIndex.rememberDraft(id: "drink", text: "Ada likes tea", kind: "fact", conversationID: "c", importance: 0.5),
    ], stream: StreamID("memory"))
    try await harness.index.rebuild(from: harness.store)
    #expect(first.embedded() == 2)
    try await harness.index.rebuild(from: harness.store)
    #expect(first.embedded() == 2)
    #expect(try await harness.index.items().map(\.modelID) == ["concepts-a", "concepts-a"])

    try await harness.engine.record([
        MemoryIndex.rememberDraft(id: "drink", text: "Ada likes coffee now", kind: "fact", conversationID: "c", importance: 0.5),
    ], stream: StreamID("memory"))
    try await harness.index.rebuild(from: harness.store)
    #expect(first.embedded() == 3)

    let second = ConceptEmbedder(id: "concepts-b")
    await harness.index.use(second)
    let hits = try await harness.index.search("dog", limit: 1)
    #expect(hits.map(\.id) == ["pet"])
    #expect(second.embedded() == 3)
    #expect(try await harness.index.items().map(\.modelID) == ["concepts-b", "concepts-b"])
    try await harness.index.rebuild(from: harness.store)
    #expect(second.embedded() == 3)
    #expect(await harness.index.embedderID == "concepts-b")
    await harness.engine.close()
}

#if canImport(NaturalLanguage)
@Test(.enabled(if: ContextualEmbedder(language: "en") != nil, "Apple's English sentence model is not on this Mac"))
func appleSentenceModelMatchesMeaningWithoutSharedWords() async throws {
    let embedder = try #require(ContextualEmbedder(language: "en"))
    #expect(embedder.id.hasPrefix("nl-contextual:"))
    let harness = try await openIndex(embedder)
    try await harness.engine.record([
        MemoryIndex.rememberDraft(id: "vet", text: "The puppy has a vet appointment on Tuesday", kind: "fact", conversationID: "c", importance: 0.5),
        MemoryIndex.rememberDraft(id: "tax", text: "The quarterly tax return is due in April", kind: "fact", conversationID: "c", importance: 0.5),
    ], stream: StreamID("memory"))
    try await harness.index.rebuild(from: harness.store)
    let hits = try await harness.index.search("my dog is sick", limit: 2)
    #expect(hits.first?.id == "vet")
    await harness.engine.close()
}
#endif

/// Maps words to a few concepts, so "car" and "automobile" land on the same axis.
private final class ConceptEmbedder: Embedder, @unchecked Sendable {
    let id: String
    let dimensions = 4
    private let lock = NSLock()
    private var count = 0
    private static let concepts: [String: Int] = [
        "car": 0, "automobile": 0, "drive": 0,
        "tea": 1, "coffee": 1,
        "dog": 2, "puppy": 2,
    ]

    init(id: String) { self.id = id }

    func embedded() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        lock.withLock { count += texts.count }
        return texts.map { text in
            var vector = [Float](repeating: 0, count: dimensions)
            for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
                vector[Self.concepts[String(word)] ?? 3] += 1
            }
            return RetrievalMath.normalize(vector)
        }
    }
}

private struct IndexHarness {
    var store: InMemoryEventStore
    var engine: Engine
    var index: MemoryIndex
}

/// Search embeds the query, so counts above include it only where the test says so.
private func openIndex(_ embedder: any Embedder) async throws -> IndexHarness {
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-\(UUID().uuidString).sqlite").path
    let index = try MemoryIndex(path: path, embedder: embedder)
    let engine = try await Engine(store: store, tools: index.tools(store: store), clock: clock, leaseTTL: .seconds(3600))
    return IndexHarness(store: store, engine: engine, index: index)
}
