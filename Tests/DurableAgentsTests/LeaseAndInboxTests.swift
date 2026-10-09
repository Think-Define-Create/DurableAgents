import DurableCore
import Foundation
import Testing

@Test func secondOwnerIsRejectedUntilTheLeaseIsStolen() async throws {
    let harness = try makeHarness(.sqlite)
    let engineA = try await harness.engine()
    let epochA = await engineA.currentFence().epoch

    do {
        _ = try await harness.engine()
        Issue.record("a second owner acquired a live lease")
    } catch let error as DurableError {
        guard case .leaseHeld = error else {
            Issue.record("expected leaseHeld, got \(error)")
            throw error
        }
    }

    harness.liveness.markDead(ProcessInfo.processInfo.processIdentifier)
    let engineB = try await harness.engine()
    let epochB = await engineB.currentFence().epoch
    #expect(epochB > epochA)

    do {
        _ = try await engineA.submit(Submission(
            requestID: "r1",
            text: "from the stale owner",
            script: Script(steps: [.finish("nope")])
        ))
        Issue.record("stale owner was allowed to commit")
    } catch let error as DurableError {
        guard case .fenced(let expected, let actual) = error else {
            Issue.record("expected fenced, got \(error)")
            throw error
        }
        #expect(expected == epochA)
        #expect(actual == epochB)
    }

    let result = try await engineB.submit(Submission(
        requestID: "r1",
        text: "from the new owner",
        script: Script(steps: [.finish("ok")])
    ))
    #expect(result.runStatus == .completed)
    #expect(result.finalText == "ok")
    await engineB.close()
}

@Test func expiredLeaseCanBeStolenWhileTheProcessIsAlive() async throws {
    let harness = try makeHarness(.memory)
    let engineA = try await harness.engine(leaseTTL: .seconds(10))
    let epochA = await engineA.currentFence().epoch
    harness.clock.advance(by: 11)
    let engineB = try await harness.engine(leaseTTL: .seconds(10))
    #expect(await engineB.currentFence().epoch > epochA)
    do {
        _ = try await engineA.submit(Submission(
            requestID: "r1",
            text: "stale",
            script: Script(steps: [.finish("nope")])
        ))
        Issue.record("expired owner was allowed to commit")
    } catch let error as DurableError {
        guard case .fenced = error else {
            throw error
        }
    }
    await engineB.close()
}

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func requestIDConflictIsExplicitAndDuplicateIsNot(_ kind: StoreKind) async throws {
    let harness = try makeHarness(kind)
    let engine = try await harness.engine()
    let script = Script(steps: [.finish("ok")])
    let first = try await engine.submit(Submission(requestID: "r1", text: "Close loan #1", script: script))
    #expect(first.duplicate == false)
    #expect(first.runStatus == .completed)
    let before = try await engine.events(for: first.conversationID)

    let duplicate = try await engine.submit(
        Submission(requestID: "r1", text: "Close loan #1", script: script),
        to: first.conversationID
    )
    #expect(duplicate.duplicate == true)
    #expect(duplicate.payloadHash == first.payloadHash)
    #expect(duplicate.runStatus == .completed)

    do {
        _ = try await engine.submit(
            Submission(requestID: "r1", text: "Cancel loan #1", script: script),
            to: first.conversationID
        )
        Issue.record("different payload with the same requestId was accepted")
    } catch let error as DurableError {
        guard case .requestIDConflict(let requestID, let existing, let attempted) = error else {
            Issue.record("expected requestIDConflict, got \(error)")
            throw error
        }
        #expect(requestID == "r1")
        #expect(existing == first.payloadHash)
        #expect(attempted != existing)
    }

    let after = try await engine.events(for: first.conversationID)
    #expect(after.count == before.count)
    await engine.close()
}

@Test func inboxHoldsASecondSubmissionUntilTheSuspendedRunResumes() async throws {
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine()
    let first = try await engine.submit(Submission(
        requestID: "r1",
        text: "first",
        script: Script(steps: [
            .approval(id: "a1", prompt: "Approve?"),
            .finish("first-done"),
        ])
    ))
    let token = try #require(first.resumeToken)
    let second = try await engine.submit(
        Submission(requestID: "r2", text: "second", script: Script(steps: [.finish("second-done")])),
        to: first.conversationID
    )
    #expect(second.queued == true)
    #expect(second.duplicate == false)
    let before = try await engine.events(for: first.conversationID)
    #expect(before.filter { $0.type == EventType.runStarted }.count == 1)

    let resumed = try await engine.resume(token: token, decision: .approved)
    #expect(resumed.runStatus == .completed)
    #expect(resumed.finalText == "second-done")
    let transcript = try await engine.transcript(first.conversationID)
    #expect(transcript.map(\.text).contains("first-done"))
    #expect(transcript.map(\.text).contains("second-done"))
    let after = try await engine.events(for: first.conversationID)
    #expect(after.filter { $0.type == EventType.runStarted }.count == 2)
    await engine.close()
}

@Test func timerRequestIsJournaledAndDoesNotBlock() async throws {
    let harness = try makeHarness(.memory)
    let log = TimerLog()
    let engine = try await harness.engine(timers: log)
    let fireAt = Date(timeIntervalSince1970: 1_800_000_000)
    try await engine.requestTimer(name: "approval-reminder", fireAt: fireAt)
    #expect(await log.names == ["approval-reminder"])
    let timers = try await harness.store.read(stream: StreamID("timers"))
    #expect(timers.count == 1)
    #expect(timers[0].type == EventType.timerRequested)
    #expect(timers[0].payload["name"]?.stringValue == "approval-reminder")
    await engine.close()
}

private actor TimerLog: TimerScheduling {
    private(set) var names: [String] = []

    func schedule(name: String, fireAt: Date) async {
        names.append(name)
    }
}
