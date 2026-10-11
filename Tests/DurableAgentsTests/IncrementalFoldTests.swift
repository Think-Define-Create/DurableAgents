import DurableCore
import DurableStore
import Foundation
import Testing

/// Counts full reads, so a test can show the engine only reads what is new.
private actor CountingStore: EventStore {
    let inner: InMemoryEventStore
    private(set) var fullReads = 0
    private(set) var tailReads = 0

    init(inner: InMemoryEventStore) { self.inner = inner }

    func storeID() async throws -> String { try await inner.storeID() }
    func acquireLease(owner: UUID, pid: Int32, ttl: Duration) async throws -> Lease { try await inner.acquireLease(owner: owner, pid: pid, ttl: ttl) }
    func renewLease(fence: FenceToken, ttl: Duration) async throws -> Lease { try await inner.renewLease(fence: fence, ttl: ttl) }
    func releaseLease(fence: FenceToken) async throws { try await inner.releaseLease(fence: fence) }
    func commit(fence: FenceToken, stream: StreamID, events: [EventDraft]) async throws -> [EventEnvelope] {
        try await inner.commit(fence: fence, stream: stream, events: events)
    }
    func readAll() async throws -> [EventEnvelope] {
        fullReads += 1
        return try await inner.readAll()
    }
    func readAll(after globalSeq: UInt64) async throws -> [EventEnvelope] {
        tailReads += 1
        return try await inner.readAll(after: globalSeq)
    }
    func read(stream: StreamID) async throws -> [EventEnvelope] { try await inner.read(stream: stream) }
    func rewritePayload(globalSeq: UInt64, payload: JSONValue, fence: FenceToken) async throws {
        try await inner.rewritePayload(globalSeq: globalSeq, payload: payload, fence: fence)
    }
}

@Test func theEngineReadsOnlyNewEventsAndMatchesAFullFold() async throws {
    let clock = ManualClock()
    let inner = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let store = CountingStore(inner: inner)
    let echo = Tool(name: "echo", effect: .pure, summary: "echo") { input, _ in ToolReturn(output: input) }
    let engine = try await Engine(store: store, tools: [echo], clock: clock, leaseTTL: .seconds(3600))
    var ids: [ConversationID] = []
    for turn in 0..<12 {
        let id = ids.count < 3 ? ConversationID.generate() : ids[turn % 3]
        if ids.count < 3 { ids.append(id) }
        _ = try await engine.submit(Submission(requestID: "r\(turn)", text: "turn \(turn)", script: Script(steps: [
            .tool(name: "echo", callID: "c\(turn)", arguments: .string("x\(turn)")),
            .finish("done \(turn)"),
        ])), to: id)
    }
    #expect(await store.fullReads == 0)
    #expect(await store.tailReads > 0)
    let live = try await ids.asyncMap { try await engine.snapshot($0) }
    await engine.close()

    // A new engine folds the whole log once. Its view must equal the incremental one.
    let fresh = try await Engine(store: store, tools: [echo], clock: clock, leaseTTL: .seconds(3600))
    let replayed = try await ids.asyncMap { try await fresh.snapshot($0) }
    #expect(live == replayed)
    await fresh.close()
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
