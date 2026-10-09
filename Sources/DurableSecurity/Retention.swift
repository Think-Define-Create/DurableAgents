import DurableCore
import Foundation

public struct RetentionPolicy: Sendable, Equatable {
    public var maxAge: TimeInterval
    /// Event types this rule may tombstone. Hold and purge records are never included.
    public var eventTypes: Set<String>

    public init(maxAge: TimeInterval, eventTypes: Set<String>) {
        self.maxAge = maxAge
        self.eventTypes = eventTypes
    }
}

public enum Retention {
    /// Latest `retention.hold` on the stream wins. No hold event means the stream can be purged.
    public static func isHeld(_ events: [EventEnvelope]) -> Bool {
        let holds = events.filter { $0.type == EventType.retentionHold }
        guard let latest = holds.max(by: { $0.globalSeq < $1.globalSeq }) else {
            return false
        }
        return latest.payload["held"]?.boolValue == true
    }

    public static func hold(
        _ store: any EventStore,
        fence: FenceToken,
        stream: StreamID,
        held: Bool,
        at: Date = Date()
    ) async throws {
        _ = try await store.commit(fence: fence, stream: stream, events: [
            EventDraft(
                type: EventType.retentionHold,
                payload: .object([
                    "held": .bool(held),
                    "stream": .string(stream.raw),
                ]),
                recordedAt: at
            ),
        ])
    }

    /// Rewrites matching payloads to `{"purged": true}` and appends `retention.purged`.
    /// A legal hold leaves the stream unchanged and returns zero.
    @discardableResult
    public static func purge(
        _ store: any EventStore,
        fence: FenceToken,
        stream: StreamID,
        policy: RetentionPolicy,
        now: Date
    ) async throws -> Int {
        let events = try await store.read(stream: stream)
        if isHeld(events) {
            return 0
        }
        var purged: [UInt64] = []
        for event in events {
            if event.type == EventType.retentionHold || event.type == EventType.retentionPurged {
                continue
            }
            if event.payload["purged"]?.boolValue == true {
                continue
            }
            guard policy.eventTypes.contains(event.type) else { continue }
            let age = now.timeIntervalSince(event.recordedAt)
            guard age >= policy.maxAge else { continue }
            try await store.rewritePayload(
                globalSeq: event.globalSeq,
                payload: .object(["purged": .bool(true)]),
                fence: fence
            )
            purged.append(event.globalSeq)
        }
        if purged.isEmpty {
            return 0
        }
        _ = try await store.commit(fence: fence, stream: stream, events: [
            EventDraft(
                type: EventType.retentionPurged,
                payload: .object([
                    "count": .int(Int64(purged.count)),
                    "sequences": .array(purged.map { .int(Int64($0)) }),
                ]),
                recordedAt: now
            ),
        ])
        return purged.count
    }
}
