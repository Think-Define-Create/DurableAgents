#if DEBUG
import AgentAppCore
import Contacts
import DurableFoundationModels
import DurableIdentity
import EventKit
import Foundation

/// Debug-only end-to-end check. Launch with `-selftest` on a fresh install: it seeds a contact and
/// an event, sets a soul and a memory, talks to real bots, and writes `selftest.json` to Documents.
@MainActor
enum SelfTest {
    struct Step: Codable {
        var name: String
        var prompt: String
        var reply: String
        var tools: [String]
        var checks: [String: Bool]
        var seconds: Double
        var passed: Bool { checks.values.allSatisfy { $0 } }
    }

    struct Report: Codable {
        var startedAt: Date
        var onDeviceModel: String
        var steps: [Step] = []
        var notes: [String] = []
        var passed: Bool { steps.allSatisfy(\.passed) }
    }

    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains("-selftest")
    }

    static func run(_ model: AssistantModel) async {
        var report = Report(startedAt: Date(), onDeviceModel: availability())
        do {
            try await seed(&report)
        } catch {
            report.notes.append("seed failed: \(error)")
        }

        model.identityLayer = .soul
        model.identityDraft = "You are cheerful and brief. Always end every reply with the exact word Cheers!"
        await model.saveIdentity(asPerson: true)
        model.memoryDraft = "The person's favorite color is teal."
        await model.remember()
        await model.reload()

        guard let assistant = model.featured else {
            report.notes.append("no featured bot")
            write(report)
            return
        }
        let chef = await model.createBot(title: "Chef", look: BotLook(tint: 6, shape: 0), choice: .apple)
        await hostChecks(&report)
        for agent in [assistant] + (chef.map { [$0] } ?? []) {
            let started = Date()
            let context = await model.contextPreview(for: agent.id, message: "What is my favorite color?")
            append(&report, Step(
                name: "context for \(agent.title)",
                prompt: "What is my favorite color?",
                reply: context,
                tools: [],
                checks: [
                    "has soul": context.contains("Always end every reply with the exact word Cheers!"),
                    "has memory": context.contains("favorite color is teal"),
                    "has date": context.contains("Now: "),
                    "fits on-device window": context.count < 4_000,
                ],
                seconds: Date().timeIntervalSince(started)
            ))
        }
        guard report.onDeviceModel == "available", !ProcessInfo.processInfo.arguments.contains("-skipmodel") else {
            report.notes.append("model steps skipped")
            write(report)
            return
        }

        append(&report, await ask(model, assistant.id, name: "soul+memory", "What is my favorite color?") { reply, _ in
            ["mentions teal": reply.lowercased().contains("teal"), "soul says Cheers": reply.contains("Cheers")]
        })
        append(&report, await ask(model, assistant.id, name: "calendar", "What's on my calendar in the next 3 days?") { reply, tools in
            ["used calendar.read": tools.contains(BuiltinToolID.calendarRead), "mentions dentist": reply.lowercased().contains("dentist")]
        })
        append(&report, await ask(model, assistant.id, name: "contacts", "What is Testy McTestface's phone number?") { reply, tools in
            ["used contacts.search": tools.contains(BuiltinToolID.contactsSearch), "has number": reply.contains("555")]
        })
        append(&report, await askWithApproval(model, assistant.id))
        if let chef {
            append(&report, await ask(model, assistant.id, name: "bot-to-bot", "Ask Chef for one quick pasta idea and tell me what Chef said.") { reply, tools in
                ["used bots.ask": tools.contains(BotMessage.toolName), "has reply": !reply.isEmpty]
            })
            append(&report, await ask(model, assistant.id, name: "remember", "Please remember that my dog's name is Rex.") { _, tools in
                ["used memory.remember": tools.contains(MemoryTool.name)]
            })
            await model.reload()
            report.notes.append("memories: " + model.memories.map(\.text).joined(separator: " | "))
            append(&report, await ask(model, chef.id, name: "memory in other bot", "What is my dog's name?") { reply, _ in
                ["mentions Rex": reply.contains("Rex"), "soul says Cheers": reply.contains("Cheers")]
            })

            model.routineAgentID = chef.id
            model.routineID = "dinner"
            model.routineChecklist = "Suggest one dinner idea in one sentence."
            model.routineMinutes = 60
            let started = Date()
            await model.defineRoutine(askPermission: false)
            let result = model.routineResults["dinner"] ?? ""
            append(&report, Step(
                name: "routine",
                prompt: model.routineChecklist,
                reply: result,
                tools: [],
                checks: [
                    "routine saved": model.routines.contains { $0.id.rawValue == "dinner" && $0.agentID == chef.id },
                    "has result": !result.isEmpty && result != "Running…",
                ],
                seconds: Date().timeIntervalSince(started)
            ))
        }
        write(report)
    }

    private static func append(_ report: inout Report, _ step: Step) {
        report.steps.append(step)
        write(report)
    }

    private static func ask(
        _ model: AssistantModel,
        _ agentID: String,
        name: String,
        _ prompt: String,
        checks: (String, [String]) -> [String: Bool]
    ) async -> Step {
        let before = await model.toolsUsed(by: agentID).count
        let started = Date()
        await model.select(agentID)
        model.draft = prompt
        await model.send()
        let reply = model.messages.last { $0.role == "assistant" }?.text ?? model.banner
        let tools = Array(await model.toolsUsed(by: agentID).dropFirst(before))
        return Step(name: name, prompt: prompt, reply: reply, tools: tools, checks: checks(reply, tools), seconds: Date().timeIntervalSince(started))
    }

    /// Reminders wait for approval. The test approves, as a person would, then checks Reminders.
    private static func askWithApproval(_ model: AssistantModel, _ agentID: String) async -> Step {
        var step = await ask(model, agentID, name: "reminder", "Remind me to buy milk tomorrow at 9am.") { _, tools in
            ["asked for notes.reminder": tools.contains(BuiltinToolID.reminder)]
        }
        let started = Date()
        let pending = model.pendingApprovals(for: agentID)
        step.checks["waited for approval"] = !pending.isEmpty
        if let item = pending.first {
            await model.decide(token: item.token, approved: true, highRisk: false)
            step.reply += " / after approval: " + (model.messages.last { $0.role == "assistant" }?.text ?? model.banner)
        }
        let reminders = await allReminders()
        step.checks["reminder exists"] = reminders.contains { $0.title.lowercased().contains("milk") }
        step.seconds += Date().timeIntervalSince(started)
        return step
    }

    /// Calls the same host code the bots' tools run, against the simulator's real stores.
    private static func hostChecks(_ report: inout Report) async {
        let hosts = AppleToolHosts.make()
        let started = Date()
        var checks: [String: Bool] = [:]
        var lines: [String] = []
        do {
            let events = try await hosts.calendar.upcoming(days: 3, limit: 10)
            lines.append("calendar: " + events.map { "\($0.title) \($0.start.map { ToolDates.describe($0) } ?? "?")" }.joined(separator: "; "))
            checks["calendar.read sees the dentist event with a time"] = events.contains { $0.title == "Dentist appointment" && $0.start != nil }
        } catch {
            lines.append("calendar error: \(error)")
            checks["calendar.read sees the dentist event with a time"] = false
        }
        do {
            let found = try await hosts.contacts.search(name: "Testy")
            lines.append("contacts: " + found.joined(separator: "; "))
            checks["contacts.search returns the phone number"] = found.contains { $0.contains("555-0100") }
        } catch {
            lines.append("contacts error: \(error)")
            checks["contacts.search returns the phone number"] = false
        }
        let key = "selftest-\(UUID().uuidString)"
        let due = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(9 * 3600)
        do {
            let first = try await hosts.notes.upsertReminder(title: "Buy milk", due: due, effectKey: key)
            let again = try await hosts.notes.upsertReminder(title: "Buy milk", due: due, effectKey: key)
            let saved = await allReminders().filter { $0.notes == key }.map { ($0.title, $0.hour) }
            lines.append("reminders: \(saved)")
            checks["notes.reminder creates one reminder with a due time"] = saved.count == 1 && saved.first?.1 == 9
            checks["notes.reminder is idempotent on retry"] = first == again
        } catch {
            lines.append("reminders error: \(error)")
            checks["notes.reminder creates one reminder with a due time"] = false
        }
        do {
            let start = due.addingTimeInterval(6 * 3600)
            _ = try await hosts.calendar.upsert(title: "Lunch with Testy", start: start, minutes: 45, effectKey: key)
            let events = try await hosts.calendar.upcoming(days: 3, limit: 20)
            let lunch = events.first { $0.title == "Lunch with Testy" }
            lines.append("created: \(lunch.map { "\($0.title) \(ToolDates.describe($0.start!)) to \(ToolDates.describe($0.end!))" } ?? "missing")")
            checks["calendar.write uses the requested time and length"] = lunch?.start == start && lunch?.end == start.addingTimeInterval(45 * 60)
        } catch {
            lines.append("calendar write error: \(error)")
            checks["calendar.write uses the requested time and length"] = false
        }
        append(&report, Step(name: "device tools", prompt: "direct host calls", reply: lines.joined(separator: "\n"), tools: [], checks: checks, seconds: Date().timeIntervalSince(started)))
    }

    struct ReminderRow: Sendable {
        var title: String
        var notes: String?
        var hour: Int?
    }

    /// EventKit calls back on its own queue, so this must not be main-actor isolated.
    nonisolated private static func allReminders() async -> [ReminderRow] {
        let store = EKEventStore()
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: nil)) { @Sendable found in
                continuation.resume(returning: (found ?? []).map {
                    ReminderRow(title: $0.title ?? "", notes: $0.notes, hour: $0.dueDateComponents?.hour)
                })
            }
        }
    }

    private static func seed(_ report: inout Report) async throws {
        let contacts = CNContactStore()
        if try await contacts.requestAccess(for: .contacts) {
            let existing = try contacts.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: "McTestface"), keysToFetch: [])
            if existing.isEmpty {
                let contact = CNMutableContact()
                contact.givenName = "Testy"
                contact.familyName = "McTestface"
                contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "555-0100"))]
                let save = CNSaveRequest()
                save.add(contact, toContainerWithIdentifier: nil)
                try contacts.execute(save)
            }
        } else {
            report.notes.append("contacts access denied")
        }
        let events = EKEventStore()
        if try await events.requestFullAccessToEvents() {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
            let start = tomorrow.addingTimeInterval(10 * 3600)
            let window = events.predicateForEvents(withStart: tomorrow, end: tomorrow.addingTimeInterval(86_400), calendars: nil)
            if !events.events(matching: window).contains(where: { $0.title == "Dentist appointment" }),
               let calendar = events.defaultCalendarForNewEvents {
                let event = EKEvent(eventStore: events)
                event.title = "Dentist appointment"
                event.startDate = start
                event.endDate = start.addingTimeInterval(3600)
                event.calendar = calendar
                try events.save(event, span: .thisEvent)
            }
        } else {
            report.notes.append("calendar access denied")
        }
        if try await EKEventStore().requestFullAccessToReminders() == false {
            report.notes.append("reminders access denied")
        }
    }

    private static func availability() -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return FoundationModelsStep.unavailableReason() ?? "available"
        }
        #endif
        return "not compiled"
    }

    private static func write(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: documents.appendingPathComponent("selftest.json"), options: .atomic)
    }
}
#endif
