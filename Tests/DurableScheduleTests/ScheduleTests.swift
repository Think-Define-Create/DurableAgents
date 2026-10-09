import DurableCore
import DurableSchedule
import DurableStore
import Foundation
import Testing

@Test func phoenixAndNewYorkKeepSevenLocalAcrossDST() throws {
    let phoenix = try #require(TimeZone(identifier: "America/Phoenix"))
    let newYork = try #require(TimeZone(identifier: "America/New_York"))
    let winter = try localDate(year: 2026, month: 1, day: 15, hour: 7, zone: phoenix)
    let summer = try localDate(year: 2026, month: 7, day: 15, hour: 7, zone: phoenix)
    #expect(Cron.matches("0 7 * * *", at: winter, timeZone: phoenix))
    #expect(Cron.matches("0 7 * * *", at: summer, timeZone: phoenix))
    #expect(utcHour(winter) == 14)
    #expect(utcHour(summer) == 14)

    let january = try localDate(year: 2026, month: 1, day: 15, hour: 7, zone: newYork)
    let july = try localDate(year: 2026, month: 7, day: 15, hour: 7, zone: newYork)
    #expect(Cron.matches("0 7 * * *", at: january, timeZone: newYork))
    #expect(Cron.matches("0 7 * * *", at: july, timeZone: newYork))
    #expect(utcHour(january) == 12)
    #expect(utcHour(july) == 11)
    let next = try #require(Cron.next(after: january, expression: "0 7 * * *", timeZone: newYork))
    #expect(utcHour(next) == 12)
}

@Test func quietHoursFollowTheActiveWindow() throws {
    let quiet = QuietHours(activeStart: "09:00", activeEnd: "17:00", timeZone: "UTC")
    let zone = try #require(TimeZone(identifier: "UTC"))
    #expect(!quiet.isActive(at: try localDate(year: 2026, month: 1, day: 1, hour: 8, minute: 59, zone: zone)))
    #expect(quiet.isActive(at: try localDate(year: 2026, month: 1, day: 1, hour: 9, zone: zone)))
    #expect(!quiet.isActive(at: try localDate(year: 2026, month: 1, day: 1, hour: 17, zone: zone)))
    let overnight = QuietHours(activeStart: "22:00", activeEnd: "07:00", timeZone: "UTC")
    #expect(overnight.isActive(at: try localDate(year: 2026, month: 1, day: 1, hour: 23, zone: zone)))
    #expect(!overnight.isActive(at: try localDate(year: 2026, month: 1, day: 1, hour: 12, zone: zone)))
}

@Test func jitterDelaysTheSlotUntilTheShiftedInstant() async throws {
    let clock = ManualClock()
    align(clock, to: 60)
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let engine = try await Engine(
        store: store,
        tools: [HeartbeatTool.make()],
        model: reply(.noReply),
        clock: clock,
        leaseTTL: .seconds(3600)
    )
    let scheduler = Scheduler(engine: engine, store: store, clock: clock, jitter: FixedJitter(value: 1))
    try await scheduler.define(Routine(
        id: RoutineID("beat"),
        agentID: "agent",
        cadence: .every(.seconds(60), jitter: 0.5),
        checklist: "look"
    ))
    let early = try await scheduler.tick()
    #expect(early.isEmpty)
    clock.advance(by: 30)
    let fired = try await scheduler.tick()
    #expect(fired.count == 1)
    #expect(fired[0].outcome == HeartbeatOutcome.noReply)
    await engine.close()
}

@Test func silentAckDoesNotNotifyAndAReportDoes() async throws {
    let silent = DeterministicWakeScheduler()
    let silentHarness = try await open(model: reply(.noReply), wake: silent)
    try await silentHarness.scheduler.define(routine("silent"))
    let quiet = try await silentHarness.scheduler.tick()
    #expect(quiet.first?.outcome == HeartbeatOutcome.noReply)
    #expect(await silent.notifications.isEmpty)

    let loud = DeterministicWakeScheduler()
    let loudHarness = try await open(model: reply(.notify(text: "Ship it", dedupeKey: "ship")), wake: loud)
    try await loudHarness.scheduler.define(routine("loud"))
    let told = try await loudHarness.scheduler.tick()
    #expect(told.first?.outcome == .notify(text: "Ship it", dedupeKey: "ship"))
    let notes = await loud.notifications
    #expect(notes.count == 1)
    #expect(notes[0].dedupeKey == "ship")
    await silentHarness.engine.close()
    await loudHarness.engine.close()
}

