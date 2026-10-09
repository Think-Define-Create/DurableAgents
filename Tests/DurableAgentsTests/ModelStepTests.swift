import DurableCore
import DurableFoundationModels
import DurableStore
import Foundation
import Testing

@Test func foundationModelsTargetIsAStubWithoutTheAppleSDK() {
    #if canImport(FoundationModels)
    #expect(FoundationModelsSupport.compiledIn)
    #else
    #expect(!FoundationModelsSupport.compiledIn)
    #endif
}

@Test func modelTurnJournalsThePlanBeforeTheEffect() async throws {
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine(
        tools: [
            Tool(name: "echo", effect: .pure, summary: "echo") { input, _ in
                ToolReturn(output: input)
            },
        ],
        model: ScriptedModelStep(steps: [
            .tool(name: "echo", callID: "c1", arguments: .string("token")),
            .finish("done"),
        ])
    )
    let result = try await engine.submitTurn("Echo a token", requestID: "req-model")
    #expect(result.runStatus == .completed)
    #expect(result.finalText == "done")
    let events = try await engine.events(for: result.conversationID)
    let planned = try #require(events.first { $0.type == EventType.stepPlanned })
    let intent = try #require(events.first { $0.type == EventType.effectIntent })
    #expect(planned.globalSeq < intent.globalSeq)
    #expect(planned.payload["stepIndex"]?.intValue == 0)
    #expect(events.contains { $0.type == EventType.runStarted && $0.payload["driver"]?.stringValue == "model" })
    await engine.close()
}

@Test func recoveryReplaysTheJournaledPlanWithoutASecondToolRun() async throws {
    let harness = try makeHarness(.sqlite)
    let once = Once()
    let recorder = Recorder()
    let model = ScriptedModelStep(steps: [
        .tool(name: "wire", callID: "c1", arguments: .string("go")),
        .finish("recovered"),
    ])
    let tool = Tool(name: "wire", effect: .external, summary: "wire", reconcile: { _, _ in
        .done(.string("sent"))
    }) { _, context in
        await recorder.add(context)
        if await once.consume() {
            throw SimulatedProcessCrash()
        }
        return ToolReturn(output: .string("sent"))
    }

    let first = try await harness.engine(tools: [tool], model: model)
    do {
        _ = try await first.submitTurn("Send it", requestID: "req-crash")
        Issue.record("expected a simulated crash")
    } catch is SimulatedProcessCrash {
    }
    let crashedID = try await harness.storeIDConversation()
    let midpoint = try await first.events(for: crashedID)
    #expect(midpoint.filter { $0.type == EventType.stepPlanned && $0.payload["stepIndex"]?.intValue == 0 }.count == 1)
    #expect(midpoint.contains { $0.type == EventType.effectIntent })
    #expect(!midpoint.contains { $0.type == EventType.effectResult })
    await first.close()

    let second = try await harness.engine(tools: [tool], model: model)
    let actions = try await second.recover()
    #expect(actions.count == 1)
    #expect(actions[0].runStatus == .completed)
    #expect(actions[0].finalText == "recovered")
    let events = try await second.events(for: crashedID)
    #expect(events.filter { $0.type == EventType.stepPlanned && $0.payload["stepIndex"]?.intValue == 0 }.count == 1)
    let calls = await recorder.calls
    #expect(calls.count == 1)
    #expect(calls[0].isReplay == false)
    await second.close()
}

private extension Harness {
    func storeIDConversation() async throws -> ConversationID {
        let projectionIDs = try await store.readAll().compactMap { event -> String? in
            guard event.type == EventType.conversationOpened else { return nil }
            return event.payload["conversationID"]?.stringValue
        }
        return ConversationID(raw: try #require(projectionIDs.first))
    }
}
