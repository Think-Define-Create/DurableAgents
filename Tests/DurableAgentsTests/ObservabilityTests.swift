import DurableCore
import DurableStore
import Foundation
import Testing

actor RecordingTracer: RunTracing {
    struct Finished: Sendable, Equatable {
        var name: String
        var begin: [String: SpanAttribute]
        var end: [String: SpanAttribute]
    }

    private var open: [String: (name: String, attributes: [String: SpanAttribute])] = [:]
    private var finished: [Finished] = []
    private var next = 0

    func begin(name: String, attributes: [String: SpanAttribute]) async -> SpanHandle {
        next += 1
        let id = String(next)
        open[id] = (name, attributes)
        return SpanHandle(id: id, name: name)
    }

    func end(_ span: SpanHandle, attributes: [String: SpanAttribute]) async {
        let started = open.removeValue(forKey: span.id)
        finished.append(Finished(name: started?.name ?? span.name, begin: started?.attributes ?? [:], end: attributes))
    }

    func snapshot() -> [Finished] { finished }
}

@Test func hashChainChangesWhenAPayloadChangesAndDetectsAGap() {
    let first = EventEnvelope(
        globalSeq: 1,
        stream: StreamID("c1"),
        streamSeq: 1,
        type: EventType.messageAppended,
        schemaVersion: 1,
        recordedAt: Date(timeIntervalSince1970: 10),
        payload: .object(["text": .string("hello")])
    )
    let second = EventEnvelope(
        globalSeq: 2,
        stream: StreamID("c1"),
        streamSeq: 2,
        type: EventType.effectIntent,
        schemaVersion: 1,
        recordedAt: Date(timeIntervalSince1970: 11),
        payload: .object(["tool": .string("echo"), "arguments": .string("sk-live")])
    )
    let original = EventHashChain.inspect([first, second])
    #expect(original.intact)
    #expect(original.tip != EventHashChain.genesis)
    #expect(EventHashChain.verify([first, second], expectedTip: original.tip))

    let tampered = EventEnvelope(
        globalSeq: second.globalSeq,
        stream: second.stream,
        streamSeq: second.streamSeq,
        type: second.type,
        schemaVersion: second.schemaVersion,
        recordedAt: second.recordedAt,
        payload: .object(["tool": .string("echo"), "arguments": .string("changed")])
    )
    #expect(EventHashChain.verify([first, tampered], expectedTip: original.tip) == false)

    let gapped = EventHashChain.inspect([second])
    #expect(gapped.intact == false)
    #expect(gapped.problems.isEmpty == false)
}

@Test func spanScrubDropsPromptKeysAndSecretValues() {
    let cleaned = SpanScrub.scrub([
        "conversation": .string("c1"),
        "prompt": .string("please wire funds"),
        "note": .string("mail user@example.com"),
        "step": .int(1),
    ])
    #expect(cleaned["prompt"] == nil)
    #expect(cleaned["conversation"] == .string("c1"))
    #expect(cleaned["note"] == .string("[redacted]"))
    #expect(cleaned["step"] == .int(1))
}

@Test func auditExportOmitsSecretsAndKeepsIntentColumns() async throws {
    let secret = "sk-supersecret-token"
    let harness = try makeHarness(.memory)
    let tracer = RecordingTracer()
    let tool = Tool(name: "echo", effect: .pure) { _, _ in
        ToolReturn(output: .string("ok"))
    }
    let engine = try await Engine(
        store: harness.store,
        tools: [tool],
        model: ScriptedModelStep(steps: [
            .tool(name: "echo", callID: "c1", arguments: .object(["body": .string(secret)])),
            .finish("done"),
        ]),
        clock: harness.clock,
        tracing: tracer,
        leaseTTL: .seconds(3600)
    )
    let result = try await engine.submitTurn("please leak \(secret) and user@example.com", requestID: "r1")
    #expect(result.runStatus == .completed)

    let events = try await harness.store.readAll()
    let exported = AuditExport.jsonl(events) + "\n" + AuditExport.csv(events)
    #expect(exported.contains(secret) == false)
    #expect(exported.contains("user@example.com") == false)
    #expect(exported.contains("effect.intent"))
    #expect(exported.contains("echo"))
    #expect(exported.contains("c1"))
    #expect(events.contains { $0.payload.canonicalJSON().contains(secret) })

    let spans = await tracer.snapshot()
    #expect(spans.contains { $0.name == "run" })
    #expect(spans.contains { $0.name == "model.plan" })
    #expect(spans.contains { $0.name == "effect" })
    let rendered = spans.map { span in
        (span.begin.map { "\($0.key)=\(SpanScrub.render($0.value))" } + span.end.map { "\($0.key)=\(SpanScrub.render($0.value))" })
            .joined(separator: " ")
    }.joined(separator: "\n")
    #expect(rendered.contains(secret) == false)
    #expect(rendered.contains("user@example.com") == false)
    #expect(rendered.contains("please leak") == false)
    await engine.close()
}

@Test func auditExportRecordsApprovalOutcomeWithoutThePrompt() async throws {
    let harness = try makeHarness(.sqlite)
    let engine = try await harness.engine()
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "Send the wire to secret-account-991",
        script: Script(steps: [
            .approval(id: "wire-ok", prompt: "Send the wire to secret-account-991?"),
            .finish("done"),
        ])
    ))
    let token = try #require(result.resumeToken)
    _ = try await engine.resume(token: token, decision: .approved)
    let events = try await harness.store.readAll()
    let csv = AuditExport.csv(events)
    #expect(csv.contains("approval.requested"))
    #expect(csv.contains("approval.resolved"))
    #expect(csv.contains("wire-ok"))
    #expect(csv.contains("secret-account-991") == false)
    let resolved = AuditExport.rows(events).first { $0.type == EventType.approvalResolved }
    #expect(resolved?.ok == "true")
    await engine.close()
}
