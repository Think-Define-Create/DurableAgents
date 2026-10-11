#if canImport(FoundationModels)
import AgentAppCore
import DurableCore
import DurableFoundationModels
import DurableStore
import Foundation
import ModelKit
import Testing

/// Talks to the real on-device model. Opt in with `LIVE_FM=1 swift test --filter LiveOnDevice`.
/// Uses in-memory calendar, contacts and reminders, so nothing touches the Mac's own data.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIVE_FM"] == "1"), .serialized)
struct LiveOnDevice {
    @available(macOS 26, iOS 26, *)
    @Test func botsUseSoulMemoryToolsEachOtherAndRoutines() async throws {
        guard FoundationModelsSupport.isAvailable() else {
            Issue.record("on-device model unavailable: \(FoundationModelsSupport.unavailableReason() ?? "")")
            return
        }
        let store = InMemoryEventStore(storeID: "live-" + UUID().uuidString)
        let calendar = SeededCalendar()
        let notes = MemoryNotes()
        let remembered = Remembered()
        let hosts = ToolHosts(
            web: MemoryWebFetch(),
            notes: notes,
            calendar: calendar,
            contacts: MemoryContacts(names: ["Testy McTestface: 555-0100"]),
            documents: MemoryDocuments()
        )
        let memoryTool = Tool(
            name: "memory.remember",
            effect: .idempotent,
            summary: "Save one short fact about the person so every bot remembers it.",
            parametersJSON: #"{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}"#
        ) { arguments, _ in
            await remembered.add(arguments["fact"]?.stringValue ?? "")
            return ToolReturn(output: .object(["saved": .bool(true)]))
        }
        let heartbeat = Tool(
            name: "heartbeat.respond",
            effect: .pure,
            summary: "Say whether a routine has anything to report.",
            parametersJSON: #"{"type":"object","properties":{"outcome":{"type":"string","enum":["noReply","notify"]},"text":{"type":"string"}},"required":["outcome"]}"#
        ) { input, _ in
            ToolReturn(output: .object(["outcome": input["outcome"] ?? .null, "text": input["text"] ?? .null]))
        }
        let session = try await AgentSession.open(
            store: store,
            directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            hosts: hosts,
            foundationModelsLinked: true,
            apple: { _ in FoundationModelsProvider(instructions: "", bridgesRequestTools: true) },
            instructions: "You are a helpful personal assistant on the person's iPhone. Answer directly and briefly. Use tools when they help, and never invent a tool result. Never say you created, saved or set something unless a tool result in this conversation shows it.",
            context: { _ in
                let facts = await remembered.all.map { "- \($0)" }.joined(separator: "\n")
                return """
                Now: \(ToolDates.describe(Date())). Write times for tools as local time like 2026-10-11T15:00.

                Your soul (who you are and how you speak):
                You are cheerful and brief. Always end every reply with the exact word Cheers!

                What you remember about the person (saved memories):
                - The person's favorite color is teal.
                \(facts)

                Only when the person tells you a new fact worth keeping, call memory.remember with that one short fact.
                """
            },
            extraTools: [heartbeat, memoryTool]
        )
        let assistant = try await session.create(title: "Assistant", provider: .apple)
        let chef = try await session.create(title: "Chef", provider: .apple)

        func turn(_ agent: AgentProfile, _ text: String) async throws -> (reply: String, tools: [String], outcome: SendOutcome) {
            let before = try await tools(agent).count
            let started = Date()
            let outcome = try await session.send(agent.id, text: text)
            let used = Array(try await tools(agent).dropFirst(before))
            let reply = outcome.finalText ?? outcome.failure ?? "(\(outcome.runStatus ?? "no status"))"
            print("LIVE [\(agent.title)] \(text)\n  tools: \(used)\n  reply: \(reply)\n  \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            return (reply, used, outcome)
        }

        func tools(_ agent: AgentProfile) async throws -> [String] {
            guard let raw = await session.agents().first(where: { $0.id == agent.id })?.conversationID else { return [] }
            return try await store.read(stream: .conversation(ConversationID(raw: raw))).compactMap { event in
                switch event.type {
                case EventType.effectIntent: event.payload["tool"]?.stringValue
                case EventType.subagentStarted: event.payload["name"]?.stringValue
                case EventType.approvalRequested: "approval"
                default: nil
                }
            }
        }

        let color = try await turn(assistant, "What is my favorite color?")
        #expect(color.reply.lowercased().contains("teal"))
        #expect(color.reply.contains("Cheers"))

        let agenda = try await turn(assistant, "What's on my calendar in the next 3 days?")
        #expect(agenda.tools.contains("calendar.read"))
        #expect(agenda.reply.lowercased().contains("dentist"))
        if agenda.reply.hasPrefix("Error") { print("FULL", agenda.outcome.failure ?? "") }

        let phone = try await turn(assistant, "What is Testy McTestface's phone number?")
        #expect(phone.tools.contains("contacts.search"))
        #expect(phone.reply.contains("555"))

        let remind = try await turn(assistant, "Remind me to buy milk tomorrow at 9am.")
        #expect(remind.tools.contains("approval") || remind.tools.contains("notes.reminder"))
        if let token = remind.outcome.resumeToken {
            let resumed = try await session.decide(token: token, approved: true, approver: Approver(id: "test", authLevel: .session))
            print("LIVE reminder after approval: \(resumed)")
            let events = try await store.read(stream: .conversation(ConversationID(raw: remind.outcome.conversationID)))
            for event in events.suffix(14) { print("  EV", event.type, String(event.payload.canonicalJSON().prefix(220))) }
            #expect(await notes.byKey.count == 1)
        }

        let asked = try await turn(assistant, "Ask Chef for one quick pasta idea and tell me what Chef said.")
        #expect(asked.tools.contains("bots.ask"))
        let chefChat = try await session.transcript(for: chef.id)
        print("LIVE CHEF CHAT", chefChat.map { "\($0.role): \($0.text.prefix(80))" })
        #expect(chefChat.contains { BotMessage.decode($0.text)?.from == assistant.id })
        #expect(chefChat.last?.role == "assistant")

        let saved = try await turn(assistant, "Please remember that my dog's name is Rex.")
        #expect(saved.tools.contains("memory.remember"))
        #expect(await remembered.all.contains { $0.contains("Rex") })

        let dog = try await turn(chef, "What is my dog's name?")
        #expect(dog.reply.contains("Rex"))

        let routine = try await session.currentEngine().submitTurn(
            "Routine dinner for \(chef.id).\nChecklist:\nSuggest one dinner idea in one sentence.\nCall heartbeat.respond. noReply means nothing to report.",
            requestID: "routine-live",
            to: nil,
            budget: RoutingModelStep.turnBudget
        )
        let routineEvents = try await store.read(stream: .conversation(routine.conversationID))
        let heartbeats = routineEvents.filter { $0.type == EventType.effectIntent && $0.payload["tool"]?.stringValue == "heartbeat.respond" }
        print("LIVE routine: heartbeat calls \(heartbeats.count), final \(routine.finalText ?? routine.failure ?? "")")
        #expect(routine.failure == nil)
        #expect(!(routine.finalText ?? "").isEmpty)
        #expect(!(routine.finalText ?? "").contains("agent_"))
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIVE_FM"] == "1"), .serialized)
struct LiveOnDeviceContext {
    /// Earlier turns stay in the conversation, including after the app is closed and reopened.
    @available(macOS 26, iOS 26, *)
    @Test func conversationKeepsItsContextAcrossTurnsAndRelaunch() async throws {
        guard FoundationModelsSupport.isAvailable() else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("events.sqlite").path
        func open() async throws -> AgentSession {
            try await AgentSession.open(
                store: try SQLiteEventStore(path: path),
                directoryURL: folder,
                foundationModelsLinked: true,
                apple: { _ in FoundationModelsProvider(instructions: "", bridgesRequestTools: true) },
                instructions: "You are a helpful personal assistant. Answer directly and briefly."
            )
        }
        var session = try await open()
        let bot = try await session.create(title: "Assistant", provider: .apple)
        func say(_ text: String) async throws -> String {
            let reply = try await session.send(bot.id, text: text)
            let answer = reply.finalText ?? reply.failure ?? ""
            print("LIVE CONTEXT \(text)\n  reply: \(answer)")
            return answer
        }
        _ = try await say("I'm planning a trip to Lisbon in March with my sister Ana.")
        _ = try await say("What is one neighborhood worth staying in there?")
        _ = try await say("And what should I pack for that month?")
        let city = try await say("Which city did I say I'm visiting, and with whom?")
        #expect(city.contains("Lisbon"))
        #expect(city.contains("Ana"))

        await session.close()
        session = try await open()
        let after = try await say("After the restart: which city am I visiting?")
        #expect(after.contains("Lisbon"))
    }
}

private actor SeededCalendar: CalendarClient {
    private var events: [CalendarEventRecord]

    init() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        events = [CalendarEventRecord(
            title: "Dentist appointment",
            start: tomorrow.addingTimeInterval(10 * 3600),
            end: tomorrow.addingTimeInterval(11 * 3600)
        )]
    }

    func upcoming(limit: Int) async throws -> [CalendarEventRecord] { Array(events.prefix(limit)) }
    func upsert(title: String, effectKey: String) async throws -> String {
        events.append(CalendarEventRecord(title: title, effectKey: effectKey))
        return effectKey
    }
    func find(effectKey: String) async throws -> Bool { events.contains { $0.effectKey == effectKey } }
}

private actor Remembered {
    private(set) var all: [String] = []
    func add(_ fact: String) { all.append(fact) }
}
#endif
