import DurableCore
import Foundation

/// Durable cron-like routines. `tick` is deterministic for a clock, a jitter function, and the journal.
/// It does not use a server, a push wake, or the store lease keep-alive.
public actor Scheduler {
    public static let runAllCap = 8

    private let engine: Engine
    private let store: any EventStore
    private let clock: any DurableClock
    private let jitter: any ScheduleJitter
    private let wake: any WakeScheduler

    public init(
        engine: Engine,
        store: any EventStore,
        clock: any DurableClock,
        jitter: any ScheduleJitter = ZeroScheduleJitter(),
        wake: any WakeScheduler = NoOpWakeScheduler()
    ) {
        self.engine = engine
        self.store = store
        self.clock = clock
        self.jitter = jitter
        self.wake = wake
    }

    public func define(_ routine: Routine) async throws {
        try validate(routine)
        try await engine.record([
            EventDraft(type: EventType.routineDefined, payload: routine.json(), recordedAt: clock.now()),
        ], stream: RoutineStream.id)
        if let when = try await nextWake() {
            await wake.scheduleWake(at: when, identifier: routine.id.rawValue)
        }
    }

    public func routines() async throws -> [Routine] {
        try await load().routines.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func tick(now: Date? = nil, events: [String: Date] = [:]) async throws -> [RoutineFiring] {
        let moment = now ?? clock.now()
        var state = try await load()
        var firings: [RoutineFiring] = []
        let active = try await activeRunCount()
        for routine in state.routines.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            let anchor = state.anchors[routine.id.rawValue] ?? moment
            let due = dueSlots(routine, now: moment, anchor: anchor, events: events)
            let pending = due.filter { !state.handled.contains(requestID(routine, slot: $0)) }
            let plan = plan(routine, due: pending)
            for slot in plan.skip {
                let firing = try await skip(routine, slot: slot, reason: "missed", moment: moment)
                state.handled.insert(firing.requestID)
                firings.append(firing)
            }
            for slot in plan.fire {
                if let reason = skipReason(
                    routine,
                    slot: slot,
                    now: moment,
                    active: active,
                    events: events,
                    lastFire: state.lastSlot[routine.id.rawValue]
                ) {
                    let firing = try await skip(routine, slot: slot, reason: reason, moment: moment)
                    state.handled.insert(firing.requestID)
                    firings.append(firing)
                    continue
                }
                let firing = try await fire(routine, slot: slot, state: state, moment: moment)
                state.handled.insert(firing.requestID)
                state.lastSlot[routine.id.rawValue] = slot
                if let id = firing.conversationID {
                    state.conversations[routine.id.rawValue] = id
                }
                if case .updateChecklist(let checklist) = firing.outcome {
                    var updated = routine
                    let clipped = String(checklist.prefix(Routine.checklistByteCap))
                    updated.checklist = clipped
                    try await engine.record([
                        EventDraft(type: EventType.routineDefined, payload: updated.json(), recordedAt: moment),
                    ], stream: RoutineStream.id)
                    state.routines[routine.id.rawValue] = updated
                }
                firings.append(firing)
            }
        }
        if let when = try await nextWake(now: moment) {
            await wake.scheduleWake(at: when, identifier: "routines")
        }
        return firings
    }

    public func nextWake(now: Date? = nil) async throws -> Date? {
        let moment = now ?? clock.now()
        let state = try await load()
        var best: Date?
        for routine in state.routines.values {
            guard let when = upcoming(routine, after: moment, anchor: state.anchors[routine.id.rawValue] ?? moment) else {
                continue
            }
            if best == nil || when < best! {
                best = when
            }
        }
        return best
    }

    private func validate(_ routine: Routine) throws {
        if routine.checklist.utf8.count > Routine.checklistByteCap {
            throw ScheduleError.checklistTooLarge(routine.checklist.utf8.count)
        }
        if let quiet = routine.quiet {
            guard TimeZone(identifier: quiet.timeZone) != nil else {
                throw ScheduleError.invalidTimeZone(quiet.timeZone)
            }
            guard QuietHours.minutes(quiet.activeStart) != nil, QuietHours.minutes(quiet.activeEnd) != nil else {
                throw ScheduleError.invalidQuietHours("\(quiet.activeStart)-\(quiet.activeEnd)")
            }
        }
        switch routine.cadence {
        case .every(let duration, let jitter):
            if duration <= .zero || jitter < 0 || jitter > 1 {
                throw ScheduleError.invalidRoutine
            }
        case .cron(let expression, let zone):
            try Cron.validate(expression, timeZone: zone)
        case .onEvent(let name):
            if name.isEmpty { throw ScheduleError.invalidRoutine }
        }
    }

    private struct SlotPlan {
        var fire: [Date]
        var skip: [Date]
    }

    private func plan(_ routine: Routine, due: [Date]) -> SlotPlan {
        guard !due.isEmpty else { return SlotPlan(fire: [], skip: []) }
        switch routine.catchUp {
        case .runLatest:
            return SlotPlan(fire: [due[due.count - 1]], skip: Array(due.dropLast()))
        case .skipMissed:
            if due.count <= 1 {
                return SlotPlan(fire: due, skip: [])
            }
            return SlotPlan(fire: [], skip: due)
        case .runAll:
            return SlotPlan(fire: Array(due.prefix(Self.runAllCap)), skip: [])
        }
    }

    private func dueSlots(_ routine: Routine, now: Date, anchor: Date, events: [String: Date]) -> [Date] {
        switch routine.cadence {
        case .every(let duration, let jitter):
            let interval = duration.timeInterval
            guard interval > 0 else { return [] }
            let firstIndex = Int(floor(anchor.timeIntervalSince1970 / interval))
            let lastIndex = Int(floor(now.timeIntervalSince1970 / interval))
            var slots: [Date] = []
            var index = firstIndex
            while index <= lastIndex && slots.count < 512 {
                let slot = Date(timeIntervalSince1970: Double(index) * interval)
                let dueAt = shifted(slot, routine: routine, interval: interval, jitter: jitter)
                if dueAt <= now && slot.addingTimeInterval(interval) > anchor {
                    slots.append(slot)
                }
                index += 1
            }
            return slots
        case .cron(let expression, let zoneName):
            guard let zone = TimeZone(identifier: zoneName) else { return [] }
            return Cron.previous(atOrBefore: now, expression: expression, timeZone: zone, days: 8).filter { $0 >= anchor }
        case .onEvent(let name):
            guard let stamp = events[name] else { return [] }
            return [stamp]
        }
    }

    private func shifted(_ slot: Date, routine: Routine, interval: TimeInterval, jitter: Double) -> Date {
        let unit = min(1, max(0, self.jitter.unit(routine: routine.id, slot: slot)))
        let offset = (unit * 2 - 1) * jitter * interval
        return slot.addingTimeInterval(offset)
    }

    private func skipReason(
        _ routine: Routine,
        slot: Date,
        now: Date,
        active: Int,
        events: [String: Date],
        lastFire: Date?
    ) -> String? {
        if let quiet = routine.quiet, !quiet.isActive(at: now) {
            return "quiet-hours"
        }
        if routine.skipWhenEmptyChecklist, routine.checklist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "empty-checklist"
        }
        if active >= routine.maxConcurrent {
            return "busy"
        }
        if case .onEvent = routine.cadence {
            if events[name(of: routine)] == nil {
                return "no-route"
            }
            if let lastFire, slot.timeIntervalSince(lastFire) < routine.minEventSpacing.timeInterval {
                return "spacing"
            }
        }
        return nil
    }

    private func name(of routine: Routine) -> String {
        if case .onEvent(let name) = routine.cadence { return name }
        return ""
    }

    private func skip(_ routine: Routine, slot: Date, reason: String, moment: Date) async throws -> RoutineFiring {
        let request = requestID(routine, slot: slot)
        try await engine.record([
            EventDraft(
                type: EventType.routineSkipped,
                payload: .object([
                    "routineID": .string(routine.id.rawValue),
                    "requestID": .string(request),
                    "slot": .double(slot.timeIntervalSince1970),
                    "reason": .string(reason),
                ]),
                recordedAt: moment
            ),
        ], stream: RoutineStream.id)
        return RoutineFiring(
            routineID: routine.id,
            requestID: request,
            slot: slot,
            skipped: reason,
            outcome: nil,
            conversationID: nil
        )
    }

    private func fire(_ routine: Routine, slot: Date, state: ScheduleState, moment: Date) async throws -> RoutineFiring {
        let request = requestID(routine, slot: slot)
        let existing = routine.isolatedSession ? nil : state.conversations[routine.id.rawValue]
        let result = try await engine.submitTurn(
            prompt(routine),
            requestID: request,
            to: existing,
            budget: routine.budget
        )
        if result.failure?.hasPrefix("budget exceeded") == true {
            _ = try await skip(routine, slot: slot, reason: "budget", moment: moment)
            return RoutineFiring(
                routineID: routine.id,
                requestID: request,
                slot: slot,
                skipped: "budget",
                outcome: nil,
                conversationID: result.conversationID
            )
        }
        let outcome = try await outcome(in: result.conversationID, fallback: result.finalText)
        try await engine.record([
            EventDraft(
                type: EventType.routineFired,
                payload: .object([
                    "routineID": .string(routine.id.rawValue),
                    "requestID": .string(request),
                    "slot": .double(slot.timeIntervalSince1970),
                    "conversationID": .string(result.conversationID.raw),
                    "outcome": outcome.json(),
                ]),
                recordedAt: moment
            ),
        ], stream: RoutineStream.id)
        if case .notify(let text, let dedupeKey) = outcome {
            await wake.notify(identifier: request, body: text, dedupeKey: dedupeKey)
        }
        return RoutineFiring(
            routineID: routine.id,
            requestID: request,
            slot: slot,
            skipped: nil,
            outcome: outcome,
            conversationID: result.conversationID
        )
    }

    private func outcome(in id: ConversationID, fallback: String?) async throws -> HeartbeatOutcome {
        let events = try await engine.events(for: id)
        var found: HeartbeatOutcome?
        for event in events where event.type == EventType.effectResult {
            guard let output = event.payload["output"], let name = output["outcome"]?.stringValue else { continue }
            switch name {
            case "noReply":
                found = .noReply
            case "notify":
                found = .notify(text: output["text"]?.stringValue ?? "", dedupeKey: output["dedupeKey"]?.stringValue ?? "heartbeat")
            case "updateChecklist":
                found = .updateChecklist(output["checklist"]?.stringValue ?? "")
            default:
                break
            }
        }
        if let found { return found }
        let text = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty || text == "NO_REPLY" {
            return .noReply
        }
        return .notify(text: text, dedupeKey: "heartbeat")
    }

    private func prompt(_ routine: Routine) -> String {
        var lines: [String] = []
        if routine.lightContext {
            lines.append("Light context. Skip bootstrap files.")
        }
        lines.append("Routine \(routine.id.rawValue) for \(routine.agentID).")
        lines.append("Checklist:")
        lines.append(routine.checklist)
        lines.append("Call heartbeat.respond. noReply means nothing to report.")
        return lines.joined(separator: "\n")
    }

    private func requestID(_ routine: Routine, slot: Date) -> String {
        "routine:\(routine.id.rawValue):\(Int(slot.timeIntervalSince1970.rounded()))"
    }

    private func upcoming(_ routine: Routine, after: Date, anchor: Date) -> Date? {
        switch routine.cadence {
        case .every(let duration, let jitter):
            let interval = duration.timeInterval
            guard interval > 0 else { return nil }
            var index = Int(floor(after.timeIntervalSince1970 / interval))
            for _ in 0..<8 {
                let slot = Date(timeIntervalSince1970: Double(index) * interval)
                let due = shifted(slot, routine: routine, interval: interval, jitter: jitter)
                if due > after && due >= anchor { return due }
                index += 1
            }
            return nil
        case .cron(let expression, let zoneName):
            guard let zone = TimeZone(identifier: zoneName) else { return nil }
            return Cron.next(after: after, expression: expression, timeZone: zone)
        case .onEvent:
            return nil
        }
    }

    private func activeRunCount() async throws -> Int {
        var count = 0
        for id in try await engine.listConversations() {
            let snap = try await engine.snapshot(id)
            if snap.run?.status == .running || snap.run?.status == .suspended {
                count += 1
            }
        }
        return count
    }

    private struct ScheduleState {
        var routines: [String: Routine] = [:]
        var anchors: [String: Date] = [:]
        var handled: Set<String> = []
        var conversations: [String: ConversationID] = [:]
        var lastSlot: [String: Date] = [:]
    }

    private func load() async throws -> ScheduleState {
        var state = ScheduleState()
        for event in try await store.readAll() {
            switch event.type {
            case EventType.routineDefined:
                let routine = try Routine.parse(event.payload)
                if state.anchors[routine.id.rawValue] == nil {
                    state.anchors[routine.id.rawValue] = event.recordedAt
                }
                state.routines[routine.id.rawValue] = routine
            case EventType.routineFired, EventType.routineSkipped:
                if let request = event.payload["requestID"]?.stringValue {
                    state.handled.insert(request)
                }
                if event.type == EventType.routineFired,
                   let id = event.payload["routineID"]?.stringValue,
                   let conversation = event.payload["conversationID"]?.stringValue
                {
                    state.conversations[id] = ConversationID(raw: conversation)
                }
                if event.type == EventType.routineFired,
                   let id = event.payload["routineID"]?.stringValue,
                   let raw = event.payload["slot"]
                {
                    let stamp = Date(timeIntervalSince1970: (try? ScheduleNumbers.double(raw)) ?? 0)
                    if state.lastSlot[id] == nil || stamp > state.lastSlot[id]! {
                        state.lastSlot[id] = stamp
                    }
                }
            default:
                break
            }
        }
        return state
    }
}
