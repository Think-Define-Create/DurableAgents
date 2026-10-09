import DurableCore
import DurableStore
import Foundation
import Testing

@Test func backoffGrowsAndJitterStaysInsideTheRatio() {
    let policy = RetryPolicy(
        maxAttempts: 4,
        initialBackoffSeconds: 2,
        multiplier: 3,
        jitterRatio: 0.5,
        automaticKinds: [.pure]
    )
    #expect(policy.delaySeconds(forAttempt: 2, jitterUnit: 0) == 1)
    #expect(policy.delaySeconds(forAttempt: 2, jitterUnit: 1) == 3)
    #expect(policy.delaySeconds(forAttempt: 3, jitterUnit: 0.5) == 6)
    #expect(!policy.allowsAutomaticRetry(.external))
    #expect(policy.allowsAutomaticRetry(.pure))
    #expect(!BackgroundWakeSupport.appleSchedulerCompiled)
}

@Test func safeToolRetriesAfterBackoffAndStopsAtTheCap() async throws {
    let harness = try makeHarness(.memory)
    let recorder = Recorder()
    let tool = Tool(name: "explode", effect: .pure) { _, context in
        await recorder.add(context)
        if context.attempt < 3 {
            throw RetryProbeError("not yet")
        }
        return ToolReturn(output: .string("ok"))
    }
    let engine = try await harness.engine(
        tools: [tool],
        retryPolicy: RetryPolicy(maxAttempts: 3, initialBackoffSeconds: 10, multiplier: 2)
    )
    let started = try await engine.submit(Submission(
        requestID: "r1",
        text: "try",
        script: crashScript(tool: "explode", callID: "c1")
    ))
    #expect(started.runStatus == .running)
    #expect(await recorder.calls.count == 1)
    let midway = try await engine.events(for: started.conversationID)
    #expect(midway.contains { $0.type == EventType.effectRetry })
    #expect(!midway.contains { $0.type == EventType.runFailed })

    harness.clock.advance(by: 10)
    let firstPump = try await engine.pumpTimers()
    #expect(firstPump.first?.runStatus == .running)
    #expect(await recorder.calls.count == 2)

    harness.clock.advance(by: 20)
    let secondPump = try await engine.pumpTimers()
    #expect(secondPump.first?.runStatus == .completed)
    #expect(secondPump.first?.finalText == "done")
    let calls = await recorder.calls
    #expect(calls.map(\.attempt) == [1, 2, 3])
    #expect(calls.map(\.key) == [calls[0].key, calls[0].key, calls[0].key])
    await engine.close()
}

@Test func externalErrorsDoNotRetryAutomatically() async throws {
    let harness = try makeHarness(.memory)
    let recorder = Recorder()
    let tool = Tool(name: "wire", effect: .external, reconcile: { _, _ in .notDone }) { _, context in
        await recorder.add(context)
        throw RetryProbeError("provider down")
    }
    let engine = try await harness.engine(
        tools: [tool],
        retryPolicy: RetryPolicy(maxAttempts: 5, initialBackoffSeconds: 0, multiplier: 1)
    )
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "send",
        script: crashScript(tool: "wire", callID: "c1")
    ))
    #expect(result.runStatus == .failed)
    #expect(await recorder.calls.count == 1)
    let events = try await engine.events(for: result.conversationID)
    #expect(!events.contains { $0.type == EventType.effectRetry })
    await engine.close()
}

@Test func deliveryRetryDeadLettersWhenThePolicyAllowsOneAttempt() async throws {
    let harness = try makeHarness(.memory)
    let tool = Tool(name: "send", effect: .external, reconcile: { _, _ in .notDone }) { _, _ in
        throw DeliveryRetry(retryable: true, reason: "http 503", status: 503)
    }
    let engine = try await harness.engine(tools: [tool], retryPolicy: .stub)
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "send",
        script: crashScript(tool: "send", callID: "c1")
    ))
    #expect(result.runStatus == .failed)
    let events = try await engine.events(for: result.conversationID)
    #expect(!events.contains { $0.type == EventType.effectRetry })
    let dead = try #require(events.first { $0.type == EventType.deliveryDeadLettered })
    #expect(dead.payload["status"]?.intValue == 503)
    #expect(dead.payload["attempts"]?.intValue == 1)
    await engine.close()
}

