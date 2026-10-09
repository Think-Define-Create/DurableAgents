import DurableCore
import Foundation
import Testing

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func pureEffectReplaysAfterCrashBetweenIntentAndResult(_ kind: StoreKind) async throws {
    let recorder = Recorder()
    let once = Once()
    let tool = Tool(name: "read", effect: .pure) { _, context in
        await recorder.add(context)
        if await once.consume() {
            throw SimulatedProcessCrash()
        }
        return ToolReturn(output: .string("attempt-\(context.attempt)"))
    }
    let outcome = try await crashAndRecover(kind, tool: tool, recorder: recorder, callID: "c-pure")
    #expect(outcome.calls.count == 2)
    #expect(outcome.calls[0].isReplay == false)
    #expect(outcome.calls[1].isReplay == true)
    #expect(outcome.calls[0].attempt == 1)
    #expect(outcome.calls[1].attempt == 2)
    #expect(outcome.result.payload["output"]?.stringValue == "attempt-2")
    #expect(outcome.result.payload["replayed"]?.boolValue == true)
    #expect(outcome.result.payload["reconciled"]?.boolValue == false)
    #expect(outcome.finalText == "done")
}

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func idempotentEffectReplaysWithTheSameEngineKey(_ kind: StoreKind) async throws {
    let recorder = Recorder()
    let once = Once()
    let tool = Tool(name: "draft", effect: .idempotent) { _, context in
        await recorder.add(context)
        if await once.consume() {
            throw SimulatedProcessCrash()
        }
        return ToolReturn(output: .string(context.key.raw))
    }
    let outcome = try await crashAndRecover(
        kind,
        tool: tool,
        recorder: recorder,
        callID: "c-idem",
        arguments: .object(["subject": .string("loan 1")])
    )
    let expected = EffectKey.derive(
        storeID: outcome.storeID,
        conversation: outcome.conversationID,
        call: CallID("c-idem")
    )
    #expect(outcome.calls.count == 2)
    #expect(outcome.calls.allSatisfy { $0.key == expected })
    #expect(outcome.intent.payload["key"]?.stringValue == expected.raw)
    #expect(outcome.intent.payload["effect"]?.stringValue == EffectKind.idempotent.rawValue)
    #expect(outcome.result.payload["output"]?.stringValue == expected.raw)
    #expect(outcome.result.payload["key"]?.stringValue == expected.raw)
    #expect(outcome.intent.globalSeq < outcome.result.globalSeq)
}

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func transactionalWritesCommitWithTheResultAndOnlyOnce(_ kind: StoreKind) async throws {
    let recorder = Recorder()
    let once = Once()
    let tool = Tool(name: "book", effect: .transactional) { _, context in
        await recorder.add(context)
        if await once.consume() {
            throw SimulatedProcessCrash()
        }
        return ToolReturn(
            output: .string("booked"),
            writes: [StateWrite(namespace: "ledger", key: "wires", value: .int(1))]
        )
    }
    let harness = try makeHarness(kind)
    let engine = try await harness.engine(tools: [tool])
    try await expectCrash {
        try await engine.submit(Submission(
            requestID: "r1",
            text: "book the wire",
            script: crashScript(tool: "book", callID: "c-tx")
        ))
    }
    await engine.close()

    let midpoint = try await harness.store.readAll()
    #expect(midpoint.contains { $0.type == EventType.effectIntent })
    #expect(!midpoint.contains { $0.type == EventType.effectResult })
    #expect(!midpoint.contains { $0.type == EventType.stateWrote })

    let recovered = try await harness.engine(tools: [tool])
    let actions = try await recovered.recover()
    #expect(actions.first?.runStatus == .completed)
    let stored = try await recovered.storedValue(namespace: "ledger", key: "wires")
    #expect(stored == .int(1))
    let events = try await harness.store.readAll()
    let writes = events.filter { $0.type == EventType.stateWrote }
    #expect(writes.count == 1)
    let result = try requireResult(in: events)
    let write = try #require(writes.first)
    #expect(write.globalSeq == result.globalSeq + 1)
    #expect(await recorder.calls.count == 2)
    await recovered.close()
}

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func externalEffectReconcilesDoneWithoutRerunning(_ kind: StoreKind) async throws {
    let recorder = Recorder()
    let once = Once()
    let receipt = Receipt()
    let tool = Tool(name: "wire", effect: .external, reconcile: { _, _ in
        if let saved = await receipt.get() {
            return .done(.string(saved))
        }
        return .notDone
    }) { _, context in
        await recorder.add(context)
        await receipt.set("sent")
        if await once.consume() {
            throw SimulatedProcessCrash()
        }
        return ToolReturn(output: .string("should-not-be-stored"))
    }
    let outcome = try await crashAndRecover(kind, tool: tool, recorder: recorder, callID: "c-ext")
    #expect(outcome.calls.count == 1)
    #expect(outcome.result.payload["reconciled"]?.boolValue == true)
    #expect(outcome.result.payload["replayed"]?.boolValue == false)
    #expect(outcome.result.payload["output"]?.stringValue == "sent")
    #expect(outcome.finalText == "done")
}

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func externalNotDoneRerunsWithTheSameKey(_ kind: StoreKind) async throws {
    let recorder = Recorder()
    let once = Once()
    let tool = Tool(name: "wire", effect: .external, reconcile: { _, _ in
        .notDone
    }) { _, context in
        await recorder.add(context)
        if await once.consume() {
            throw SimulatedProcessCrash()
        }
        return ToolReturn(output: .string("sent-on-replay"))
    }
    let outcome = try await crashAndRecover(kind, tool: tool, recorder: recorder, callID: "c-ext-rerun")
    #expect(outcome.calls.count == 2)
    #expect(outcome.calls[0].key == outcome.calls[1].key)
    #expect(outcome.result.payload["output"]?.stringValue == "sent-on-replay")
    #expect(outcome.result.payload["replayed"]?.boolValue == true)
    #expect(outcome.result.payload["reconciled"]?.boolValue == false)
}

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func externalUnknownSuspendsForAHumanInsteadOfGuessing(_ kind: StoreKind) async throws {
    let recorder = Recorder()
    let tool = Tool(name: "wire", effect: .external, reconcile: { _, _ in
        .unknown(reason: "no receipt")
    }) { _, context in
        await recorder.add(context)
        throw SimulatedProcessCrash()
    }
    let harness = try makeHarness(kind)
    let engine = try await harness.engine(tools: [tool])
    try await expectCrash {
        try await engine.submit(Submission(
            requestID: "r1",
            text: "send",
            script: crashScript(tool: "wire", callID: "c-unknown")
        ))
    }
    await engine.close()

    let recovered = try await harness.engine(tools: [tool])
    let actions = try await recovered.recover()
    let action = try #require(actions.first)
    #expect(action.runStatus == .suspended)
    let token = try #require(action.resumeToken)
    #expect(token.approvalID == "reconcile-c-unknown")
    #expect(await recorder.calls.count == 1)

    let resumed = try await recovered.resume(
        token: token,
        decision: .approvedWithOutput(.string("human-confirmed"))
    )
    #expect(resumed.runStatus == .completed)
    #expect(resumed.finalText == "done")
    let result = try requireResult(in: try await harness.store.readAll())
    #expect(result.payload["output"]?.stringValue == "human-confirmed")
    #expect(result.payload["reconciled"]?.boolValue == true)
    #expect(await recorder.calls.count == 1)
    await recovered.close()
}

