import DurableCore
import Foundation
import Testing

actor RecordingWebhook: WebhookTransport {
    private(set) var urls: [String] = []
    private(set) var bodies: [JSONValue] = []
    private(set) var headers: [[String: String]] = []

    func post(url: String, body: JSONValue, headers: [String: String]) {
        urls.append(url)
        bodies.append(body)
        self.headers.append(headers)
    }
}

actor NoticeBox {
    var notices: [ApprovalNotice] = []
    var drafts: [LocalNotificationDraft] = []
    var pushes: [JSONValue] = []

    func add(_ notice: ApprovalNotice) { notices.append(notice) }
    func addDraft(_ draft: LocalNotificationDraft) { drafts.append(draft) }
    func addPush(_ payload: JSONValue) { pushes.append(payload) }
}

@Test func highRiskApprovalRequiresAStrongerAuthenticatorAndRecordsWhoApproved() async throws {
    let harness = try makeHarness(.memory)
    let box = NoticeBox()
    let channel = MultiplexApprovalChannel(channels: [
        LocalNotificationChannel { draft in await box.addDraft(draft) },
        PushApprovalChannel { payload in await box.addPush(payload) },
        WebApprovalChannel(),
    ])
    let engine = try await Engine(
        store: harness.store,
        clock: harness.clock,
        approvals: channel,
        leaseTTL: .seconds(3600)
    )
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "Send the wire",
        script: Script(steps: [
            .approval(id: "wire-ok", prompt: "Send the wire?", risk: .high),
            .finish("sent"),
        ])
    ))
    #expect(result.runStatus == .suspended)
    let token = try #require(result.resumeToken)
    await #expect(throws: DurableError.approvalAuthTooWeak(required: "devicePasscode", actual: "session")) {
        try await engine.resume(token: token, decision: .approved)
    }
    let done = try await engine.resume(
        token: token,
        decision: .approved,
        approver: Approver(id: "ada", authLevel: .biometric)
    )
    #expect(done.runStatus == .completed)
    let events = try await harness.store.readAll()
    let resolved = try #require(events.last { $0.type == EventType.approvalResolved })
    #expect(resolved.payload["approver"]?.stringValue == "ada")
    #expect(resolved.payload["authLevel"]?.stringValue == "biometric")
    let exported = AuditExport.jsonl(events)
    #expect(exported.contains("ada"))
    #expect(exported.contains("Send the wire?") == false)
    let drafts = await box.drafts
    #expect(drafts.count == 1)
    #expect(drafts[0].title == "High-risk approval")
    #expect(drafts[0].category == LocalNotificationDraft.categoryIdentifier)
    let push = try #require(await box.pushes.first)
    #expect(push["aps"]?["alert"]?["body"]?.stringValue == "Send the wire?")
    #expect(push["aps"]?["category"]?.stringValue == LocalNotificationDraft.categoryIdentifier)
    #expect(push["token"]?.stringValue == token.raw)
    await engine.close()
}

@Test func expiredApprovalEscalatesOnceAndASecretHeaderStaysOutOfTheLog() async throws {
    let harness = try makeHarness(.sqlite)
    let transport = RecordingWebhook()
    let web = WebApprovalChannel()
    let secret = "Bearer sk-webhook-secret"
    let channel = MultiplexApprovalChannel(channels: [
        WebhookApprovalChannel(
            url: "https://hooks.example/approval",
            style: .slack,
            authorization: secret,
            transport: transport
        ),
        web,
    ])
    let engine = try await Engine(
        store: harness.store,
        clock: harness.clock,
        approvals: channel,
        leaseTTL: .seconds(3600)
    )
    let deadline = harness.clock.now().addingTimeInterval(30)
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "Hold the wire",
        script: Script(steps: [
            .approval(
                id: "wire-ok",
                prompt: "Still send it?",
                expiresAt: deadline,
                escalateTo: "counsel"
            ),
            .finish("sent"),
        ])
    ))
    #expect(result.runStatus == .suspended)
    #expect(await transport.headers.first?["Authorization"] == secret)
    #expect(await transport.bodies.first?["text"]?.stringValue == "Still send it?")
    harness.clock.advance(by: 31)
    let pumped = try await engine.pumpTimers()
    #expect(pumped.first?.runStatus == .suspended)
    #expect(pumped.first?.resumeToken?.approvalID == "wire-ok:escalated")
    let notices = await web.pending
    #expect(notices.count == 2)
    #expect(notices[1].audience == "counsel")
    harness.clock.advance(by: 10_000)
    let still = try await engine.pumpTimers()
    #expect(still.first?.runStatus == .suspended)
    let events = try await harness.store.readAll()
    let blob = events.map { $0.payload.canonicalJSON() }.joined(separator: "\n")
    #expect(blob.contains(secret) == false)
    #expect(blob.contains("sk-webhook-secret") == false)
    #expect(events.contains { $0.type == EventType.approvalEscalated })
    await engine.close()
}

@Test func approvalWithoutAnEscalationTargetFailsWhenItExpires() async throws {
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine()
    let deadline = harness.clock.now().addingTimeInterval(5)
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "wait",
        script: Script(steps: [
            .approval(id: "a1", prompt: "Now?", expiresAt: deadline),
            .finish("late"),
        ])
    ))
    #expect(result.runStatus == .suspended)
    harness.clock.advance(by: 6)
    let pumped = try await engine.pumpTimers()
    #expect(pumped.first?.runStatus == .failed)
    #expect(pumped.first?.failure == "approval expired")
    await engine.close()
}

@Test func appleApprovalFrameworksAreNotCompiledHere() {
    #expect(ApprovalAppleSupport.localAuthenticationCompiled == false)
    #expect(ApprovalAppleSupport.activityKitCompiled == false)
    #expect(ApprovalAppleSupport.userNotificationsCompiled == false)
}
