import AgentAppCore
import DurableCore
import DurableMCP
import DurableSecurity
import DurableStore
import Foundation
import ModelKit
import Testing

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

@Test func createSendArchiveAndFork() async throws {
    let harness = try await Harness.open()
    let agent = try await harness.session.create(title: "Desk")
    let sent = try await harness.session.send(agent.id, text: "Hello")
    #expect(sent.finalText == "done")
    #expect(await harness.session.agents().count == 1)
    let copy = try await harness.session.fork(agent.id)
    #expect(copy.forkedFrom == agent.id)
    #expect(copy.conversationID != sent.conversationID)
    try await harness.session.archive(agent.id)
    #expect(await harness.session.agents().map(\.id) == [copy.id])
    #expect(await harness.session.agents(includeArchived: true).count == 2)
}

@Test func allowlistAndOnDeviceBlockNetwork() async throws {
    let allow = WebAllowlist(hosts: ["example.com", "127.0.0.1"])
    #expect(allow.allows(URL(string: "https://example.com/a")!))
    #expect(!allow.allows(URL(string: "http://example.com/a")!))
    #expect(allow.allows(URL(string: "http://127.0.0.1/a")!))
    #expect(!allow.allows(URL(string: "https://evil.test/a")!))

    let web = MemoryWebFetch()
    let hosts = ToolHosts(
        web: web,
        notes: MemoryNotes(),
        calendar: MemoryCalendar(),
        contacts: MemoryContacts(),
        documents: MemoryDocuments()
    )
    let policy = PolicyBox(onDeviceOnly: true)
    let tool = BuiltinTools.make(hosts: hosts, policy: policy, allowlist: allow).first { $0.name == BuiltinToolID.webFetch }!
    let output = try await tool.run(.object(["url": .string("https://example.com")]), EffectContext(
        key: EffectKey(raw: "fx"),
        conversationID: ConversationID(raw: "c"),
        callID: CallID("call"),
        attempt: 1,
        isReplay: false
    ))
    #expect(output.output["refused"]?.stringValue == "on-device only")
    #expect(await web.urls.isEmpty)
}

@Test func calendarReconcileIsDoneOnlyAfterWrite() async throws {
    let calendar = MemoryCalendar()
    let hosts = ToolHosts(
        web: MemoryWebFetch(),
        notes: MemoryNotes(),
        calendar: calendar,
        contacts: MemoryContacts(),
        documents: MemoryDocuments()
    )
    let tool = BuiltinTools.make(
        hosts: hosts,
        policy: PolicyBox(),
        allowlist: WebAllowlist()
    ).first { $0.name == BuiltinToolID.calendarWrite }!
    let key = EffectKey(raw: "fx:store:conv:call")
    let context = EffectContext(
        key: key,
        conversationID: ConversationID(raw: "conv"),
        callID: CallID("call"),
        attempt: 1,
        isReplay: false
    )
    let missing = try await tool.reconcile!(key, context)
    #expect(missing == .notDone)
    _ = try await tool.run(.object(["title": .string("Standup")]), context)
    let found = try await tool.reconcile!(key, context)
    #expect(found == .done(.object(["effectKey": .string(key.raw), "status": .string("exists")])))
    #expect(await calendar.events.count == 1)
}

@Test func approvalInboxAndHighRiskAuth() async throws {
    let step = ScriptedModelStep(steps: [
        .approval(ApprovalSpec(id: "gate", prompt: "Send the wire?", risk: .high)),
    ])
    let harness = try await Harness.open(model: step)
    let agent = try await harness.session.create(title: "Pay")
    let sent = try await harness.session.send(agent.id, text: "pay")
    #expect(sent.runStatus == RunStatus.suspended.rawValue)
    let inbox = try await harness.session.inbox()
    #expect(inbox.count == 1)
    #expect(inbox[0].risk == "high")
    #expect(inbox[0].prompt == "Send the wire?")
    do {
        _ = try await harness.session.decide(
            token: inbox[0].token,
            approved: true,
            approver: Approver(id: "local", authLevel: .session)
        )
        Issue.record("session auth should not satisfy a high-risk approval")
    } catch let error as DurableError {
        if case .approvalAuthTooWeak = error {
        } else {
            Issue.record("unexpected \(error)")
        }
    }
    let resumed = try await harness.session.decide(
        token: inbox[0].token,
        approved: true,
        approver: Approver(id: "local", authLevel: .devicePasscode)
    )
    #expect(resumed.runStatus == .completed)
    #expect(try await harness.session.inbox().isEmpty)
}