@Test func checklistEditsAreJournaledAndASecondTickIsExactlyOnce() async throws {
    let harness = try await open(model: reply(.updateChecklist("next")))
    try await harness.scheduler.define(routine("edit"))
    let first = try await harness.scheduler.tick()
    #expect(first.first?.outcome == .updateChecklist("next"))
    let again = try await harness.scheduler.tick()
    #expect(again.isEmpty)
    let saved = try await harness.scheduler.routines()
    #expect(saved.first?.checklist == "next")
    let events = try await harness.store.readAll()
    #expect(events.filter { $0.type == EventType.routineFired }.count == 1)
    await harness.engine.close()
}

@Test func runLatestCatchesTheNewestSlotAndRecordsTheMissedOnes() async throws {
    let harness = try await open(model: reply(.noReply))
    align(harness.clock, to: 60)
    try await harness.scheduler.define(routine("latest", catchUp: .runLatest))
    _ = try await harness.scheduler.tick()
    harness.clock.advance(by: 180)
    let caught = try await harness.scheduler.tick()
    #expect(caught.filter { $0.outcome == HeartbeatOutcome.noReply }.count == 1)
    #expect(caught.filter { $0.skipped == "missed" }.count == 2)
    await harness.engine.close()
}

@Test func skipMissedDropsAGapAndRunAllIsCapped() async throws {
    let skipped = try await open(model: reply(.noReply))
    align(skipped.clock, to: 60)
    try await skipped.scheduler.define(routine("drop", catchUp: .skipMissed))
    _ = try await skipped.scheduler.tick()
    skipped.clock.advance(by: 180)
    let dropped = try await skipped.scheduler.tick()
    #expect(dropped.allSatisfy { $0.skipped == "missed" })
    #expect(dropped.count == 3)
    await skipped.engine.close()

    let all = try await open(model: reply(.noReply))
    align(all.clock, to: 60)
    try await all.scheduler.define(routine("all", catchUp: .runAll))
    _ = try await all.scheduler.tick()
    all.clock.advance(by: 60 * 10)
    let batch = try await all.scheduler.tick()
    #expect(batch.filter { $0.outcome == HeartbeatOutcome.noReply }.count == Scheduler.runAllCap)
    await all.engine.close()
}

@Test func quietHoursBusyChecklistAndBudgetAreSkipped() async throws {
    let clock = ManualClock()
    align(clock, to: 60)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let hour = calendar.component(.hour, from: clock.now())
    let quiet = QuietHours(
        activeStart: String(format: "%02d:00", (hour + 3) % 24),
        activeEnd: String(format: "%02d:00", (hour + 4) % 24),
        timeZone: "UTC"
    )
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let engine = try await Engine(
        store: store,
        tools: [HeartbeatTool.make()],
        model: reply(.noReply),
        clock: clock,
        leaseTTL: .seconds(3600)
    )
    let scheduler = Scheduler(engine: engine, store: store, clock: clock)
    try await scheduler.define(Routine(
        id: RoutineID("quiet"),
        agentID: "agent",
        cadence: .every(.seconds(60), jitter: 0),
        quiet: quiet,
        checklist: "look"
    ))
    let outside = try await scheduler.tick()
    #expect(outside.first?.skipped == "quiet-hours")

    let emptyStore = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let emptyEngine = try await Engine(store: emptyStore, model: reply(.noReply), clock: clock, leaseTTL: .seconds(3600))
    let emptyScheduler = Scheduler(engine: emptyEngine, store: emptyStore, clock: clock)
    try await emptyScheduler.define(Routine(
        id: RoutineID("empty"),
        agentID: "agent",
        cadence: .every(.seconds(60), jitter: 0),
        checklist: "   "
    ))
    let empty = try await emptyScheduler.tick()
    #expect(empty.first?.skipped == "empty-checklist")

    let busyStore = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let busyEngine = try await Engine(store: busyStore, model: reply(.noReply), clock: clock, leaseTTL: .seconds(3600))
    _ = try await busyEngine.submit(Submission(
        requestID: "hold",
        text: "hold",
        script: Script(steps: [.approval(id: "a1", prompt: "wait")])
    ))
    let busyScheduler = Scheduler(engine: busyEngine, store: busyStore, clock: clock)
    try await busyScheduler.define(Routine(
        id: RoutineID("busy"),
        agentID: "agent",
        cadence: .every(.seconds(60), jitter: 0),
        checklist: "look"
    ))
    let busy = try await busyScheduler.tick()
    #expect(busy.first?.skipped == "busy")

    let budgetStore = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let budgetEngine = try await Engine(store: budgetStore, model: reply(.noReply), clock: clock, leaseTTL: .seconds(3600))
    let budgetScheduler = Scheduler(engine: budgetEngine, store: budgetStore, clock: clock)
    try await budgetScheduler.define(Routine(
        id: RoutineID("budget"),
        agentID: "agent",
        cadence: .every(.seconds(60), jitter: 0),
        checklist: "look",
        budget: RunBudget(maxSteps: 0, onExceeded: .fail)
    ))
    let limited = try await budgetScheduler.tick()
    #expect(limited.first?.skipped == "budget")

    await engine.close()
    await emptyEngine.close()
    await busyEngine.close()
    await budgetEngine.close()
}