@Test func scriptedModelCompletesWithoutAProvider() async throws {
    let harness = try makeHarness(.memory)
    let tool = Tool(name: "echo", effect: .pure) { input, _ in
        ToolReturn(output: input)
    }
    let engine = try await harness.engine(tools: [tool])
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "Say hello and echo a token",
        script: Script(steps: [
            .assistant("Hello."),
            .tool(name: "echo", callID: "c1", arguments: .string("token-1")),
            .finish("done"),
        ])
    ))
    #expect(result.runStatus == .completed)
    #expect(result.finalText == "done")
    let transcript = try await engine.transcript(result.conversationID)
    #expect(transcript.map(\.role) == ["user", "assistant", "tool", "assistant"])
    #expect(transcript.map(\.text) == ["Say hello and echo a token", "Hello.", "token-1", "done"])
    let started = try await engine.events(for: result.conversationID)
    let retry = try #require(started.first { $0.type == EventType.runStarted }?.payload["retry"])
    #expect(retry["maxAttempts"]?.intValue == Int64(RetryPolicy.stub.maxAttempts))
    await engine.close()
}

@Test func toolErrorFailsTheRunWithoutRetrying() async throws {
    let recorder = Recorder()
    let harness = try makeHarness(.memory)
    let tool = Tool(name: "explode", effect: .pure) { _, context in
        await recorder.add(context)
        throw ProbeToolError("upstream refused")
    }
    let engine = try await harness.engine(tools: [tool])
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "try",
        script: crashScript(tool: "explode", callID: "c1")
    ))
    #expect(result.runStatus == .failed)
    #expect(result.failure?.contains("upstream refused") == true)
    #expect(await recorder.calls.count == 1)
    await engine.close()
}

private struct CrashOutcome {
    var calls: [Recorder.Call]
    var intent: EventEnvelope
    var result: EventEnvelope
    var finalText: String?
    var storeID: String
    var conversationID: ConversationID
}

private func crashAndRecover(
    _ kind: StoreKind,
    tool: Tool,
    recorder: Recorder,
    callID: String,
    arguments: JSONValue = .object([:])
) async throws -> CrashOutcome {
    let harness = try makeHarness(kind)
    let engine = try await harness.engine(tools: [tool])
    try await expectCrash {
        try await engine.submit(Submission(
            requestID: "r1",
            text: "go",
            script: crashScript(tool: tool.name, callID: callID, arguments: arguments)
        ))
    }
    await engine.close()
    let midpoint = try await harness.store.readAll()
    let intent = try requireIntent(in: midpoint)
    #expect(!midpoint.contains { $0.type == EventType.effectResult })

    let recovered = try await harness.engine(tools: [tool])
    let actions = try await recovered.recover()
    #expect(actions.first?.runStatus == .completed)
    let events = try await harness.store.readAll()
    let result = try requireResult(in: events)
    let calls = await recorder.calls
    await recovered.close()
    return CrashOutcome(
        calls: calls,
        intent: intent,
        result: result,
        finalText: actions.first?.finalText,
        storeID: try await harness.store.storeID(),
        conversationID: ConversationID(raw: intent.stream.raw)
    )
}

private func expectCrash(_ body: () async throws -> SubmitResult) async throws {
    do {
        _ = try await body()
        Issue.record("expected a simulated crash between intent and result")
        throw ExpectedCrash()
    } catch is SimulatedProcessCrash {
        return
    } catch is ExpectedCrash {
        throw ExpectedCrash()
    } catch {
        throw error
    }
}

private struct ExpectedCrash: Error {}

private struct ProbeToolError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private actor Receipt {
    private var value: String?
    func set(_ value: String) { self.value = value }
    func get() -> String? { value }
}