@Test func usageReadsPlannedTokens() async throws {
    let step = ScriptedModelStep(steps: [
        .providerTurn(ProviderTurnStep(text: "ok", calls: [], inputTokens: 20, outputTokens: 4, stopRaw: "end_turn")),
    ])
    let harness = try await Harness.open(model: step)
    let agent = try await harness.session.create(title: "Cost", provider: .anthropic())
    _ = try await harness.session.send(agent.id, text: "hi")
    let usage = try await harness.session.usage(for: agent.id)
    #expect(usage.inputTokens == 20)
    #expect(usage.outputTokens == 4)
    #expect(usage.estimatedUSD > 0)
    #expect(usage.note.contains("not a bill"))
}

@Test func recoverOnLaunchSurfacesSuspendedWork() async throws {
    let store = InMemoryEventStore(storeID: "recover")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = try await AgentSession.open(
        store: store,
        directoryURL: directory,
        model: ScriptedModelStep(steps: [.approval(id: "wait", prompt: "Continue?")])
    )
    let agent = try await first.create(title: "Resume")
    _ = try await first.send(agent.id, text: "go")
    await first.close()
    let second = try await AgentSession.open(
        store: store,
        directoryURL: directory,
        model: ScriptedModelStep(steps: [.approval(id: "wait", prompt: "Continue?")])
    )
    #expect(await second.didRecover)
}

@Test func shredDropsTheConversationAndKeepsTheStoreOpen() async throws {
    let inner = InMemoryEventStore(storeID: "shred-app")
    let keys = MemoryKeyProvider()
    let store = EncryptingEventStore(inner: inner, keys: keys, omitShredded: true)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let session = try await AgentSession.open(store: store, directoryURL: directory, keys: keys, model: ScriptedModelStep(steps: [.finish("kept")]))
    let keep = try await session.create(title: "Keep")
    let drop = try await session.create(title: "Drop")
    _ = try await session.send(keep.id, text: "stay")
    _ = try await session.send(drop.id, text: "secret words")
    try await session.shred(drop.id)
    #expect(await session.agents().map(\.title) == ["Keep"])
    let again = try await session.transcript(for: keep.id)
    #expect(again.contains { $0.text == "stay" })
}

@Test func demoStreamsWordsIntoTheTranscript() async throws {
    let transcript = LiveTranscript()
    let provider = PublishingProvider(
        inner: DemoChatProvider(),
        transcript: transcript,
        conversationID: "conv"
    )
    let turn = try await provider.complete(ModelRequest(
        model: "lumen-demo",
        messages: [ModelMessage(role: .user, text: "status")]
    ))
    #expect(turn.text.contains("status"))
    let live = await transcript.snapshot(conversationID: "conv")
    #expect(live == turn.text)
}

@Test func liveTextShowsOnlyTheCurrentTurn() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let session = try await AgentSession.open(
        store: InMemoryEventStore(storeID: "agent-" + UUID().uuidString),
        directoryURL: directory
    )
    let agent = try await session.create(title: "Desk")
    _ = try await session.send(agent.id, text: "first")
    let live = await session.liveTranscript()
    #expect(await live.latest().contains("first"))
    _ = try await session.send(agent.id, text: "second")
    let text = await live.latest()
    #expect(text.contains("second"))
    #expect(!text.contains("first"))
}

@Test func overviewMatchesTheSeparateReads() async throws {
    let harness = try await Harness.open(model: ScriptedModelStep(steps: [.approval(id: "pay", prompt: "Pay?")]))
    let session = harness.session
    let agent = try await session.create(title: "Desk")
    let idle = try await session.create(title: "Idle")
    _ = try await session.send(agent.id, text: "Hello")
    let overview = try await session.overview(for: agent.id)
    #expect(overview.messages == (try await session.transcript(for: agent.id)))
    #expect(overview.events == (try await session.events(for: agent.id)))
    #expect(overview.usage == (try await session.usage(for: agent.id)))
    #expect(overview.inbox == (try await session.inbox()))
    #expect(overview.inbox.count == 1)
    #expect(overview.runningAgents == 1)
    let empty = try await session.overview(for: idle.id)
    #expect(empty.messages.isEmpty)
    #expect(empty.usage == (try await session.usage(for: idle.id)))
}

