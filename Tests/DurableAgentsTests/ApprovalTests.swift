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
