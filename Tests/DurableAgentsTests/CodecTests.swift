@testable import DurableCore
import Foundation
import Testing

@Test func sha256MatchesKnownVectors() {
    #expect(SHA256Hash.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(SHA256Hash.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func jsonCanonicalFormRoundTripsIntegersAndKeyOrder() throws {
    let value = JSONValue.object([
        "z": .int(1),
        "a": .array([.string("x\"y"), .bool(true), .null]),
        "m": .object(["n": .int(2)]),
    ])
    let text = value.canonicalJSON()
    #expect(text == #"{"a":["x\"y",true,null],"m":{"n":2},"z":1}"#)
    let parsed = try JSONValue.parse(text)
    #expect(parsed == value)
}

@Test func payloadHashChangesWhenTheTextChanges() {
    let script = Script(steps: [.finish("ok")])
    let close = Submission(requestID: "r1", text: "Close loan #1", script: script)
    let cancel = Submission(requestID: "r1", text: "Cancel loan #1", script: script)
    #expect(close.payloadHash() != cancel.payloadHash())
    #expect(close.payloadHash() == Submission(requestID: "r1", text: "Close loan #1", script: script).payloadHash())
}

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func messageAppendedV1UpcastsWithoutRewritingTheLog(_ kind: StoreKind) async throws {
    let harness = try makeHarness(kind)
    let owner = UUID()
    let lease = try await harness.store.acquireLease(owner: owner, pid: 4242, ttl: .seconds(60))
    let conversation = ConversationID(raw: "conv_legacy")
    _ = try await harness.store.commit(
        fence: lease.fence,
        stream: .conversation(conversation),
        events: [
            EventDraft(
                type: EventType.messageAppended,
                schemaVersion: 1,
                payload: .object(["text": .string("hello from v1")])
            ),
        ]
    )
    try await harness.store.releaseLease(fence: lease.fence)

    let raw = try await harness.store.read(stream: .conversation(conversation))
    let stored = try #require(raw.first)
    #expect(stored.schemaVersion == 1)
    #expect(stored.payload["text"]?.stringValue == "hello from v1")
    #expect(stored.payload["role"] == nil)
    #expect(stored.payload["messageID"] == nil)

    let upcast = try EventCodec.upcast(type: stored.type, schemaVersion: stored.schemaVersion, payload: stored.payload)
    #expect(upcast.version == 2)
    #expect(upcast.payload["role"]?.stringValue == "assistant")
    #expect(upcast.payload["text"]?.stringValue == "hello from v1")
    #expect(upcast.payload["messageID"]?.stringValue?.hasPrefix("m_legacy_") == true)

    let engine = try await harness.engine()
    let transcript = try await engine.transcript(conversation)
    #expect(transcript.count == 1)
    #expect(transcript[0].role == "assistant")
    #expect(transcript[0].text == "hello from v1")
    #expect(transcript[0].messageID.hasPrefix("m_legacy_"))

    let rawAfterRead = try await harness.store.read(stream: .conversation(conversation))
    #expect(rawAfterRead.first?.schemaVersion == 1)
    #expect(rawAfterRead.first?.payload["role"] == nil)
    await engine.close()
}

@Test func newerMessageSchemaIsRejected() {
    #expect(throws: DurableError.self) {
        _ = try EventCodec.upcast(
            type: EventType.messageAppended,
            schemaVersion: 3,
            payload: .object(["text": .string("future")])
        )
    }
}
