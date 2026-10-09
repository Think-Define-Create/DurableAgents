import DurableCore
import DurableStore
import Foundation
import Testing

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func stepBudgetFailsBeforeTheNextStep(kind: StoreKind) async throws {
    let harness = try makeHarness(kind)
    let engine = try await harness.engine()
    let result = try await engine.submit(Submission(
        requestID: "steps",
        text: "two",
        script: Script(steps: [.assistant("one"), .assistant("two")]),
        budget: RunBudget(maxSteps: 1, onExceeded: .fail)
    ))
    #expect(result.runStatus == .failed)
    #expect(result.failure == "budget exceeded: steps")
    let events = try await engine.events(for: result.conversationID)
    let breach = try #require(events.first { $0.type == EventType.runBudgetExceeded })
    #expect(breach.payload["reason"]?.stringValue == "steps")
    #expect(breach.payload["disposition"]?.stringValue == "fail")
    #expect(events.filter { $0.type == EventType.stepCompleted }.count == 1)
    await engine.close()
}

@Test func toolCallBudgetCountsJournaledIntents() async throws {
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine(tools: [
        Tool(name: "echo", effect: .pure) { input, _ in ToolReturn(output: input) },
    ])
    let result = try await engine.submit(Submission(
        requestID: "tools",
        text: "tools",
        script: Script(steps: [
            .tool(name: "echo", callID: "c1", arguments: .string("a")),
            .tool(name: "echo", callID: "c2", arguments: .string("b")),
            .finish("done"),
        ]),
        budget: RunBudget(maxToolCalls: 1, onExceeded: .fail)
    ))
    #expect(result.runStatus == .failed)
    #expect(result.failure == "budget exceeded: toolCalls")
    let events = try await engine.events(for: result.conversationID)
    #expect(events.filter { $0.type == EventType.effectResult && $0.payload["ok"]?.boolValue == true }.count == 1)
    await engine.close()
}

@Test func tokenBudgetUsesPlannedProviderUsage() async throws {
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine(model: ScriptedModelStep(steps: [
        .providerTurn(ProviderTurnStep(text: "long", calls: [], inputTokens: 40, outputTokens: 20)),
        .finish("later"),
    ]))
    let result = try await engine.submitTurn(
        "count tokens",
        requestID: "tokens",
        budget: RunBudget(maxTokens: 50, onExceeded: .fail)
    )
    #expect(result.runStatus == .failed)
    #expect(result.failure == "budget exceeded: tokens")
    let events = try await engine.events(for: result.conversationID)
    #expect(events.contains { $0.type == EventType.stepPlanned })
    #expect(!events.contains { $0.type == EventType.stepCompleted })
    await engine.close()
}

@Test func wallBudgetUsesTheEngineClock() async throws {
    let harness = try makeHarness(.memory)
    let clock = harness.clock
    let engine = try await harness.engine(tools: [
        Tool(name: "tick", effect: .pure) { _, _ in
            clock.advance(by: 30)
            return ToolReturn(output: .string("ticked"))
        },
    ])
    let result = try await engine.submit(Submission(
        requestID: "wall",
        text: "wall",
        script: Script(steps: [
            .tool(name: "tick", callID: "c1", arguments: .object([:])),
            .finish("done"),
        ]),
        budget: RunBudget(maxWallSeconds: 10, onExceeded: .fail)
    ))
    #expect(result.runStatus == .failed)
    #expect(result.failure == "budget exceeded: wall")
    await engine.close()
}

@Test func repeatedIdenticalToolsStopTheRun() async throws {
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine(tools: [
        Tool(name: "echo", effect: .pure) { input, _ in ToolReturn(output: input) },
    ])
    let same = JSONValue.object(["q": .string("ping")])
    let result = try await engine.submit(Submission(
        requestID: "repeat",
        text: "repeat",
        script: Script(steps: [
            .tool(name: "echo", callID: "c1", arguments: same),
            .tool(name: "echo", callID: "c2", arguments: same),
            .tool(name: "echo", callID: "c3", arguments: same),
            .finish("done"),
        ]),
        budget: RunBudget(onExceeded: .fail)
    ))
    #expect(result.runStatus == .failed)
    #expect(result.failure == "budget exceeded: repeat")
    let events = try await engine.events(for: result.conversationID)
    #expect(events.filter { $0.type == EventType.effectIntent }.count == 3)
    await engine.close()
}

