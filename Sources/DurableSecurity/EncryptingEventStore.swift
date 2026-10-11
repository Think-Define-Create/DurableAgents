import DurableCore
import Foundation

/// Encrypts event payloads at rest. Readers of this store see plaintext.
/// Readers of `inner` see AES-GCM ciphertext. Keys come from `ConversationKeyProvider`
/// and are never written into the log.
public actor EncryptingEventStore: EventStore {
    public let inner: any EventStore
    private let keys: any ConversationKeyProvider
    private let redactor: any PayloadRedactor
    /// When true, streams whose key was shredded are omitted from reads so the rest of the store still opens.
    /// The ciphertext stays in `inner`. Default is false: a shredded stream fails the read.
    private let omitShredded: Bool

    public init(
        inner: any EventStore,
        keys: any ConversationKeyProvider,
        redactor: any PayloadRedactor = PassThroughRedactor(),
        omitShredded: Bool = false
    ) {
        self.inner = inner
        self.keys = keys
        self.redactor = redactor
        self.omitShredded = omitShredded
    }

    public func storeID() async throws -> String {
        try await inner.storeID()
    }

    public func acquireLease(owner: UUID, pid: Int32, ttl: Duration) async throws -> Lease {
        try await inner.acquireLease(owner: owner, pid: pid, ttl: ttl)
    }

    public func renewLease(fence: FenceToken, ttl: Duration) async throws -> Lease {
        try await inner.renewLease(fence: fence, ttl: ttl)
    }

    public func releaseLease(fence: FenceToken) async throws {
        try await inner.releaseLease(fence: fence)
    }

    public func commit(fence: FenceToken, stream: StreamID, events drafts: [EventDraft]) async throws -> [EventEnvelope] {
        var sealed: [EventDraft] = []
        sealed.reserveCapacity(drafts.count)
        for draft in drafts {
            let redacted = await redactor.redact(draft.payload)
            sealed.append(EventDraft(
                type: draft.type,
                schemaVersion: draft.schemaVersion,
                payload: try await encrypt(redacted, scope: stream.raw),
                recordedAt: draft.recordedAt
            ))
        }
        let stored = try await inner.commit(fence: fence, stream: stream, events: sealed)
        return try await decryptAll(stored)
    }

    public func readAll() async throws -> [EventEnvelope] {
        try await decryptAll(try await inner.readAll())
    }

    public func read(stream: StreamID) async throws -> [EventEnvelope] {
        try await decryptAll(try await inner.read(stream: stream))
    }

    public func rewritePayload(globalSeq: UInt64, payload: JSONValue, fence: FenceToken) async throws {
        let stored = try await inner.readAll()
        guard let event = stored.first(where: { $0.globalSeq == globalSeq }) else {
            throw DurableError.invariant("no event \(globalSeq)")
        }
        let redacted = await redactor.redact(payload)
        let sealed = try await encrypt(redacted, scope: event.stream.raw)
        try await inner.rewritePayload(globalSeq: globalSeq, payload: sealed, fence: fence)
    }

    private func encrypt(_ payload: JSONValue, scope: String) async throws -> JSONValue {
        let key = try await keys.loadKey(for: scope)
        let plain = Data(payload.canonicalJSON().utf8)
        let boxed = try AESGCM.seal(plain, key: key)
        return .object([
            "alg": .string("AES-GCM"),
            "ct": .string(boxed.base64EncodedString()),
            "v": .int(1),
        ])
    }

    private func decryptAll(_ events: [EventEnvelope]) async throws -> [EventEnvelope] {
        var opened: [EventEnvelope] = []
        opened.reserveCapacity(events.count)
        for event in events {
            do {
                opened.append(try await decrypt(event))
            } catch let error as SecurityError {
                if omitShredded, Self.isShredded(error) {
                    continue
                }
                throw error
            }
        }
        return opened
    }

    private static func isShredded(_ error: SecurityError) -> Bool {
        switch error {
        case .shredded, .missingKey:
            return true
        case .malformedCiphertext, .keyUnavailable:
            return false
        }
    }

    private func decrypt(_ event: EventEnvelope) async throws -> EventEnvelope {
        guard event.payload["alg"]?.stringValue == "AES-GCM",
              let encoded = event.payload["ct"]?.stringValue,
              let boxed = Data(base64Encoded: encoded)
        else {
            throw SecurityError.malformedCiphertext("event \(event.globalSeq) is not an AES-GCM payload")
        }
        let key = try await keys.loadKey(for: event.stream.raw)
        let plain = try AESGCM.open(boxed, key: key, scope: event.stream.raw)
        guard let text = String(data: plain, encoding: .utf8) else {
            throw SecurityError.malformedCiphertext("event \(event.globalSeq) did not decrypt to UTF-8")
        }
        var copy = event
        copy.payload = try JSONValue.parse(text)
        return copy
    }
}