@Test func deliveryRetryWaitsForRetryAfterThenSucceeds() async throws {
    let harness = try makeHarness(.memory)
    let recorder = Recorder()
    let tool = Tool(name: "send", effect: .external, reconcile: { _, _ in .notDone }) { _, context in
        await recorder.add(context)
        if context.attempt == 1 {
            throw DeliveryRetry(retryable: true, retryAfter: 12, reason: "http 429", status: 429)
        }
        return ToolReturn(output: .string("sent"))
    }
    let engine = try await harness.engine(tools: [tool], retryPolicy: .standard)
    let started = try await engine.submit(Submission(
        requestID: "r1",
        text: "send",
        script: crashScript(tool: "send", callID: "c1")
    ))
    #expect(started.runStatus == .running)
    harness.clock.advance(by: 11)
    let early = try await engine.pumpTimers()
    #expect(early.first?.runStatus == .running)
    #expect(await recorder.calls.count == 1)
    harness.clock.advance(by: 1)
    let done = try await engine.pumpTimers()
    #expect(done.first?.runStatus == .completed)
    let calls = await recorder.calls
    #expect(calls.count == 2)
    #expect(calls[0].key == calls[1].key)
    await engine.close()
}

@Test func refusedDeliveryDoesNotRetry() async throws {
    let harness = try makeHarness(.memory)
    let recorder = Recorder()
    let tool = Tool(name: "send", effect: .external, reconcile: { _, _ in .notDone }) { _, context in
        await recorder.add(context)
        throw DeliveryRetry(retryable: false, reason: "http 400", status: 400)
    }
    let engine = try await harness.engine(
        tools: [tool],
        retryPolicy: RetryPolicy(maxAttempts: 5, initialBackoffSeconds: 0, multiplier: 1)
    )
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "send",
        script: crashScript(tool: "send", callID: "c1")
    ))
    #expect(result.runStatus == .failed)
    #expect(await recorder.calls.count == 1)
    let events = try await engine.events(for: result.conversationID)
    #expect(events.contains { $0.type == EventType.deliveryDeadLettered })
    #expect(!events.contains { $0.type == EventType.effectRetry })
    await engine.close()
}

@Test func sleepUntilSurvivesRestartUntilTheTimerFires() async throws {
    let harness = try makeHarness(.sqlite)
    let wake = harness.clock.now().addingTimeInterval(15)
    let engine = try await harness.engine()
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "nap",
        script: Script(steps: [
            .sleepUntil(wake),
            .finish("awake"),
        ])
    ))
    #expect(result.runStatus == .suspended)
    let before = try await engine.events(for: result.conversationID)
    #expect(before.contains { $0.type == EventType.waitStarted })
    #expect(!before.contains { $0.type == EventType.timerFired })
    await engine.close()

    harness.clock.advance(by: 15)
    let restarted = try await harness.engine()
    let actions = try await restarted.recover()
    #expect(actions.first?.runStatus == .completed)
    #expect(actions.first?.finalText == "awake")
    let timers = try await restartedStoreTimers(harness)
    #expect(timers.contains { $0.type == EventType.timerFired })
    await restarted.close()
}

@Test func queuedSignalResumesAWaitingRun() async throws {
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine()
    let waiting = try await engine.submit(Submission(
        requestID: "r1",
        text: "wait",
        script: Script(steps: [
            .waitSignal(name: "wire-cleared"),
            .finish("cleared"),
        ])
    ))
    #expect(waiting.runStatus == .suspended)
    let resumed = try await engine.signal("wire-cleared", payload: .string("ok"))
    #expect(resumed?.runStatus == .completed)
    #expect(resumed?.finalText == "cleared")
    let transcript = try await engine.transcript(waiting.conversationID)
    #expect(transcript.contains { $0.role == "system" && $0.text == "ok" })
    await engine.close()
}

private struct RetryProbeError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private func restartedStoreTimers(_ harness: Harness) async throws -> [EventEnvelope] {
    try await harness.store.read(stream: StreamID("timers"))
}
