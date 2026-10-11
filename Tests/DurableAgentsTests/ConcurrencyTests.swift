import DurableCore
import DurableStore
import Foundation
import Testing

/// Holds the model's answer for one conversation until the test opens the gate.
private actor Gate {
    private var open = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Replies at once, except the turn that says "slow", which waits at the gate.
private struct GatedModel: ModelStep {
    let gate: Gate

    func plan(context: ModelContext) async throws -> ScriptedStep {
        let said = context.messages.last { $0.role == "user" }?.text ?? ""
        if said.contains("slow") {
            await gate.pass()
        }
        return .finish("answer to \(said)")
    }
}

@Test func aSlowConversationDoesNotHoldUpAnother() async throws {
    let gate = Gate()
    let harness = try makeHarness(.sqlite)
    let engine = try await harness.engine(model: GatedModel(gate: gate))
    let slowID = ConversationID.generate()
    let fastID = ConversationID.generate()

    let slow = Task { try await engine.submitTurn("slow question", requestID: "slow", to: slowID) }
    await gate.waitUntilEntered()

    // The slow turn is inside its model call. Another conversation, and reads, still go through.
    let fast = try await engine.submitTurn("quick question", requestID: "fast", to: fastID)
    #expect(fast.runStatus == .completed)
    #expect(fast.finalText == "answer to quick question")
    let snapshot = try await engine.snapshot(slowID)
    #expect(snapshot.messages.contains { $0.text == "slow question" })
    _ = try await engine.transcript(fastID)
    _ = try await engine.listConversations()

    await gate.release()
    let finished = try await slow.value
    #expect(finished.finalText == "answer to slow question")
    await engine.close()
}

@Test func aSecondTurnInTheSameConversationWaitsForTheFirst() async throws {
    let gate = Gate()
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine(model: GatedModel(gate: gate))
    let id = ConversationID.generate()

    let first = Task { try await engine.submitTurn("slow one", requestID: "one", to: id) }
    await gate.waitUntilEntered()
    let second = Task { try await engine.submitTurn("then this", requestID: "two", to: id) }
    try await Task.sleep(for: .milliseconds(50))

    // Nothing from the second turn reached the log while the first held the conversation.
    let during = try await engine.transcript(id)
    #expect(!during.contains { $0.text == "then this" })

    await gate.release()
    #expect(try await first.value.finalText == "answer to slow one")
    #expect(try await second.value.finalText == "answer to then this")
    let after = try await engine.transcript(id).map(\.text)
    let firstAnswer = try #require(after.firstIndex(of: "answer to slow one"))
    let secondAsk = try #require(after.firstIndex(of: "then this"))
    #expect(firstAnswer < secondAsk)
    await engine.close()
}

@Test func recoveryWaitsForRunningTurnsAndThenRuns() async throws {
    let gate = Gate()
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine(model: GatedModel(gate: gate))
    let id = ConversationID.generate()

    let slow = Task { try await engine.submitTurn("slow work", requestID: "slow", to: id) }
    await gate.waitUntilEntered()
    let recovery = Task { try await engine.recover() }
    try await Task.sleep(for: .milliseconds(50))
    await gate.release()

    #expect(try await slow.value.finalText == "answer to slow work")
    // Recovery ran after the turn released the conversation, so it found nothing left to continue.
    let actions = try await recovery.value
    #expect(actions.allSatisfy { $0.runStatus != .running })
    await engine.close()
}
