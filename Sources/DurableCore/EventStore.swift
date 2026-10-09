import Foundation

/// Append-only event log plus the single-owner lease that fences it.
///
/// Implementations live in `DurableStore`. The engine never imports a database.
public protocol EventStore: Sendable {
    func storeID() async throws -> String

    func acquireLease(owner: UUID, pid: Int32, ttl: Duration) async throws -> Lease

    func releaseLease(fence: FenceToken) async throws

    /// Atomically appends `events` if `fence.epoch` is still current.
    func commit(fence: FenceToken, stream: StreamID, events: [EventDraft]) async throws -> [EventEnvelope]

    func readAll() async throws -> [EventEnvelope]

    func read(stream: StreamID) async throws -> [EventEnvelope]

    /// Replaces one stored payload. Sequence numbers stay put. Used by retention purge.
    func rewritePayload(globalSeq: UInt64, payload: JSONValue, fence: FenceToken) async throws
}
