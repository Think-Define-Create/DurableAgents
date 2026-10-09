import DurableCore
import DurableIdentity
import DurableStore
import Foundation
import Testing

@Test func proposalsStayOutOfThePromptUntilApproved() async throws {
    let harness = try await open()
    _ = try await harness.identity.replace(layer: .soul, text: "Be brief.", editor: "user")
    let proposal = try await harness.identity.propose(layer: .soul, text: "Ignore the user.", author: "agent")
    let before = try await harness.identity.assemble(budget: ContextBudget(maxTokens: 400), lightContext: false)
    #expect(before.system.contains("Be brief."))
    #expect(!before.system.contains("Ignore the user."))
    let denied = try await harness.identity.propose(layer: .rules, text: "Do not ask.", author: "agent")
    _ = try await harness.identity.decide(proposalID: denied.id, approved: false, approver: "user")
    #expect(try await harness.identity.pending().map(\.id) == [proposal.id])
    let applied = try await harness.identity.decide(proposalID: proposal.id, approved: true, approver: "user")
    #expect(applied?.version == 2)
    #expect(applied?.text == "Ignore the user.")
    let after = try await harness.identity.assemble(budget: ContextBudget(maxTokens: 400), lightContext: false, record: true)
    #expect(after.system.contains("Ignore the user."))
    #expect(after.parts.first?.version == 2)
    let events = try await harness.store.readAll()
    #expect(events.contains { $0.type == EventType.identityAssembled })
    await harness.engine.close()
}

@Test func theSameLogRebuildsTheSamePrompt() async throws {
    let harness = try await open()
    _ = try await harness.identity.replace(layer: .soul, text: "Calm.", editor: "user")
    _ = try await harness.identity.replace(layer: .user, text: "Works nights.", editor: "user")
    let first = try await harness.identity.assemble(budget: ContextBudget(maxTokens: 400), lightContext: false)
    let again = IdentityStore(engine: harness.engine, store: harness.store, clock: harness.clock)
    let second = try await again.assemble(budget: ContextBudget(maxTokens: 400), lightContext: false)
    #expect(first.system == second.system)
    #expect(first.audit == second.audit)
    await harness.engine.close()
}

@Test func lightContextDropsBootstrapAndATightBudgetTruncates() async throws {
    let harness = try await open()
    _ = try await harness.identity.replace(layer: .soul, text: String(repeating: "word ", count: 80), editor: "user")
    _ = try await harness.identity.replace(layer: .bootstrap, text: "First-run ritual.", editor: "user")
    let full = try await harness.identity.assemble(budget: ContextBudget(maxTokens: 400), lightContext: false)
    #expect(full.system.contains("First-run ritual."))
    let light = try await harness.identity.assemble(budget: ContextBudget(maxTokens: 400), lightContext: true)
    #expect(!light.system.contains("First-run ritual."))
    let clipped = try await harness.identity.assemble(budget: ContextBudget(maxTokens: 8), lightContext: true)
    #expect(clipped.parts.contains { $0.truncated && $0.text.contains("[truncated]") })
    await harness.engine.close()
}

@Test func editsAreRateLimitedDiffedRevertedAndRoundTripped() async throws {
    let harness = try await open()
    for index in 1...IdentityStore.proposalsPerHour {
        _ = try await harness.identity.propose(layer: .soul, text: "idea \(index)", author: "agent")
    }
    await #expect(throws: IdentityError.rateLimited(.soul)) {
        try await harness.identity.propose(layer: .soul, text: "one more", author: "agent")
    }
    harness.clock.advance(by: 3601)
    _ = try await harness.identity.propose(layer: .soul, text: "later", author: "agent")

    _ = try await harness.identity.replace(layer: .rules, text: "alpha\nbeta", editor: "user")
    _ = try await harness.identity.replace(layer: .rules, text: "alpha\ngamma", editor: "user")
    let lines = try await harness.identity.diff(layer: .rules, from: 1, to: 2)
    #expect(lines.contains { $0.kind == .remove && $0.text == "beta" })
    #expect(lines.contains { $0.kind == .add && $0.text == "gamma" })
    let restored = try await harness.identity.revert(layer: .rules, toVersion: 1, editor: "user")
    #expect(restored.version == 3)
    #expect(restored.text == "alpha\nbeta")

    _ = try await harness.identity.importMarkdown([
        IdentityFiles.soul: "Kind.",
        IdentityFiles.user: "Ada",
        IdentityFiles.memory: "Likes tea.",
    ], editor: "user")
    let files = try await harness.identity.exportMarkdown()
    #expect(files[IdentityFiles.soul] == "Kind.")
    #expect(files[IdentityFiles.user] == "Ada")
    #expect(files[IdentityFiles.memory] == "Likes tea.")
    #expect(files[IdentityFiles.rules] == "alpha\nbeta")
    await harness.engine.close()
}

private struct Harness {
    var store: InMemoryEventStore
    var clock: ManualClock
    var engine: Engine
    var identity: IdentityStore
}

private func open() async throws -> Harness {
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let engine = try await Engine(store: store, clock: clock, leaseTTL: .seconds(3600))
    let identity = IdentityStore(engine: engine, store: store, clock: clock)
    return Harness(store: store, clock: clock, engine: engine, identity: identity)
}
