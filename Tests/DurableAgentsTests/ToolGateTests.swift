import DurableCore
import DurableStore
import Foundation
import Testing

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func toolApprovalGateSuspendsBeforeTheEffect(_ kind: StoreKind) async throws {
    let recorder = Recorder()
    let tool = Tool(name: "pay", effect: .idempotent, requiresApproval: true, approvalRisk: .standard) { _, context in
        await recorder.add(context)
        return ToolReturn(output: .string("paid"))
    }
    let harness = try makeHarness(kind)
    let engine = try await harness.engine(tools: [tool])
    let submitted = try await engine.submit(Submission(
        requestID: "r1",
        text: "pay",
        script: Script(steps: [
            .tool(name: "pay", callID: "c1", arguments: .object([:])),
            .finish("done"),
        ])
    ))
    #expect(submitted.runStatus == .suspended)
    #expect(await recorder.calls.isEmpty)
    let events = try await harness.store.readAll()
    #expect(!events.contains { $0.type == EventType.effectIntent })
    let requested = try #require(events.first { $0.type == EventType.approvalRequested })
    #expect(requested.payload["purpose"]?.stringValue == "gate")
    #expect(requested.payload["requiredAuth"]?.stringValue == AuthenticationLevel.session.rawValue)
    let token = try #require(submitted.resumeToken)
    let resumed = try await engine.resume(
        token: token,
        decision: .approved,
        approver: Approver(id: "clerk", authLevel: .session)
    )
    #expect(resumed.runStatus == .completed)
    #expect(await recorder.calls.count == 1)
    let after = try await harness.store.readAll()
    #expect(after.contains { $0.type == EventType.effectIntent })
    #expect(after.contains { $0.type == EventType.effectResult })
}

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func highRiskGateRejectsSessionAuthAndAcceptsBiometric(_ kind: StoreKind) async throws {
    let recorder = Recorder()
    let tool = Tool(name: "wire", effect: .external, requiresApproval: true, approvalRisk: .high) { _, context in
        await recorder.add(context)
        return ToolReturn(output: .string("sent"))
    }
    let harness = try makeHarness(kind)
    let engine = try await harness.engine(tools: [tool])
    let submitted = try await engine.submit(Submission(
        requestID: "r1",
        text: "wire",
        script: Script(steps: [
            .tool(name: "wire", callID: "c1", arguments: .object([:])),
            .finish("sent"),
        ])
    ))
    let token = try #require(submitted.resumeToken)
    let requested = try await harness.store.readAll()
    let approval = try #require(requested.first { $0.type == EventType.approvalRequested })
    #expect(approval.payload["requiredAuth"]?.stringValue == AuthenticationLevel.devicePasscode.rawValue)
    await #expect(throws: DurableError.self) {
        try await engine.resume(
            token: token,
            decision: .approved,
            approver: Approver(id: "clerk", authLevel: .session)
        )
    }
    #expect(await recorder.calls.isEmpty)
    let resumed = try await engine.resume(
        token: token,
        decision: .approved,
        approver: Approver(id: "owner", authLevel: .biometric)
    )
    #expect(resumed.runStatus == .completed)
    #expect(await recorder.calls.count == 1)
}

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func externalWithoutReconcileSuspendsAfterCrash(_ kind: StoreKind) async throws {
    let recorder = Recorder()
    let tool = Tool(name: "opaque", effect: .external) { _, context in
        await recorder.add(context)
        throw SimulatedProcessCrash()
    }
    let harness = try makeHarness(kind)
    let engine = try await harness.engine(tools: [tool])
    do {
        _ = try await engine.submit(Submission(
            requestID: "r1",
            text: "call",
            script: Script(steps: [
                .tool(name: "opaque", callID: "c1", arguments: .object([:])),
                .finish("done"),
            ])
        ))
        Issue.record("expected a simulated crash")
    } catch is SimulatedProcessCrash {
    }
    await engine.close()
    let midpoint = try await harness.store.readAll()
    #expect(midpoint.contains { $0.type == EventType.effectIntent })
    #expect(!midpoint.contains { $0.type == EventType.effectResult })

    let recovered = try await harness.engine(tools: [tool])
    let actions = try await recovered.recover()
    #expect(actions.first?.runStatus == .suspended)
    #expect(await recorder.calls.count == 1)
    let token = try #require(actions.first?.resumeToken)
    let resumed = try await recovered.resume(
        token: token,
        decision: .approvedWithOutput(.string("manual")),
        approver: Approver(id: "owner", authLevel: .session)
    )
    #expect(resumed.runStatus == .completed)
    #expect(resumed.finalText == "done")
    #expect(await recorder.calls.count == 1)
    let result = try requireResult(in: try await harness.store.readAll())
    #expect(result.payload["output"]?.stringValue == "manual")
    #expect(result.payload["reconciled"]?.boolValue == true)
}