@Test func isolatedRunsDoNotShareAConversationAndLightContextIsInThePrompt() async throws {
    let harness = try await open(model: reply(.noReply))
    align(harness.clock, to: 60)
    try await harness.scheduler.define(Routine(
        id: RoutineID("iso"),
        agentID: "agent",
        cadence: .every(.seconds(60), jitter: 0),
        isolatedSession: true,
        lightContext: true,
        checklist: "look"
    ))
    let first = try await harness.scheduler.tick()
    harness.clock.advance(by: 60)
    let second = try await harness.scheduler.tick()
    let left = try #require(first.first?.conversationID)
    let right = try #require(second.first?.conversationID)
    #expect(left != right)
    let text = try await harness.engine.transcript(left).map(\.text).joined(separator: "\n")
    #expect(text.contains("Light context"))
    await harness.engine.close()
}

@Test func anEventInsideTheFloodWindowIsDropped() async throws {
    let harness = try await open(model: reply(.noReply))
    let stamp = harness.clock.now()
    try await harness.scheduler.define(Routine(
        id: RoutineID("event"),
        agentID: "agent",
        cadence: .onEvent("mail.arrived"),
        checklist: "look",
        skipWhenEmptyChecklist: false,
        minEventSpacing: .seconds(30)
    ))
    let first = try await harness.scheduler.tick(events: ["mail.arrived": stamp])
    #expect(first.first?.outcome == HeartbeatOutcome.noReply)
    let second = try await harness.scheduler.tick(events: ["mail.arrived": stamp.addingTimeInterval(10)])
    #expect(second.first?.skipped == "spacing")
    await harness.engine.close()
}

private struct FixedJitter: ScheduleJitter {
    var value: Double
    func unit(routine: RoutineID, slot: Date) -> Double { value }
}

private struct Opened {
    var store: InMemoryEventStore
    var clock: ManualClock
    var engine: Engine
    var scheduler: Scheduler
}

private func open(model: any ModelStep, wake: any WakeScheduler = NoOpWakeScheduler()) async throws -> Opened {
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let engine = try await Engine(
        store: store,
        tools: [HeartbeatTool.make()],
        model: model,
        clock: clock,
        leaseTTL: .seconds(3600)
    )
    let scheduler = Scheduler(engine: engine, store: store, clock: clock, wake: wake)
    return Opened(store: store, clock: clock, engine: engine, scheduler: scheduler)
}

private func routine(_ id: String, catchUp: CatchUpPolicy = .runLatest) -> Routine {
    Routine(
        id: RoutineID(id),
        agentID: "agent",
        cadence: .every(.seconds(60), jitter: 0),
        checklist: "look",
        catchUp: catchUp
    )
}

private enum SampleReply {
    case noReply
    case notify(text: String, dedupeKey: String)
    case updateChecklist(String)
}

private func reply(_ sample: SampleReply) -> ScriptedModelStep {
    let arguments: JSONValue
    switch sample {
    case .noReply:
        arguments = .object(["outcome": .string("noReply")])
    case .notify(let text, let dedupeKey):
        arguments = .object([
            "outcome": .string("notify"),
            "text": .string(text),
            "dedupeKey": .string(dedupeKey),
        ])
    case .updateChecklist(let checklist):
        arguments = .object([
            "outcome": .string("updateChecklist"),
            "checklist": .string(checklist),
        ])
    }
    return ScriptedModelStep(steps: [
        .tool(name: HeartbeatTool.name, callID: "h1", arguments: arguments),
        .finish("done"),
    ])
}

private func align(_ clock: ManualClock, to interval: TimeInterval) {
    let remainder = clock.now().timeIntervalSince1970.truncatingRemainder(dividingBy: interval)
    if remainder != 0 {
        clock.advance(by: interval - remainder)
    }
}

private func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0, zone: TimeZone) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    var parts = DateComponents()
    parts.year = year
    parts.month = month
    parts.day = day
    parts.hour = hour
    parts.minute = minute
    parts.second = 0
    return try #require(calendar.date(from: parts))
}

private func utcHour(_ date: Date) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.component(.hour, from: date)
}
