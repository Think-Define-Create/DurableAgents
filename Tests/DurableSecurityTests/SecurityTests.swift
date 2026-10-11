import DurableCore
import DurableSecurity
import DurableStore
import Foundation
import Testing

private let secretSentence = "Authorization: Bearer sk-test-secret-DO-NOT-LOG"
private let personal = "SSN 123-45-6789 email ada@example.com phone 415-555-0134 routing 021000021 account 123456789012 card 4111111111111111"

@Test func redactionTokenizesSecretsAndKeepsThemOutOfTheLog() async throws {
    let vault = MemoryTokenVault()
    let inner = InMemoryEventStore(storeID: "redact")
    let store = EncryptingEventStore(
        inner: inner,
        keys: MemoryKeyProvider(),
        redactor: BuiltInRedactor(tokenize: true, vault: vault)
    )
    let fence = try await lease(store)
    let stream = StreamID("conv-redact")
    _ = try await store.commit(fence: fence, stream: stream, events: [
        EventDraft(
            type: EventType.messageAppended,
            schemaVersion: 2,
            payload: .object([
                "messageID": .string("m1"),
                "role": .string("user"),
                "text": .string(personal + " " + secretSentence),
            ])
        ),
    ])
    let visible = try await store.read(stream: stream)
    let shown = visible[0].payload.canonicalJSON()
    #expect(!shown.contains("123-45-6789"))
    #expect(!shown.contains("ada@example.com"))
    #expect(!shown.contains("415-555-0134"))
    #expect(!shown.contains("021000021"))
    #expect(!shown.contains("123456789012"))
    #expect(!shown.contains("4111111111111111"))
    #expect(!shown.contains("sk-test-secret-DO-NOT-LOG"))
    #expect(!shown.contains("Bearer"))
    #expect(shown.contains("tok_ssn_"))
    let token = try #require(shown.split(separator: " ").first { $0.hasPrefix("tok_ssn_") })
    let revealed = await vault.plaintext(for: String(token))
    #expect(revealed == "123-45-6789")

    let atRest = try await inner.readAll()
    let stored = atRest.map { $0.payload.canonicalJSON() }.joined(separator: "\n")
    #expect(!stored.contains("123-45-6789"))
    #expect(!stored.contains("sk-test-secret-DO-NOT-LOG"))
    #expect(!stored.contains("ada@example.com"))
    #expect(stored.contains("AES-GCM"))
}

@Test func cryptoShredMakesThePayloadUnreadable() async throws {
    let keys = try FileKeyProvider(directory: FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)", isDirectory: true))
    let phrase = "escrow file 42 stays sealed"
    let inner = InMemoryEventStore(storeID: "shred")
    let store = EncryptingEventStore(inner: inner, keys: keys, redactor: PassThroughRedactor())
    let fence = try await lease(store)
    let stream = StreamID("conv-shred")
    _ = try await store.commit(fence: fence, stream: stream, events: [
        EventDraft(type: EventType.messageAppended, schemaVersion: 2, payload: .object([
            "messageID": .string("m1"),
            "role": .string("assistant"),
            "text": .string(phrase),
        ])),
    ])
    let before = try await store.read(stream: stream)
    #expect(before[0].payload["text"]?.stringValue == phrase)
    let atRest = try await inner.readAll().map { $0.payload.canonicalJSON() }.joined()
    #expect(!atRest.contains(phrase))
    try await keys.shred(stream.raw)
    do {
        _ = try await store.read(stream: stream)
        Issue.record("read should fail after shred")
    } catch let error as SecurityError {
        #expect(error == .shredded(stream.raw))
    }
}

