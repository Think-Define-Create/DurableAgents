import DurableCore
import Foundation

/// Process-local event log with the same lease and commit rules as SQLite.
public actor InMemoryEventStore: EventStore {
    private let identifier: String
    private let clock: any StoreClock
    private let liveness: any ProcessLiveness
    private var highWater: UInt64 = 0
    private var lease: Lease?
    private var events: [EventEnvelope] = []
    private var nextGlobal: UInt64 = 1
    private var nextStreamSeq: [String: UInt64] = [:]

    public init(
        storeID: String = "mem-" + UUID().uuidString.lowercased(),
        clock: any StoreClock = SystemClock(),
        liveness: any ProcessLiveness = SystemProcessLiveness()
    ) {
        self.identifier = storeID
        self.clock = clock
        self.liveness = liveness
    }

    public func storeID() async throws -> String { identifier }

    public func acquireLease(owner: UUID, pid: Int32, ttl: Duration) async throws -> Lease {
        let ruling = ruleLease(
            existing: lease,
            highWater: highWater,
            requester: owner,
            now: clock.now(),
            isAlive: liveness.isAlive(pid:)
        )
        switch ruling {
        case .held(let holder):
            throw DurableError.leaseHeld(owner: holder.owner, epoch: holder.epoch)
        case .renew:
            guard var current = lease else {
                throw DurableError.invariant("lease disappeared during renew")
            }
            current.pid = pid
            current.expiresAt = clock.now().addingTimeInterval(ttl.timeInterval)
            lease = current
            return current
        case .grant(let epoch):
            let granted = Lease(
                owner: owner,
                epoch: epoch,
                pid: pid,
                expiresAt: clock.now().addingTimeInterval(ttl.timeInterval)
            )
            lease = granted
            highWater = epoch
            return granted
        }
    }

    public func releaseLease(fence: FenceToken) async throws {
        try requireFence(fence)
        highWater = max(highWater, fence.epoch)
        lease = nil
    }

    public func commit(fence: FenceToken, stream: StreamID, events drafts: [EventDraft]) async throws -> [EventEnvelope] {
        try requireFence(fence)
        var written: [EventEnvelope] = []
        written.reserveCapacity(drafts.count)
        var global = nextGlobal
        var streamSeq = nextStreamSeq[stream.raw] ?? 1
        for draft in drafts {
            let envelope = EventEnvelope(
                globalSeq: global,
                stream: stream,
                streamSeq: streamSeq,
                type: draft.type,
                schemaVersion: draft.schemaVersion,
                recordedAt: draft.recordedAt ?? clock.now(),
                payload: draft.payload
            )
            written.append(envelope)
            global += 1
            streamSeq += 1
        }
        events.append(contentsOf: written)
        nextGlobal = global
        nextStreamSeq[stream.raw] = streamSeq
        return written
    }

    public func readAll() async throws -> [EventEnvelope] { events }

    public func read(stream: StreamID) async throws -> [EventEnvelope] {
        events.filter { $0.stream == stream }
    }

    public func rewritePayload(globalSeq: UInt64, payload: JSONValue, fence: FenceToken) async throws {
        try requireFence(fence)
        guard let index = events.firstIndex(where: { $0.globalSeq == globalSeq }) else {
            throw DurableError.invariant("no event \(globalSeq)")
        }
        let existing = events[index]
        events[index] = EventEnvelope(
            globalSeq: existing.globalSeq,
            stream: existing.stream,
            streamSeq: existing.streamSeq,
            type: existing.type,
            schemaVersion: existing.schemaVersion,
            recordedAt: existing.recordedAt,
            payload: payload
        )
    }

    private func requireFence(_ fence: FenceToken) throws {
        guard let lease, lease.owner == fence.owner, lease.epoch == fence.epoch else {
            throw DurableError.fenced(expectedEpoch: fence.epoch, actualEpoch: lease?.epoch ?? 0)
        }
    }
}