@Test func approvedDemoReminderFinishesTheRun() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = InMemoryEventStore(storeID: "agent-" + UUID().uuidString)
    let session = try await AgentSession.open(store: store, directoryURL: directory)
    let agent = try await session.create(title: "Pay")
    _ = try await session.send(agent.id, text: "remind me to approve the wire")
    let item = try #require(try await session.inbox().first)
    let resumed = try await withThrowingTaskGroup(of: ResumeResult?.self) { group in
        group.addTask {
            try await session.decide(token: item.token, approved: true, approver: Approver(id: "local", authLevel: .session))
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
    let events = try await session.events(for: agent.id)
    let planned = events.filter { $0.type == EventType.stepPlanned }.count
    #expect(resumed != nil, "decide did not return within 5s; \(planned) steps planned")
    #expect(planned <= 3)
    #expect(events.last?.type == EventType.runCompleted)
}

@Test func routingStopsARunAtTheStepCap() async throws {
    let model = LoopingModel()
    let harness = try await Harness.open(model: model)
    let agent = try await harness.session.create(title: "Loop")
    let sent = try await harness.session.send(agent.id, text: "keep going")
    #expect(sent.runStatus == RunStatus.failed.rawValue)
    #expect(sent.failure == "budget exceeded: steps")
    #expect(model.plans == RoutingModelStep.maxStepsPerRun)
    let events = try await harness.session.events(for: agent.id)
    #expect(events.contains { $0.type == EventType.runBudgetExceeded })
}

@Test func onDeviceOnlyDoesNotBuildACloudProvider() async throws {
    let table = ProviderTable()
    let policy = PolicyBox(onDeviceOnly: true)
    let builds = ProviderBuildCounter()
    let step = RoutingModelStep(
        table: table,
        policy: policy,
        secrets: MemorySecretStore(),
        transcript: LiveTranscript(),
        builds: builds
    )
    await table.prepare(.openAI())
    let planned = try await step.plan(context: ModelContext(
        conversationID: ConversationID(raw: "cloud"),
        messages: [TranscriptMessage(messageID: "m", role: "user", text: "hi")],
        completedTools: [],
        grantedApprovalIDs: [],
        tools: [],
        completedSteps: 0
    ))
    guard case .finish(let text) = planned else {
        Issue.record("expected a finish")
        return
    }
    #expect(text.contains("On-device only"))
    #expect(builds.count == 0)
}

@Test func emptyMCPAllowlistAttachesNothing() async throws {
    let harness = try await Harness.open()
    let config = MCPServerConfig(name: "docs", transport: "http", url: "http://127.0.0.1:9", allow: [])
    let listed = [MCPListedTool(name: "search", summary: "search", inputSchemaJSON: "{}", hints: MCPToolHints())]
    let count = try await harness.session.installMCPTools(config: config, listed: listed, caller: SilentCaller())
    #expect(count == 0)
}

@Test func loopbackMCPRefusesGET() async throws {
    let harness = try await Harness.open()
    let port = try await harness.session.exposeMCP(true)
    #expect(port != nil)
    let status = try getStatus(port: port!)
    #expect(status == 405)
    _ = try await harness.session.exposeMCP(false)
}

@Test func widgetSnapshotCountsPendingApprovals() async throws {
    let harness = try await Harness.open(model: ScriptedModelStep(steps: [
        .approval(id: "n", prompt: "Look at this"),
    ]))
    let agent = try await harness.session.create(title: "Watch")
    _ = try await harness.session.send(agent.id, text: "go")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try await harness.session.writeWidgetSnapshot(to: url)
    let snapshot = try WidgetSnapshot.read(from: url)
    #expect(snapshot.pendingApprovals == 1)
    #expect(snapshot.prompts == ["Look at this"])
}

@Test func fileKeyShredSurvivesANewProvider() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = try FileKeyProvider(directory: directory)
    _ = try await keys.loadKey(for: "conv_a")
    try await keys.shred("conv_a")
    let reopened = try FileKeyProvider(directory: directory)
    do {
        _ = try await reopened.loadKey(for: "conv_a")
        Issue.record("shredded key should not be recreated")
    } catch let error as SecurityError {
        #expect(error == .shredded("conv_a"))
    }
}

private struct SilentCaller: MCPToolCaller {
    func callTool(name: String, arguments: JSONValue) async throws -> MCPToolOutput {
        MCPToolOutput(texts: [], isError: false)
    }
}

private func getStatus(port: Int) throws -> Int {
    #if canImport(Glibc)
    let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    let streamType = SOCK_STREAM
    #endif
    let fd = socket(AF_INET, streamType, 0)
    guard fd >= 0 else { throw AgentError.invalidURL }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
            connect(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        close(fd)
        throw AgentError.mcpListenUnavailable
    }
    let request = Data("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
    _ = request.withUnsafeBytes { raw in
        send(fd, raw.baseAddress, raw.count, 0)
    }
    var buffer = [UInt8](repeating: 0, count: 512)
    let count = buffer.withUnsafeMutableBytes { raw in
        recv(fd, raw.baseAddress, raw.count, 0)
    }
    close(fd)
    let text = String(decoding: buffer.prefix(max(0, count)), as: UTF8.self)
    let code = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    return Int(code) ?? 0
}

private final class LoopingModel: ModelStep, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var plans: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func plan(context: ModelContext) async throws -> ScriptedStep {
        record()
        return .assistant("loop")
    }

    private func record() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

private struct Harness {
    let session: AgentSession

    static func open(model: (any ModelStep)? = nil) async throws -> Harness {
        let store = InMemoryEventStore(storeID: "agent-" + UUID().uuidString)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = try await AgentSession.open(
            store: store,
            directoryURL: directory,
            model: model ?? ScriptedModelStep(steps: [.finish("done")])
        )
        return Harness(session: session)
    }
}
