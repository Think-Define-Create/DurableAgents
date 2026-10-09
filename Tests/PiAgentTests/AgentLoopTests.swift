import DurableCore
import DurableFoundationModels
import DurableStore
import Foundation
import PiAgent
import PiAI
import Testing

final class QueueProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[ModelStreamEvent]]
    private(set) var requests: [ModelRequest] = []

    init(script: [[ModelStreamEvent]]) {
        self.script = script
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let events = script.isEmpty ? [ModelStreamEvent.stop(StopReason(raw: "end_turn"))] : script.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func recordedRequests() -> [ModelRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

final class Overlap: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private(set) var maxInside = 0

    func enter() {
        lock.lock()
        inside += 1
        maxInside = max(maxInside, inside)
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.08)
        lock.lock()
        inside -= 1
        lock.unlock()
    }
}

final class CrashOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func boom() throws {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first {
            throw SimulatedProcessCrash()
        }
    }
}

private func toolCall(_ name: String, _ id: String, _ arguments: String) -> ModelStreamEvent {
    .toolCall(ProviderToolCall(id: id, name: name, argumentsJSON: arguments))
}

private func finish(_ text: String) -> [ModelStreamEvent] {
    [.textDelta(text), .stop(StopReason(raw: "end_turn"))]
}

@Test func parallelSafeToolsOverlapAndUnsafeToolsDoNot() async throws {
    let overlap = Overlap()
    let pure = Tool(name: "lookup", effect: .pure, summary: "Look up a file") { _, _ in
        overlap.enter()
        return ToolReturn(output: .string("file"))
    }
    let other = Tool(name: "search", effect: .pure, summary: "Search notes") { _, _ in
        overlap.enter()
        return ToolReturn(output: .string("notes"))
    }
    let externalOverlap = Overlap()
    let external = Tool(name: "send", effect: .external, summary: "Send mail", reconcile: { _, _ in
        .notDone
    }) { _, _ in
        externalOverlap.enter()
        return ToolReturn(output: .string("sent"))
    }
    let side = Tool(name: "read", effect: .pure, summary: "Read a record") { _, _ in
        externalOverlap.enter()
        return ToolReturn(output: .string("record"))
    }

    let parallel = QueueProvider(script: [
        [toolCall("lookup", "c1", #"{"q":"a"}"#), toolCall("search", "c2", #"{"q":"b"}"#)],
        finish("both"),
    ])
    let store = InMemoryEventStore()
    let engine = try await Engine(
        store: store,
        tools: [pure, other],
        model: PiAgentStep(provider: parallel, modelName: "scripted", instructions: "Be brief.")
    )
    let result = try await engine.submitTurn("Find both", requestID: "req-parallel")
    #expect(result.runStatus == .completed)
    #expect(result.finalText == "both")
    #expect(overlap.maxInside == 2)
    let events = try await engine.events(for: result.conversationID)
    let intents = events.filter { $0.type == EventType.effectIntent }
    #expect(intents.count == 2)
    #expect(events.contains { $0.type == EventType.stepPlanned && $0.payload["step"]?["type"]?.stringValue == "providerTurn" })

    let serial = QueueProvider(script: [
        [toolCall("read", "r1", #"{"q":"a"}"#), toolCall("send", "s1", #"{"q":"b"}"#)],
        finish("mailed"),
    ])
    let serialEngine = try await Engine(
        store: InMemoryEventStore(),
        tools: [side, external],
        model: PiAgentStep(provider: serial, modelName: "scripted")
    )
    let mailed = try await serialEngine.submitTurn("Send it", requestID: "req-serial")
    #expect(mailed.runStatus == .completed)
    #expect(mailed.finalText == "mailed")
    #expect(externalOverlap.maxInside == 1)
}

@Test func providerTurnCrashReplaysBothSafeTools() async throws {
    let once = CrashOnce()
    let recorder = Recorder()
    let lookup = Tool(name: "lookup", effect: .pure) { _, context in
        await recorder.add(context)
        return ToolReturn(output: .string("file"))
    }
    let crash = Tool(name: "search", effect: .idempotent) { _, context in
        await recorder.add(context)
        try once.boom()
        return ToolReturn(output: .string("notes"))
    }
    let store = InMemoryEventStore()
    let provider = QueueProvider(script: [
        [toolCall("lookup", "c1", #"{"q":"a"}"#), toolCall("search", "c2", #"{"q":"b"}"#)],
        finish("recovered"),
    ])
    let engine = try await Engine(
        store: store,
        tools: [lookup, crash],
        model: PiAgentStep(provider: provider, modelName: "scripted")
    )
    await #expect(throws: SimulatedProcessCrash.self) {
        try await engine.submitTurn("Find both", requestID: "req-crash")
    }
    await engine.close()
    let restarted = try await Engine(
        store: store,
        tools: [lookup, crash],
        model: PiAgentStep(provider: provider, modelName: "scripted")
    )
    let actions = try await restarted.recover()
    #expect(actions.contains { $0.runStatus == .completed && $0.finalText == "recovered" })
    let calls = await recorder.calls
    #expect(calls.filter { $0.key.raw.hasSuffix(":c1") }.count == 2)
    #expect(calls.filter { $0.key.raw.hasSuffix(":c2") }.count == 2)
    #expect(calls.contains { $0.isReplay && $0.key.raw.hasSuffix(":c2") })
}

@Test func compactionKeepsTheLogAndDropsOldPromptText() async throws {
    let provider = QueueProvider(script: [
        finish("Earlier notes were folded."),
        finish("ready"),
    ])
    let store = InMemoryEventStore()
    let scripted = try await Engine(store: store, tools: [])
    let seeded = try await scripted.submit(Submission(
        requestID: "seed",
        text: "alpha-token please",
        script: Script(steps: [
            .assistant("beta-token noted"),
            .finish("seeded"),
        ])
    ))
    await scripted.close()
    let agent = try await Engine(
        store: store,
        tools: [],
        model: PiAgentStep(
            provider: provider,
            modelName: "scripted",
            compactAfterMessages: 2,
            keepRecentMessages: 1
        )
    )
    let result = try await agent.submitTurn("latest-token", requestID: "req-compact", to: seeded.conversationID)
    #expect(result.runStatus == .completed)
    #expect(result.finalText == "ready")
    let transcript = try await agent.transcript(seeded.conversationID)
    #expect(transcript.contains { $0.text.contains("alpha-token") })
    #expect(transcript.contains { $0.text.contains("beta-token") })
    let events = try await agent.events(for: seeded.conversationID)
    #expect(events.contains { $0.type == EventType.contextCompacted })
    let requests = provider.recordedRequests()
    #expect(requests.count == 2)
    let answer = requests[1].messages.map(\.text).joined(separator: "\n")
    let summarized = requests[0].messages.map(\.text).joined(separator: "\n")
    #expect(summarized.contains("alpha-token"))
    #expect(answer.contains("latest-token"))
    #expect(answer.contains("Earlier notes were folded."))
    #expect(!answer.contains("alpha-token"))
}

@Test func forkCopiesTheTranscriptWithNewMessageIDs() async throws {
    let store = InMemoryEventStore()
    let engine = try await Engine(store: store, tools: [])
    let original = try await engine.submit(Submission(
        requestID: "seed",
        text: "harbor lane",
        script: Script(steps: [.finish("noted")])
    ))
    let forked = try await engine.fork(original.conversationID)
    let source = try await engine.transcript(original.conversationID)
    let copy = try await engine.transcript(forked)
    #expect(copy.map(\.text) == source.map(\.text))
    #expect(Set(copy.map(\.messageID)).isDisjoint(with: Set(source.map(\.messageID))))
    let opened = try await engine.events(for: forked)
    #expect(opened.first?.payload["forkedFrom"]?.stringValue == original.conversationID.raw)
    #expect(try await engine.transcript(original.conversationID) == source)
}

@Test func subagentRunsAChildConversation() async throws {
    let provider = QueueProvider(script: [
        [toolCall("research", "sub-1", #"{"goal":"check harbor"}"#)],
        finish("the file is clean"),
        finish("parent done"),
    ])
    let researchRan = Flag()
    let research = Tool(name: "research", effect: .pure) { _, _ in
        researchRan.value = true
        return ToolReturn(output: .string("should-not-run"))
    }
    let engine = try await Engine(
        store: InMemoryEventStore(),
        tools: [research],
        model: PiAgentStep(
            provider: provider,
            modelName: "scripted",
            subagentTools: ["research"]
        )
    )
    let result = try await engine.submitTurn("Ask research", requestID: "req-sub")
    #expect(result.runStatus == .completed)
    #expect(result.finalText == "parent done")
    #expect(!researchRan.value)
    let events = try await engine.events(for: result.conversationID)
    let started = try #require(events.first { $0.type == EventType.subagentStarted })
    let childRaw = try #require(started.payload["childConversationID"]?.stringValue)
    let child = try await engine.transcript(ConversationID(raw: childRaw))
    #expect(child.contains { $0.text == "check harbor" })
    #expect(child.contains { $0.text == "the file is clean" })
    let parent = try await engine.transcript(result.conversationID)
    #expect(parent.contains { $0.role == "tool" && $0.text == "the file is clean" })
}

@Test func foundationModelsProviderIsAppleOnly() {
    #if canImport(FoundationModels)
    #expect(FoundationModelsProviderSupport.compiledIn)
    #else
    #expect(!FoundationModelsProviderSupport.compiledIn)
    #endif
}

final class Flag: @unchecked Sendable {
    var value = false
}

actor Recorder {
    struct Call: Sendable {
        var key: EffectKey
        var isReplay: Bool
    }

    private(set) var calls: [Call] = []

    func add(_ context: EffectContext) {
        calls.append(Call(key: context.key, isReplay: context.isReplay))
    }
}