@Test func identicalToolsFinishWhenNoBudgetIsSet() async throws {
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine(tools: [
        Tool(name: "echo", effect: .pure) { input, _ in ToolReturn(output: input) },
    ])
    let same = JSONValue.string("ping")
    let result = try await engine.submit(Submission(
        requestID: "free",
        text: "free",
        script: Script(steps: [
            .tool(name: "echo", callID: "c1", arguments: same),
            .tool(name: "echo", callID: "c2", arguments: same),
            .tool(name: "echo", callID: "c3", arguments: same),
            .finish("done"),
        ])
    ))
    #expect(result.runStatus == .completed)
    #expect(result.finalText == "done")
    await engine.close()
}

@Test func suspendedBudgetContinuesAfterApprovalAndFailsWhenDenied() async throws {
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine()
    let held = try await engine.submit(Submission(
        requestID: "hold",
        text: "hold",
        script: Script(steps: [.assistant("one"), .assistant("two")]),
        budget: RunBudget(maxSteps: 1, onExceeded: .suspend)
    ))
    #expect(held.runStatus == .suspended)
    let token = try #require(held.resumeToken)
    #expect(token.raw.contains("budget:steps"))
    let continued = try await engine.resume(token: token, decision: .approved)
    #expect(continued.runStatus == .completed)
    #expect(continued.finalText == "two")

    let denied = try await engine.submit(Submission(
        requestID: "deny",
        text: "deny",
        script: Script(steps: [.assistant("one"), .assistant("two")]),
        budget: RunBudget(maxSteps: 1, onExceeded: .suspend)
    ))
    let denyToken = try #require(denied.resumeToken)
    let stopped = try await engine.resume(token: denyToken, decision: .denied("no"))
    #expect(stopped.runStatus == .failed)
    #expect(stopped.failure == "approval denied: no")
    await engine.close()
}

@Test func budgetSurvivesACrashAndStillStopsTheRun() async throws {
    let harness = try makeHarness(.sqlite)
    let once = Once()
    let model = CrashThenReply(once: once)
    let first = try await harness.engine(model: model)
    do {
        _ = try await first.submitTurn(
            "keep",
            requestID: "crash-budget",
            budget: RunBudget(maxSteps: 1, onExceeded: .fail)
        )
        Issue.record("expected a simulated crash")
    } catch is SimulatedProcessCrash {}
    let opened = try await harness.store.readAll().first { $0.type == EventType.conversationOpened }
    let id = ConversationID(raw: try #require(opened?.payload["conversationID"]?.stringValue))
    let midpoint = try await first.events(for: id)
    #expect(midpoint.contains { $0.type == EventType.runStarted && $0.payload["budget"] != nil })
    #expect(!midpoint.contains { $0.type == EventType.stepPlanned })
    await first.close()

    let second = try await harness.engine(model: model)
    let actions = try await second.recover()
    #expect(actions.count == 1)
    #expect(actions[0].runStatus == .failed)
    #expect(actions[0].failure == "budget exceeded: steps")
    let events = try await second.events(for: id)
    #expect(events.filter { $0.type == EventType.stepCompleted }.count == 1)
    #expect(events.contains { $0.type == EventType.runBudgetExceeded })
    #expect(!events.contains { $0.type == EventType.runCompleted })
    await second.close()
}

@Test func aBudgetChangesTheSubmissionHash() {
    let script = Script(steps: [.finish("ok")])
    let plain = Submission(requestID: "r", text: "hi", script: script)
    let limited = Submission(
        requestID: "r",
        text: "hi",
        script: script,
        budget: RunBudget(maxSteps: 4, onExceeded: .fail)
    )
    #expect(plain.payloadHash() != limited.payloadHash())
    #expect(Submission.modelTurnHash(text: "hi") != Submission.modelTurnHash(text: "hi", budget: limited.budget))
}

private struct CrashThenReply: ModelStep {
    var once: Once

    func plan(context: ModelContext) async throws -> ScriptedStep {
        if await once.consume() {
            throw SimulatedProcessCrash()
        }
        if context.completedSteps == 0 {
            return .assistant("kept")
        }
        return .finish("should-not-run")
    }
}
