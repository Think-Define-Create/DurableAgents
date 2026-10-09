import DurableCore
import DurableKit
import DurableStore
import Foundation
import Testing

private actor KitRecorder {
    private(set) var calls: [EffectContext] = []

    func add(_ context: EffectContext) {
        calls.append(context)
    }
}

private actor KitOnce {
    private var armed = true

    func consume() -> Bool {
        if armed {
            armed = false
            return true
        }
        return false
    }
}

@Test @MainActor func conversationModelCompletesAScriptedTurn() async throws {
    let store = InMemoryEventStore()
    let model = try await ConversationModel.open(
        store: store,
        tools: [
            Tool(name: "echo", effect: .pure, summary: "echo") { input, _ in
                ToolReturn(output: input)
            },
        ],
        model: ScriptedModelStep(steps: [
            .tool(name: "echo", callID: "c1", arguments: .string("token")),
            .finish("done"),
        ]),
        backendLabel: "script"
    )
    let stream = model.eventLog
    let collected = Task {
        var types: [String] = []
        for await event in stream {
            types.append(event.type)
            if event.type == EventType.runCompleted {
                break
            }
        }
        return types
    }
    try await model.send("Echo a token")
    #expect(model.status == .done)
    #expect(model.messages.contains { $0.role == "user" && $0.text == "Echo a token" })
    #expect(model.messages.contains { $0.role == "tool" && $0.text == "token" })
    #expect(model.messages.contains { $0.role == "assistant" && $0.text == "done" })
    #expect(model.failure == nil)
    let types = await collected.value
    #expect(types.contains(EventType.effectIntent))
    #expect(types.contains(EventType.effectResult))
    #expect(types.contains(EventType.runCompleted))
    await model.close()
}

@Test @MainActor func conversationModelSuspendsThenApproves() async throws {
    let store = InMemoryEventStore()
    let ran = KitRecorder()
    let model = try await ConversationModel.open(
        store: store,
        tools: [
            Tool(name: "scheduleClosing", effect: .idempotent, summary: "book") { _, context in
                await ran.add(context)
                return ToolReturn(output: .string("booked"))
            },
        ],
        model: ScriptedModelStep(steps: [
            .approval(id: "closing", prompt: "Approve scheduling this closing?"),
            .tool(name: "scheduleClosing", callID: "c1", arguments: .object(["when": .string("Friday")])),
            .finish("Scheduled."),
        ]),
        backendLabel: "script"
    )
    try await model.send("Schedule Friday's closing")
    #expect(model.status == .suspendedForApproval)
    let pending = try #require(model.pendingApproval)
    #expect(pending.approvalID == "closing")
    #expect(pending.prompt == "Approve scheduling this closing?")
    try await model.approve()
    #expect(model.status == .done)
    #expect(model.pendingApproval == nil)
    #expect(model.messages.contains { $0.text == "Scheduled." })
    let calls = await ran.calls
    #expect(calls.count == 1)
    await model.close()
}

@Test @MainActor func conversationModelRejectsAnApproval() async throws {
    let store = InMemoryEventStore()
    let model = try await ConversationModel.open(
        store: store,
        tools: [],
        model: ScriptedModelStep(steps: [
            .approval(id: "closing", prompt: "Approve?"),
            .finish("nope"),
        ]),
        backendLabel: "script"
    )
    try await model.send("Schedule")
    try await model.reject("not this week")
    #expect(model.status == .failed)
    #expect(model.failure?.contains("not this week") == true)
    #expect(model.pendingApproval == nil)
    await model.close()
}

@Test @MainActor func conversationModelRecoversAnExternalEffectOnce() async throws {
    let store = InMemoryEventStore()
    let once = KitOnce()
    let recorder = KitRecorder()
    let tools = [
        Tool(name: "sendEmail", effect: .external, summary: "mail", reconcile: { _, _ in
            .done(.string("sent to buyer@example.com"))
        }) { _, context in
            await recorder.add(context)
            if await once.consume() {
                throw SimulatedProcessCrash()
            }
            return ToolReturn(output: .string("sent to buyer@example.com"))
        },
    ]
    let script = ScriptedModelStep(steps: [
        .tool(name: "sendEmail", callID: "c1", arguments: .string("hi")),
        .finish("Email handed to the outbox."),
    ])
    let first = try await ConversationModel.open(
        store: store,
        tools: tools,
        model: script,
        backendLabel: "script"
    )
    do {
        try await first.send("Send the buyer an email")
        Issue.record("expected a simulated crash")
    } catch is SimulatedProcessCrash {
    }
    await first.close()

    let second = try await ConversationModel.open(
        store: store,
        tools: tools,
        model: script,
        backendLabel: "script"
    )
    #expect(second.status == .done)
    #expect(second.messages.contains { $0.text == "Email handed to the outbox." })
    #expect(second.messages.contains { $0.text == "sent to buyer@example.com" })
    let calls = await recorder.calls
    #expect(calls.count == 1)
    #expect(second.events.contains { $0.type == EventType.effectResult && $0.payload["reconciled"]?.boolValue == true })
    await second.close()
}

@Test @MainActor func escrowScriptedModelLooksUpThenDescribesTheRecord() async throws {
    let store = InMemoryEventStore()
    let model = try await ConversationModel.open(
        store: store,
        tools: [
            Tool(name: "lookupProperty", effect: .pure, summary: "Look up a property.") { _, _ in
                ToolReturn(output: .object([
                    "address": .string("14 Harbor Lane"),
                    "parcel": .string("P-1044"),
                    "status": .string("in escrow"),
                ]))
            },
        ],
        model: EscrowScriptedModel(),
        backendLabel: "escrow script"
    )
    try await model.send("Look up 14 Harbor Lane")
    #expect(model.status == .done)
    #expect(model.messages.contains { $0.text == "14 Harbor Lane (P-1044) is in escrow." })
    await model.close()
}

@Test @MainActor func escrowScriptedModelAsksBeforeScheduling() async throws {
    let store = InMemoryEventStore()
    let model = try await ConversationModel.open(
        store: store,
        tools: [
            Tool(name: "scheduleClosing", effect: .idempotent, summary: "Book a closing.") { input, _ in
                ToolReturn(output: .object([
                    "when": input["when"] ?? .string(""),
                    "address": input["address"] ?? .string(""),
                    "status": .string("scheduled"),
                ]))
            },
        ],
        model: EscrowScriptedModel(),
        backendLabel: "escrow script"
    )
    try await model.send("Schedule Friday's closing")
    #expect(model.status == .suspendedForApproval)
    #expect(model.pendingApproval?.approvalID == EscrowScriptedModel.closingApprovalID)
    #expect(model.pendingApproval?.risk == .high)
    await #expect(throws: DurableError.self) {
        try await model.approve()
    }
    try await model.approve(as: Approver(id: "tester", authLevel: .biometric))
    #expect(model.status == .done)
    #expect(model.messages.contains { $0.role == "assistant" && $0.text.contains("14 Harbor Lane") })
    await model.close()
}

@Test @MainActor func emptySendIsRejected() async throws {
    let store = InMemoryEventStore()
    let model = try await ConversationModel.open(
        store: store,
        tools: [],
        model: ScriptedModelStep(steps: [.finish("x")]),
        backendLabel: "script"
    )
    await #expect(throws: DurableError.self) {
        try await model.send("   ")
    }
    #expect(model.status == .idle)
    await model.close()
}
