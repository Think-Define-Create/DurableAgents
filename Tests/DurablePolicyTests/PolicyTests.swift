import DurableCore
import DurablePolicy
import DurableSchedule
import DurableStore
import Foundation
import Testing

@Test func quietHoursAndTheDailyCapAndDedupeAreJournaled() async throws {
    let clock = ManualClock()
    let quiet = QuietHours(activeStart: "09:00", activeEnd: "17:00", timeZone: "America/Phoenix")
    let policy = NotificationPolicy(quiet: quiet, dailyCap: 1)
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let engine = try await Engine(store: store, clock: clock, leaseTTL: .seconds(3600))
    let journal = PolicyJournal(notifications: policy, approvals: ApprovalPolicy(rules: []), engine: engine, store: store)

    let outside = clock.now().addingTimeInterval(3 * 60 * 60)
    let suppressed = try await journal.considerNotification(dedupeKey: "briefing", collapseID: "morning", now: outside)
    #expect(suppressed.deliver == false)
    #expect(suppressed.ruleID == "quiet-hours")
    #expect(suppressed.collapseID == "morning")

    let allowed = try await journal.considerNotification(dedupeKey: "briefing", collapseID: "morning", now: clock.now())
    #expect(allowed.deliver == true)
    #expect(allowed.ruleID == "allow")

    let capped = try await journal.considerNotification(dedupeKey: "other", collapseID: "stack", now: clock.now())
    #expect(capped.ruleID == "daily-cap")

    clock.advance(by: 86_400)
    let duplicate = try await journal.considerNotification(dedupeKey: "briefing", collapseID: "morning", now: clock.now())
    #expect(duplicate.ruleID == "dedupe")
    #expect(duplicate.disposition == "duplicate")

    let nextDay = try await journal.considerNotification(dedupeKey: "tomorrow", collapseID: "morning", now: clock.now())
    #expect(nextDay.deliver == true)

    let events = try await store.readAll().filter { $0.type == EventType.notificationDecided }
    #expect(events.count == 5)
    #expect(events.contains { $0.payload["ruleID"]?.stringValue == "quiet-hours" })
    _ = try await engine.recover()
    await engine.close()
}

@Test func unattendedModeNeverClearsAnExternalApproval() async throws {
    let clock = ManualClock()
    let window = QuietHours(activeStart: "09:00", activeEnd: "17:00", timeZone: "America/Phoenix")
    let policy = ApprovalPolicy(rules: [
        ApprovalRule(id: "allow-send", tool: "webhook.send", effect: .external, autoApprove: true),
        ApprovalRule(
            id: "daytime-read",
            tool: "files.read",
            effect: .pure,
            arguments: ["path": "/notes"],
            window: window,
            autoApprove: false
        ),
        ApprovalRule(id: "auto-pure", tool: "memory.search", effect: .pure, unattended: true, autoApprove: true),
    ])
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let engine = try await Engine(store: store, clock: clock, leaseTTL: .seconds(3600))
    let journal = PolicyJournal(
        notifications: NotificationPolicy(dailyCap: 3),
        approvals: policy,
        engine: engine,
        store: store
    )

    let blocked = try await journal.considerApproval(ApprovalSubject(
        tool: "webhook.send",
        effect: .external,
        toolRequiresApproval: false,
        unattended: true,
        now: clock.now()
    ))
    #expect(blocked.requiresApproval == true)
    #expect(blocked.ruleID == ApprovalPolicy.unattendedExternalRuleID)
    #expect(blocked.matchedRuleID == "allow-send")

    let attended = try await journal.considerApproval(ApprovalSubject(
        tool: "webhook.send",
        effect: .external,
        toolRequiresApproval: true,
        unattended: false,
        now: clock.now()
    ))
    #expect(attended.requiresApproval == false)
    #expect(attended.ruleID == "allow-send")

    let forced = try await journal.considerApproval(ApprovalSubject(
        tool: "files.read",
        effect: .pure,
        arguments: ["path": "/notes"],
        toolRequiresApproval: false,
        unattended: true,
        now: clock.now()
    ))
    #expect(forced.requiresApproval == true)
    #expect(forced.ruleID == "daytime-read")

    let outside = try await journal.considerApproval(ApprovalSubject(
        tool: "files.read",
        effect: .pure,
        arguments: ["path": "/notes"],
        toolRequiresApproval: false,
        unattended: true,
        now: clock.now().addingTimeInterval(3 * 60 * 60)
    ))
    #expect(outside.requiresApproval == false)
    #expect(outside.ruleID == "none")

    let cleared = try await journal.considerApproval(ApprovalSubject(
        tool: "memory.search",
        effect: .pure,
        toolRequiresApproval: true,
        unattended: true,
        now: clock.now()
    ))
    #expect(cleared.requiresApproval == false)
    #expect(cleared.ruleID == "auto-pure")

    let rows = try await store.readAll().filter { $0.type == EventType.approvalPolicy }
    #expect(rows.map { $0.payload["ruleID"]?.stringValue } == [
        "unattended-external", "allow-send", "daytime-read", "none", "auto-pure",
    ])
    _ = try await engine.recover()
    await engine.close()
}
