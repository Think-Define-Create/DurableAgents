import DurableCore
import DurableMCP
import DurableSecurity
import Foundation
import ModelKit

public struct SendOutcome: Sendable, Equatable {
    public var conversationID: String
    public var runStatus: String?
    public var finalText: String?
    public var failure: String?
    public var resumeToken: String?

    public init(conversationID: String, runStatus: String?, finalText: String?, failure: String?, resumeToken: String?) {
        self.conversationID = conversationID
        self.runStatus = runStatus
        self.finalText = finalText
        self.failure = failure
        self.resumeToken = resumeToken
    }
}

/// Everything a screen refresh needs, built from one read of the log.
public struct SessionOverview: Sendable, Equatable {
    public var inbox: [InboxItem]
    public var messages: [TranscriptMessage]
    public var events: [RunEvent]
    public var usage: UsageSummary?
    public var runningAgents: Int

    public var widget: WidgetSnapshot {
        WidgetSnapshot(pendingApprovals: inbox.count, runningAgents: runningAgents, prompts: inbox.map(\.prompt))
    }
}

/// One engine for every agent in the store. Tools and the model do not call back into this actor.
public actor AgentSession {
    private let store: any EventStore
    private let directoryURL: URL
    private let hosts: ToolHosts
    private let keys: (any ConversationKeyProvider)?
    private var directory: AgentDirectory
    private var engine: Engine
    private let mailbox: WebApprovalChannel
    private let table: ProviderTable
    private let policy: PolicyBox
    private let transcript: LiveTranscript
    private let secrets: any SecretStore
    private let modelOverride: (any ModelStep)?
    private let routing: RoutingModelStep
    private var extraTools: [Tool] = []
    private var mcpServer: DurableMCPServer?
    private var loopback: MCPLoopbackServer?
    public private(set) var mcpPort: Int?
    public private(set) var lastRecovery: [RecoveryAction] = []

    public var didRecover: Bool { !lastRecovery.isEmpty }

    public static func open(
        store: any EventStore,
        directoryURL: URL,
        hosts: ToolHosts = .memory(),
        secrets: any SecretStore = MemorySecretStore(),
        keys: (any ConversationKeyProvider)? = nil,
        model: (any ModelStep)? = nil,
        foundationModelsLinked: Bool = false,
        apple: (@Sendable (ProviderChoice) -> (any ModelProvider)?)? = nil
    ) async throws -> AgentSession {
        let directory = try AgentDirectory.load(from: directoryURL)
        return try await AgentSession(
            store: store,
            directoryURL: directoryURL,
            directory: directory,
            hosts: hosts,
            secrets: secrets,
            keys: keys,
            model: model,
            foundationModelsLinked: foundationModelsLinked,
            apple: apple
        )
    }

    private init(
        store: any EventStore,
        directoryURL: URL,
        directory: AgentDirectory,
        hosts: ToolHosts,
        secrets: any SecretStore,
        keys: (any ConversationKeyProvider)?,
        model: (any ModelStep)?,
        foundationModelsLinked: Bool,
        apple: (@Sendable (ProviderChoice) -> (any ModelProvider)?)?
    ) async throws {
        self.store = store
        self.directoryURL = directoryURL
        self.directory = directory
        self.hosts = hosts
        self.secrets = secrets
        self.keys = keys
        self.modelOverride = model
        let policy = PolicyBox(onDeviceOnly: directory.settings.onDeviceOnly)
        self.policy = policy
        let table = ProviderTable()
        self.table = table
        let transcript = LiveTranscript()
        self.transcript = transcript
        let mailbox = WebApprovalChannel()
        self.mailbox = mailbox
        self.routing = RoutingModelStep(
            table: table,
            policy: policy,
            secrets: secrets,
            transcript: transcript,
            foundationModelsLinked: foundationModelsLinked,
            apple: apple
        )
        for agent in directory.agents {
            if let conversationID = agent.conversationID {
                await table.bind(conversationID, agent.provider)
            }
        }
        self.engine = try await Self.makeEngine(
            store: store,
            hosts: hosts,
            policy: policy,
            allowlist: WebAllowlist(hosts: directory.settings.webAllowHosts),
            extra: [],
            mailbox: mailbox,
            model: model ?? routing
        )
        self.lastRecovery = try await engine.recover()
    }

    public func agents(includeArchived: Bool = false) -> [AgentProfile] {
        directory.agents.filter { includeArchived || !$0.archived }
    }

    public func settings() -> AppSettings {
        directory.settings
    }

    public func create(title: String, provider: ProviderChoice = .demo) throws -> AgentProfile {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw AgentError.emptyTitle }
        let profile = AgentProfile(
            id: "agent_" + UUID().uuidString.lowercased(),
            title: trimmed,
            provider: provider
        )
        directory.upsert(profile)
        try directory.save(to: directoryURL)
        return profile
    }

    public func archive(_ id: String) throws {
        guard var profile = directory.agent(id) else { throw AgentError.missingAgent }
        profile.archived = true
        directory.upsert(profile)
        try directory.save(to: directoryURL)
    }

    public func fork(_ id: String) async throws -> AgentProfile {
        guard let source = directory.agent(id) else { throw AgentError.missingAgent }
        var copy = AgentProfile(
            id: "agent_" + UUID().uuidString.lowercased(),
            title: source.title + " copy",
            provider: source.provider,
            forkedFrom: source.id
        )
        if let raw = source.conversationID {
            let forked = try await engine.fork(ConversationID(raw: raw))
            copy.conversationID = forked.raw
            await table.bind(forked.raw, source.provider)
        }
        directory.upsert(copy)
        try directory.save(to: directoryURL)
        return copy
    }

    public func setProvider(_ id: String, _ choice: ProviderChoice) async throws {
        guard var profile = directory.agent(id) else { throw AgentError.missingAgent }
        profile.provider = choice
        directory.upsert(profile)
        try directory.save(to: directoryURL)
        if let conversationID = profile.conversationID {
            await table.bind(conversationID, choice)
        }
    }

    public func send(_ id: String, text: String) async throws -> SendOutcome {
        guard var profile = directory.agent(id) else { throw AgentError.missingAgent }
        if profile.archived { throw AgentError.archived }
        await table.prepare(profile.provider)
        let existing = profile.conversationID.map { ConversationID(raw: $0) }
        await transcript.beginTurn(conversationID: profile.conversationID)
        let requestID = "req_" + UUID().uuidString.lowercased()
        let result = try await engine.submitTurn(
            text,
            requestID: requestID,
            to: existing,
            budget: RoutingModelStep.turnBudget
        )
        if profile.conversationID == nil {
            profile.conversationID = result.conversationID.raw
            directory.upsert(profile)
            try directory.save(to: directoryURL)
        }
        await table.bind(result.conversationID.raw, profile.provider)
        return SendOutcome(
            conversationID: result.conversationID.raw,
            runStatus: result.runStatus?.rawValue,
            finalText: result.finalText,
            failure: result.failure,
            resumeToken: result.resumeToken?.raw
        )
    }

    public func transcript(for id: String) async throws -> [TranscriptMessage] {
        guard let raw = directory.agent(id)?.conversationID else { return [] }
        return try await engine.transcript(ConversationID(raw: raw))
    }

    public func liveTranscript() -> LiveTranscript { transcript }

    /// The engine that owns this store right now. `installMCPTools` and `shred` replace it.
    /// Do not keep the value inside a tool, and do not call the engine from a tool body.
    public func currentEngine() -> Engine { engine }

    public func liveText(for id: String) async -> String {
        guard let raw = directory.agent(id)?.conversationID else { return "" }
        return await transcript.snapshot(conversationID: raw)
    }

    public func snapshot(_ id: String) async throws -> ConversationSnapshot? {
        guard let raw = directory.agent(id)?.conversationID else { return nil }
        return try await engine.snapshot(ConversationID(raw: raw))
    }

    public func inbox(now: Date = Date()) async throws -> [InboxItem] {
        ApprovalInbox.pending(events: try await store.readAll(), agents: directory.agents, now: now)
    }

    public func decide(token: String, approved: Bool, approver: Approver, reason: String = "") async throws -> ResumeResult {
        guard let resume = ResumeToken(raw: token) else { throw AgentError.badToken }
        let decision: ApprovalDecision = approved ? .approved : .denied(reason.isEmpty ? "denied" : reason)
        return try await engine.resume(token: resume, decision: decision, approver: approver)
    }

    public func usage(for id: String) async throws -> UsageSummary {
        guard let profile = directory.agent(id), let raw = profile.conversationID else {
            return UsageSummary(inputTokens: 0, outputTokens: 0, estimatedUSD: 0, note: UsageLedger.note)
        }
        let events = try await store.read(stream: .conversation(ConversationID(raw: raw)))
        return UsageLedger.summarize(events: events, provider: profile.provider.kind)
    }

    public func events(for id: String) async throws -> [RunEvent] {
        guard let raw = directory.agent(id)?.conversationID else { return [] }
        return try await engine.events(for: ConversationID(raw: raw)).map { event in
            RunEvent(id: event.globalSeq, type: event.type, summary: event.type)
        }
    }

    public func exportAudit() async throws -> AuditBundle {
        let events = try await store.readAll()
        let report = EventHashChain.inspect(events)
        return AuditBundle(
            jsonl: AuditExport.jsonl(events),
            intact: report.intact,
            tip: report.tip,
            problems: report.problems
        )
    }

    public func setOnDeviceOnly(_ on: Bool) async throws {
        await policy.set(on)
        directory.settings.onDeviceOnly = on
        try directory.save(to: directoryURL)
        try await rebuild()
    }

    public func setAllowHosts(_ hosts: [String]) async throws {
        directory.settings.webAllowHosts = hosts
        try directory.save(to: directoryURL)
        try await rebuild()
    }

    public func updateSettings(_ settings: AppSettings) async throws {
        directory.settings = settings
        await policy.set(settings.onDeviceOnly)
        try directory.save(to: directoryURL)
        try await rebuild()
    }

    public func setHold(_ id: String, held: Bool) async throws {
        guard let raw = directory.agent(id)?.conversationID else { throw AgentError.noConversation }
        try await Retention.hold(
            store,
            fence: engine.currentFence(),
            stream: .conversation(ConversationID(raw: raw)),
            held: held
        )
    }

    public func purge(_ id: String, now: Date = Date()) async throws -> Int {
        guard let profile = directory.agent(id), let raw = profile.conversationID else {
            throw AgentError.noConversation
        }
        let days = directory.settings.retentionDays
        return try await Retention.purge(
            store,
            fence: engine.currentFence(),
            stream: .conversation(ConversationID(raw: raw)),
            policy: RetentionPolicy(
                maxAge: TimeInterval(days * 24 * 60 * 60),
                eventTypes: [EventType.messageAppended, EventType.stepPlanned]
            ),
            now: now
        )
    }

    /// Deletes the conversation key and drops the profile. Ciphertext remains and cannot be opened.
    public func shred(_ id: String) async throws {
        guard let profile = directory.agent(id) else { throw AgentError.missingAgent }
        let scope = profile.conversationID
        await stopMCP()
        await engine.close()
        if let scope, let keys {
            try await keys.shred(scope)
        }
        directory.agents.removeAll { $0.id == id }
        try directory.save(to: directoryURL)
        engine = try await Self.makeEngine(
            store: store,
            hosts: hosts,
            policy: policy,
            allowlist: WebAllowlist(hosts: directory.settings.webAllowHosts),
            extra: extraTools,
            mailbox: mailbox,
            model: modelOverride ?? routing
        )
        lastRecovery = try await engine.recover()
    }

    public func installMCPTools(
        config: MCPServerConfig,
        listed: [MCPListedTool],
        caller: any MCPToolCaller
    ) async throws -> Int {
        if await policy.onDeviceOnly, config.transport == "http" {
            throw AgentError.onDeviceBlocked
        }
        let tools = try MCPToolBridge.makeTools(config: config, listed: listed, caller: caller)
        extraTools.removeAll { tool in tool.name.hasPrefix("mcp.\(config.name).") }
        extraTools.append(contentsOf: tools)
        try await rebuild()
        return tools.count
    }

    public func connectMCP(_ config: MCPServerConfig) async throws -> Int {
        if await policy.onDeviceOnly, config.transport == "http" {
            throw AgentError.onDeviceBlocked
        }
        if config.transport == "stdio", !MCPPlatform.stdioAvailable {
            throw AgentError.stdioUnavailable
        }
        let client = try await MCPClientSession.connect(config, secrets: MCPSecretBridge(store: secrets))
        let listed = try await client.listTools()
        return try await installMCPTools(config: config, listed: listed, caller: client)
    }

    @discardableResult
    public func exposeMCP(_ enabled: Bool) async throws -> Int? {
        if !enabled {
            await stopMCP()
            return nil
        }
        guard MCPListenSupport.available else { throw AgentError.mcpListenUnavailable }
        await stopMCP()
        let server = DurableMCPServer(
            engine: engine,
            store: store,
            approverIDs: Set(directory.settings.mcpApproverIDs)
        )
        try await server.prepareHTTP()
        let loop = MCPLoopbackServer { request in
            await server.handleHTTP(request)
        }
        let port = try loop.start()
        mcpServer = server
        loopback = loop
        mcpPort = port
        return port
    }

    public func close() async {
        await stopMCP()
        await engine.close()
    }

    public func pumpTimers() async throws -> [RecoveryAction] {
        try await engine.pumpTimers()
    }

    public func signal(_ name: String) async throws -> RecoveryAction? {
        try await engine.signal(name)
    }

    public func writeWidgetSnapshot(to url: URL) async throws {
        try await overview(for: nil).widget.write(to: url)
    }

    /// Reads and decrypts the log once, then derives the inbox, the selected agent's
    /// transcript, events and usage, and the running count from that single read.
    public func overview(for id: String?, now: Date = Date()) async throws -> SessionOverview {
        let all = try await store.readAll()
        let snapshots = try ConversationSnapshot.all(from: all)
        var running = 0
        for agent in directory.agents where !agent.archived {
            guard let raw = agent.conversationID, let status = snapshots[raw]?.run?.status else { continue }
            if status == .running || status == .suspended {
                running += 1
            }
        }
        var overview = SessionOverview(
            inbox: ApprovalInbox.pending(events: all, agents: directory.agents, now: now),
            messages: [],
            events: [],
            usage: nil,
            runningAgents: running
        )
        guard let id, let profile = directory.agent(id) else {
            return overview
        }
        guard let raw = profile.conversationID else {
            overview.usage = UsageSummary(inputTokens: 0, outputTokens: 0, estimatedUSD: 0, note: UsageLedger.note)
            return overview
        }
        let stream = StreamID.conversation(ConversationID(raw: raw))
        let conversation = all.filter { $0.stream == stream }
        overview.messages = try conversation.compactMap { try EventCodec.transcriptMessage($0) }
        overview.events = conversation.map { RunEvent(id: $0.globalSeq, type: $0.type, summary: $0.type) }
        overview.usage = UsageLedger.summarize(events: conversation, provider: profile.provider.kind)
        return overview
    }

    public func redactionPatterns() -> [RedactionPattern] {
        directory.settings.extraRedaction.enumerated().map { index, regex in
            RedactionPattern(name: "custom-\(index)", regex: regex)
        }
    }

    private func rebuild() async throws {
        let port = mcpPort
        await stopMCP()
        await engine.close()
        engine = try await Self.makeEngine(
            store: store,
            hosts: hosts,
            policy: policy,
            allowlist: WebAllowlist(hosts: directory.settings.webAllowHosts),
            extra: extraTools,
            mailbox: mailbox,
            model: modelOverride ?? routing
        )
        lastRecovery = try await engine.recover()
        if port != nil {
            _ = try await exposeMCP(true)
        }
    }

    private func stopMCP() async {
        loopback?.stop()
        loopback = nil
        if let mcpServer {
            await mcpServer.stop()
        }
        mcpServer = nil
        mcpPort = nil
    }

    private static func makeEngine(
        store: any EventStore,
        hosts: ToolHosts,
        policy: PolicyBox,
        allowlist: WebAllowlist,
        extra: [Tool],
        mailbox: WebApprovalChannel,
        model: any ModelStep
    ) async throws -> Engine {
        let builtin = BuiltinTools.make(hosts: hosts, policy: policy, allowlist: allowlist)
        return try await Engine(
            store: store,
            tools: builtin + extra,
            model: model,
            retryPolicy: .standard,
            approvals: mailbox,
            leaseTTL: .seconds(86_400)
        )
    }
}
