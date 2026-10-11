import DurableCore
import Foundation
import Testing

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func approvalSurvivesEngineRestartAndResumes(_ kind: StoreKind) async throws {
    let harness = try makeHarness(kind)
    let engine = try await harness.engine()
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "Send the wire",
        script: Script(steps: [
            .assistant("I need a human."),
            .approval(id: "wire-ok", prompt: "Send the wire?"),
            .finish("approved-and-done"),
        ])
    ))
    #expect(result.runStatus == .suspended)
    let token = try #require(result.resumeToken)
    #expect(token.approvalID == "wire-ok")
    await engine.close()

    let restarted = try await harness.engine()
    let recovered = try await restarted.recover()
    #expect(recovered.count == 1)
    #expect(recovered[0].runStatus == .suspended)
    #expect(recovered[0].resumeToken == token)

    let resumed = try await restarted.resume(token: token, decision: .approved)
    #expect(resumed.runStatus == .completed)
    #expect(resumed.finalText == "approved-and-done")
    let snapshot = try await restarted.snapshot(token.conversationID)
    #expect(snapshot.messages.contains { $0.role == "system" && $0.text == "Send the wire?" })
    await restarted.close()
}

@Test func deniedApprovalFailsTheRun() async throws {
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine()
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "Send the wire",
        script: Script(steps: [
            .approval(id: "wire-ok", prompt: "Send the wire?"),
            .finish("should-not-run"),
        ])
    ))
    let token = try #require(result.resumeToken)
    let denied = try await engine.resume(token: token, decision: .denied("customer said no"))
    #expect(denied.runStatus == .failed)
    #expect(denied.failure?.contains("customer said no") == true)
    let transcript = try await engine.transcript(result.conversationID)
    #expect(!transcript.contains { $0.text == "should-not-run" })
    await engine.close()
}

@Test func wrongResumeTokenIsRejected() async throws {
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine()
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "wait",
        script: Script(steps: [.approval(id: "a1", prompt: "OK?")])
    ))
    let token = try #require(result.resumeToken)
    let bogus = ResumeToken(conversationID: token.conversationID, approvalID: "other")
    do {
        _ = try await engine.resume(token: bogus, decision: .approved)
        Issue.record("wrong token resumed the run")
    } catch let error as DurableError {
        guard case .invalidResumeToken = error else {
            throw error
        }
    }
    let still = try await engine.snapshot(token.conversationID)
    #expect(still.run?.status == .suspended)
    await engine.close()
}

/// Asks for one journaled notification per approval.
private struct JournaledNotify: ApprovalChannel {
    func deliver(_ notice: ApprovalNotice) async {}

    func journaledDeliveries(for notice: ApprovalNotice) -> [JournaledDelivery] {
        [JournaledDelivery(id: "notify-\(notice.approvalID)", toolName: "notify.person", arguments: .object(["token": .string(notice.token)]))]
    }
}

/// The approval is journaled but the process dies before its notification is sent. Here the first
/// engine has no `notify.person` tool, so the delivery never leaves memory, which is the same gap.
/// Recovery must send it once, and the run must still resume.
@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func anApprovalWhoseNotificationWasLostIsSentOnRecovery(_ kind: StoreKind) async throws {
    let harness = try makeHarness(kind)
    let first = try await Engine(store: harness.store, clock: harness.clock, approvals: JournaledNotify(), leaseTTL: .seconds(3600))
    let result = try await first.submit(Submission(
        requestID: "r1",
        text: "Send the wire",
        script: Script(steps: [
            .approval(id: "wire-ok", prompt: "Send the wire?"),
            .finish("done"),
        ])
    ))
    let token = try #require(result.resumeToken)
    await first.close()

    let sent = Recorder()
    let notify = Tool(name: "notify.person", effect: .external, summary: "notify", reconcile: { _, _ in .notDone }) { _, context in
        await sent.add(context)
        return ToolReturn(output: .string("sent"))
    }
    let second = try await Engine(store: harness.store, tools: [notify], clock: harness.clock, approvals: JournaledNotify(), leaseTTL: .seconds(3600))
    let recovered = try await second.recover()
    #expect(recovered.first?.resumeToken == token)
    #expect(await sent.calls.count == 1)

    // A second recovery does not notify again.
    _ = try await second.recover()
    #expect(await sent.calls.count == 1)

    let resumed = try await second.resume(token: token, decision: .approved)
    #expect(resumed.finalText == "done")
    await second.close()
}