@Test func purgeRemovesOldPayloadsUnlessTheStreamIsHeld() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sec-sqlite-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("events.sqlite").path
    let inner = try SQLiteEventStore(path: path)
    let store = EncryptingEventStore(inner: inner, keys: MemoryKeyProvider(), redactor: PassThroughRedactor())
    let fence = try await lease(store)
    let stream = StreamID("conv-retain")
    let old = Date(timeIntervalSince1970: 1_000)
    let phrase = "phrase-to-purge"
    _ = try await store.commit(fence: fence, stream: stream, events: [
        EventDraft(
            type: EventType.messageAppended,
            schemaVersion: 2,
            payload: .object([
                "messageID": .string("m1"),
                "role": .string("user"),
                "text": .string(phrase),
            ]),
            recordedAt: old
        ),
    ])
    let removed = try await Retention.purge(
        store,
        fence: fence,
        stream: stream,
        policy: RetentionPolicy(maxAge: 60, eventTypes: [EventType.messageAppended]),
        now: Date(timeIntervalSince1970: 10_000)
    )
    #expect(removed == 1)
    let after = try await store.read(stream: stream)
    #expect(after[0].payload["purged"]?.boolValue == true)
    let raw = try String(contentsOfFile: path, encoding: .isoLatin1)
    #expect(!raw.contains(phrase))

    let heldStore = EncryptingEventStore(inner: InMemoryEventStore(storeID: "hold"), keys: MemoryKeyProvider())
    let heldFence = try await lease(heldStore)
    let heldStream = StreamID("conv-hold")
    _ = try await heldStore.commit(fence: heldFence, stream: heldStream, events: [
        EventDraft(
            type: EventType.messageAppended,
            schemaVersion: 2,
            payload: .object([
                "messageID": .string("m1"),
                "role": .string("user"),
                "text": .string("still-here"),
            ]),
            recordedAt: old
        ),
    ])
    try await Retention.hold(heldStore, fence: heldFence, stream: heldStream, held: true)
    let kept = try await Retention.purge(
        heldStore,
        fence: heldFence,
        stream: heldStream,
        policy: RetentionPolicy(maxAge: 0, eventTypes: [EventType.messageAppended]),
        now: Date()
    )
    #expect(kept == 0)
    let heldEvents = try await heldStore.read(stream: heldStream)
    #expect(heldEvents.contains { $0.payload["text"]?.stringValue == "still-here" })
}

@Test func keychainKeyProviderIsAppleOnly() {
    #if canImport(Security)
    #expect(KeyStorageSupport.keychainCompiled)
    #else
    #expect(!KeyStorageSupport.keychainCompiled)
    #endif
}

private func lease(_ store: any EventStore) async throws -> FenceToken {
    let acquired = try await store.acquireLease(owner: UUID(), pid: 1, ttl: .seconds(60))
    return FenceToken(owner: acquired.owner, epoch: acquired.epoch)
}

/// The Keychain provider makes a new key when one is missing, so after a shred the old ciphertext
/// meets a different key. That must read as shredded, not fail the whole store.
private actor RegeneratingKeys: ConversationKeyProvider {
    private var keys: [String: Data] = [:]

    func loadKey(for scope: String) async throws -> Data {
        if let key = keys[scope] { return key }
        let made = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        keys[scope] = made
        return made
    }

    func shred(_ scope: String) async throws {
        keys[scope] = nil
    }
}

@Test func aShreddedConversationIsSkippedEvenWhenTheProviderMakesANewKey() async throws {
    let keys = RegeneratingKeys()
    let inner = InMemoryEventStore(storeID: "regen")
    let writer = EncryptingEventStore(inner: inner, keys: keys)
    let fence = try await lease(writer)
    for stream in ["kept", "gone"] {
        _ = try await writer.commit(fence: fence, stream: StreamID(stream), events: [
            EventDraft(type: EventType.messageAppended, payload: .object(["text": .string(stream)])),
        ])
    }
    try await keys.shred("gone")
    let reader = EncryptingEventStore(inner: inner, keys: keys, omitShredded: true)
    let events = try await reader.readAll()
    #expect(events.map { $0.payload["text"]?.stringValue } == ["kept"])
}
