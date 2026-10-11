import AgentAppKit
import DurableCore
import DurableFoundationModels
import DurableIdentity
import DurableMCP
import DurableMemory
import DurablePolicy
import DurableRetrieval
import DurableSchedule
import DurableSecurity
import DurableSkills
import DurableStore
import Foundation
import ModelKit
import Observation

struct HostPolicy: Codable, Equatable, Sendable {
    var quietStart: String = "08:00"
    var quietEnd: String = "21:00"
    var timeZone: String = TimeZone.current.identifier
    var dailyCap: Int = 3
    var unattended: Bool = false
}

@MainActor
@Observable
final class AssistantModel {
    var phase: Phase = .loading
    var banner: String = ""
    var agents: [AgentProfile] = []
    var selectedID: String?
    var messages: [TranscriptMessage] = []
    var draft: String = ""
    var inbox: [InboxItem] = []
    var settings = AppSettings()
    var host = HostPolicy()
    var documents: [IdentityDocument] = []
    var identityProposals: [IdentityProposal] = []
    var identityLayer: IdentityLayer = .soul
    var identityDraft: String = ""
    var identityDiff: String = ""
    var skills: [SkillManifest] = []
    var skillProposals: [SkillProposal] = []
    var skillDraft: String = """
    ---
    name: notes
    description: Keep a short note.
    ---

    Keep a short note. Do not run scripts.
    """
    var memories: [MemoryRecord] = []
    var graphNodes: [MemoryEntity] = []
    var graphEdges: [MemoryEdge] = []
    var memoryQuery: String = ""
    var memoryDraft: String = ""
    var routines: [Routine] = []
    var nextWake: Date?
    var lastCatchUp: String = "No catch-up yet. Opening the app runs one."
    var routineID: String = "morning"
    var routineChecklist: String = "Summarize what is waiting, then stop."
    var routineMinutes: Int = 60
    var servers: [MCPServerConfig] = []
    var serverName: String = "notes"
    var serverURL: String = "http://127.0.0.1/mcp"
    var serverAllow: String = ""
    var previews: [String: AgentPreview] = [:]
    /// A bot to open, set by a Spotlight result. HomeView navigates and clears it.
    var openRequest: String?
    var looks: [String: BotLook] = [:]
    /// Bots replying right now. Each bot runs on its own, so another chat stays usable meanwhile.
    var sending: Set<String> = []
    /// Reply text so far, by bot.
    var liveTexts: [String: String] = [:]
    var isSending: Bool { selectedID.map(sending.contains) ?? false }
    var liveText: String { selectedID.flatMap { liveTexts[$0] } ?? "" }
    var savedKeys: Set<String> = []
    var connectedServers: Set<String> = []
    var catalog: [BotProvider: [RemoteModel]] = [:]
    var catalogError: [BotProvider: String] = [:]
    var catalogLoading: Set<BotProvider> = []
    var routineAgentID: String?
    var routineResults: [String: String] = [:]
    /// Messages the open bot sent to other bots, keyed by the reply's tool call id.
    var exchanges: [String: BotExchange] = [:]

    private var session: AgentSession?
    private var store: (any EventStore)?
    private var memory: MemoryIndex?
    private var supportURL: URL?
    /// Proposal ids with a decision in flight. A second tap must not journal a second resolution.
    private var deciding: Set<String> = []
    private var transcript: LiveTranscript?
    private var brain: BotBrain?
    private let secrets = AssistantKeychain(service: "dev.thinkdefinecreate.Assistant.secrets")
    private let clock = SystemDurableClock()

    /// Read-only handles for Settings → Diagnostics.
    var diagnosticsSession: AgentSession? { session }
    var diagnosticsSupportURL: URL? { supportURL }
    func diagnosticsSecret(_ account: String) async -> String? {
        try? await secrets.secret(for: NamedSecret(account: account))
    }

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    func bootstrap() async {
        if session != nil {
            await reload()
            return
        }
        do {
            let support = try supportDirectory()
            supportURL = support
            host = loadPolicy(from: support)
            servers = loadServers(from: support)
            let saved = try AgentDirectory.load(from: support)
            settings = saved.settings
            let sqlite = try SQLiteEventStore(path: support.appendingPathComponent("assistant.sqlite").path)
            let keys = SecureEnclaveKeyProvider(service: Self.keyService)
            // Wraps the plain keys from earlier builds with the Secure Enclave key, keeping their bytes.
            _ = try? await keys.wrapExistingKeys()
            let encrypted = EncryptingEventStore(
                inner: sqlite,
                keys: keys,
                redactor: BuiltInRedactor(extra: []),
                omitShredded: true
            )
            looks = loadLooks(from: support)
            let index = try MemoryIndex(path: support.appendingPathComponent("memory.sqlite").path, embedder: Embedders.fallback)
            // Apple's sentence model may need a download, so search starts on the hash fallback and
            // switches when the model is ready. The index re-embeds rows made by the old embedder.
            Task.detached { await index.use(await Embedders.preferred(requestAssets: true)) }
            let brain = BotBrain(memory: index)
            self.brain = brain
            memory = index
            let opened = try await AgentSession.open(
                store: encrypted,
                directoryURL: support,
                hosts: AppleToolHosts.make(),
                secrets: secrets,
                keys: keys,
                foundationModelsLinked: FoundationModelsSupport.compiledIn,
                apple: { choice in
                    #if canImport(FoundationModels)
                    if #available(iOS 26, macOS 26, *) {
                        return FoundationModelsProvider(
                            instructions: Self.instructions,
                            bridgesRequestTools: true,
                            privateCloud: choice.model == ProviderChoice.applePrivateCloud.model
                        )
                    }
                    #endif
                    return nil
                },
                instructions: Self.instructions,
                context: { turn in await brain.instructions(for: turn) },
                extraTools: [HeartbeatTool.make(), MemoryTool.make()]
            )
            session = opened
            store = encrypted
            transcript = await opened.liveTranscript()
            if await opened.agents().isEmpty {
                settings.onDeviceOnly = true
                settings.completedOnboarding = true
                try await opened.updateSettings(settings)
                let first = try await opened.create(title: "Assistant", provider: .apple)
                looks[first.id] = BotLook(tint: 0, shape: 3)
                try? saveLooks()
            }
            refreshSavedKeys()
            AssistantBackground.register()
            AssistantBackground.scheduleNext()
            await reload()
            await catchUp()
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func reload() async {
        guard let session, let supportURL else { return }
        do {
            let saved = try AgentDirectory.load(from: supportURL)
            settings = saved.settings
            agents = await session.agents()
            if let selectedID, !agents.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
            let overview = try await session.overview(for: selectedID)
            messages = overview.messages
            exchanges = overview.exchanges
            inbox = overview.inbox
            previews = overview.previews
            AssistantSpotlight.update(agents: agents, previews: previews)
        } catch {
            banner = String(describing: error)
        }
        await reloadIdentity()
        await reloadSkills()
        await reloadMemory()
        await reloadRoutines()
    }

    func select(_ id: String) async {
        selectedID = id
        await reload()
    }

    func send(_ typed: String? = nil) async {
        let text = (typed ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, let session, let agentID = selectedID else { return }
        if typed == nil { draft = "" }
        // Show the message right away; the journal copy replaces it on reload.
        messages.append(TranscriptMessage(messageID: "pending-\(UUID().uuidString)", role: "user", text: text))
        sending.insert(agentID)
        liveTexts[agentID] = ""
        let pump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let latest = await session.liveText(for: agentID)
                self?.liveTexts[agentID] = latest
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        let name = agents.first { $0.id == agentID }?.title ?? "Assistant"
        Trace.log("send \(name): start")
        let result = await ReplyKeepAlive.shared.run(title: "\(name) is replying", subtitle: String(text.prefix(60))) {
            Trace.log("send \(name): session.send")
            do {
                let outcome = try await session.send(agentID, text: text)
                Trace.log("send \(name): returned \(outcome.runStatus ?? "nil") failure=\(outcome.failure ?? "") text=\(outcome.finalText?.prefix(60) ?? "")")
                if AssistantModel.sandboxed {
                    let events = (try? await session.currentEngine().events(for: ConversationID(raw: outcome.conversationID))) ?? []
                    let turn = events.suffix(from: events.lastIndex { $0.type == "run.started" } ?? 0)
                    for event in turn where event.type == "effect.intent" || event.type == "effect.retry" || event.type == "subagent.started" {
                        Trace.log("  \(event.type) \(event.payload.canonicalJSON().prefix(300))")
                    }
                }
                if outcome.runStatus == "running" {
                    // A step failed and a retry is scheduled. Keep the typing dots until it lands.
                    return await Self.waitWhileRunning(session, agentID: agentID) ?? (outcome.failure ?? "")
                }
                return outcome.failure ?? ""
            } catch {
                Trace.log("send \(name): threw \(error)")
                return String(describing: error)
            }
        }
        Trace.log("send \(name): done")
        if selectedID == agentID || !result.isEmpty {
            banner = result.isEmpty ? "" : (selectedID == agentID ? result : "\(name): \(result)")
        }
        pump.cancel()
        sending.remove(agentID)
        liveTexts[agentID] = nil
        await reload()
    }

    /// Waits up to two minutes for a run that is between retries. Returns its failure, if it failed.
    private static func waitWhileRunning(_ session: AgentSession, agentID: String) async -> String? {
        for _ in 0..<240 {
            try? await Task.sleep(for: .milliseconds(500))
            guard let run = (try? await session.snapshot(agentID))?.run else { return nil }
            if run.status != .running {
                Trace.log("retry settled: \(run.status.rawValue)")
                return run.failure
            }
        }
        return "Still working on it. The reply will appear here when it is ready."
    }

    /// Puts text read from an attachment into the draft. The person still decides when to send.
    func attach(_ text: String, label: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            banner = "No text was found in that \(label)."
            return
        }
        let block = "[\(label)]\n\(trimmed)"
        draft = draft.isEmpty ? block : draft + "\n\n" + block
    }

    func look(for id: String) -> BotLook {
        looks[id] ?? BotLook.derived(from: id)
    }

    /// Bots in the order the home list shows them: most recent activity first.
    var sortedAgents: [AgentProfile] {
        agents.sorted { left, right in
            let l = previews[left.id]?.at ?? left.createdAt
            let r = previews[right.id]?.at ?? right.createdAt
            return l > r
        }
    }

    /// The first bot, shown large at the top of the home screen.
    var featured: AgentProfile? {
        agents.min { $0.createdAt < $1.createdAt }
    }

    func pendingApprovals(for id: String) -> [InboxItem] {
        inbox.filter { $0.agentID == id }
    }

    func createBot(title: String, look: BotLook, choice: ProviderChoice) async -> AgentProfile? {
        guard let session else { return nil }
        do {
            let agent = try await session.create(title: title, provider: choice)
            looks[agent.id] = look
            try saveLooks()
            try await allowCloud(for: choice)
            await reload()
            return agent
        } catch {
            banner = String(describing: error)
            return nil
        }
    }

    func setChoice(_ choice: ProviderChoice, for id: String) async {
        guard let session else { return }
        do {
            try await session.setProvider(id, choice)
            try await allowCloud(for: choice)
            await reload()
        } catch {
            banner = String(describing: error)
        }
    }

    /// A cloud bot needs the network, so choosing one turns off On-device only.
    private func allowCloud(for choice: ProviderChoice) async throws {
        guard let session, OnDevicePolicy.blocksCloud(choice), settings.onDeviceOnly else { return }
        settings.onDeviceOnly = false
        try await session.updateSettings(settings)
    }

    func setLook(_ look: BotLook, for id: String) {
        looks[id] = look
        try? saveLooks()
    }

    /// Hides the bot. Its journal stays, so an audit export still covers it.
    func archive(_ id: String) async {
        guard let session else { return }
        do {
            try await session.archive(id)
            if selectedID == id { selectedID = nil }
            await reload()
        } catch {
            banner = String(describing: error)
        }
    }

    func choice(for id: String) -> ProviderChoice {
        agents.first { $0.id == id }?.provider ?? .apple
    }

    /// "Apple on-device", or the provider's display name for a cloud model.
    func modelTitle(for choice: ProviderChoice) -> String {
        let provider = BotProvider(choice.kind)
        if provider == .apple { return "Apple on-device" }
        let name = catalog[provider]?.first { $0.id == choice.model }?.name ?? choice.model
        return "\(provider.title) · \(name)"
    }

    /// True when a cloud bot cannot answer yet because its key is missing.
    func needsKey(_ id: String) -> Bool {
        guard let account = BotProvider(choice(for: id).kind).keyAccount else { return false }
        return !savedKeys.contains(account)
    }

    func needsKey(choice: ProviderChoice) -> Bool {
        guard let account = BotProvider(choice.kind).keyAccount else { return false }
        return !savedKeys.contains(account)
    }

    func defaultModel(for provider: BotProvider) -> String {
        switch provider {
        case .apple: ProviderChoice.apple.model
        case .anthropic: "claude-opus-5-5"
        case .openAI: "gpt-5"
        }
    }

    /// Fetches the provider's model list with the saved key. Cached until `force`.
    func loadCatalog(_ provider: BotProvider, force: Bool = false) async {
        guard let account = provider.keyAccount else { return }
        if !force, catalog[provider] != nil { return }
        guard !catalogLoading.contains(provider) else { return }
        catalogLoading.insert(provider)
        defer { catalogLoading.remove(provider) }
        do {
            let key = try await secrets.secret(for: NamedSecret(account: account))
            let models = try await ModelDirectory.fetch(provider, key: key)
            catalog[provider] = models
            catalogError[provider] = models.isEmpty ? "No models were listed for this key." : nil
        } catch {
            catalogError[provider] = String(describing: error)
        }
    }

    func saveKey(account: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                secrets.delete(account: account)
            } else {
                try secrets.save(account: account, secret: trimmed)
            }
            refreshSavedKeys()
        } catch {
            banner = String(describing: error)
        }
    }

    func refreshSavedKeys() {
        savedKeys = Set(["ANTHROPIC_API_KEY", "OPENAI_API_KEY"].filter { secrets.has(account: $0) })
    }

    /// Token totals across every bot, for the Usage screen.
    func usageTotals() async -> [(agent: AgentProfile, usage: UsageSummary)] {
        guard let session else { return [] }
        var rows: [(AgentProfile, UsageSummary)] = []
        for agent in agents {
            if let usage = try? await session.usage(for: agent.id) {
                rows.append((agent, usage))
            }
        }
        return rows
    }

    nonisolated static let instructions = "You are a helpful personal assistant on the person's iPhone. Answer directly and briefly. Use tools when they help, and never invent a tool result. Never say you created, saved or set something unless a tool result in this conversation shows it."

    func saveIdentity(asPerson: Bool) async {
        guard let library = await identityStore() else { return }
        do {
            if asPerson {
                _ = try await library.replace(layer: identityLayer, text: identityDraft, editor: "user")
            } else {
                _ = try await library.propose(layer: identityLayer, text: identityDraft, author: "agent")
                banner = "Saved as a proposal. It does not change the prompt until you approve it."
            }
            await reloadIdentity()
        } catch {
            banner = String(describing: error)
        }
    }

    func decideIdentity(_ id: String, approved: Bool) async {
        guard deciding.insert(id).inserted else { return }
        defer { deciding.remove(id) }
        guard let library = await identityStore() else { return }
        do {
            _ = try await library.decide(proposalID: id, approved: approved, approver: "user")
            await reloadIdentity()
        } catch {
            banner = String(describing: error)
        }
    }

    func revertIdentity() async {
        guard let library = await identityStore() else { return }
        guard let current = documents.first(where: { $0.layer == identityLayer }), current.version > 1 else {
            banner = "There is no older version to restore."
            return
        }
        do {
            _ = try await library.revert(layer: identityLayer, toVersion: current.version - 1, editor: "user")
            await reloadIdentity()
        } catch {
            banner = String(describing: error)
        }
    }

    func showIdentityDiff() async {
        guard let library = await identityStore() else { return }
        guard let current = documents.first(where: { $0.layer == identityLayer }), current.version > 1 else {
            identityDiff = "Only one version is stored."
            return
        }
        do {
            let lines = try await library.diff(layer: identityLayer, from: current.version - 1, to: current.version)
            identityDiff = lines.map { line in
                switch line.kind {
                case .same: "  \(line.text)"
                case .add: "+ \(line.text)"
                case .remove: "- \(line.text)"
                }
            }.joined(separator: "\n")
        } catch {
            identityDiff = String(describing: error)
        }
    }

    func installSkill(proposed: Bool) async {
        guard let library = await skillStore() else { return }
        do {
            let parsed = SkillParser.parse(directoryName: "notes", markdown: skillDraft)
            if proposed {
                _ = try await library.propose(directoryName: parsed.name, markdown: skillDraft, author: "agent")
                banner = "Skill proposal stored. Scripts stay text until you approve, and they still will not run."
            } else {
                _ = try await library.install(directoryName: parsed.name, markdown: skillDraft, editor: "user")
            }
            await reloadSkills()
        } catch {
            banner = String(describing: error)
        }
    }

    func decideSkill(_ id: String, approved: Bool) async {
        guard deciding.insert(id).inserted else { return }
        defer { deciding.remove(id) }
        guard let library = await skillStore() else { return }
        do {
            _ = try await library.decide(proposalID: id, approved: approved, approver: "user")
            await reloadSkills()
        } catch {
            banner = String(describing: error)
        }
    }

    func remember() async {
        let text = memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let memory, let session, let store else { return }
        do {
            let id = "mem_" + UUID().uuidString.lowercased()
            try await session.currentEngine().record([
                MemoryIndex.rememberDraft(id: id, text: text, kind: "fact", conversationID: selectedID ?? "assistant", importance: 0.5),
            ], stream: StreamID("memory"))
            try await memory.rebuild(from: store)
            memoryDraft = ""
            await reloadMemory()
        } catch {
            banner = String(describing: error)
        }
    }

    func searchMemory() async {
        guard let memory, let store else { return }
        do {
            try await memory.rebuild(from: store)
            memories = try await memory.search(memoryQuery)
            graphNodes = try await memory.searchNodes(memoryQuery)
        } catch {
            banner = String(describing: error)
        }
    }

    func forget(_ id: String) async {
        guard let memory, let session, let store else { return }
        do {
            try await session.currentEngine().record([
                MemoryIndex.tombstoneDraft(namespace: "memory.tombstone", key: id),
            ], stream: StreamID("memory"))
            try await memory.rebuild(from: store)
            await reloadMemory()
        } catch {
            banner = String(describing: error)
        }
    }

    func defineRoutine(askPermission: Bool = true) async {
        guard let scheduler = await scheduler() else { return }
        // Asked here, where the reason is clear, rather than at launch.
        if askPermission {
            await AssistantNotifications.requestPermission()
        }
        let id = routineID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.range(of: #"^[a-z0-9-]{1,64}$"#, options: .regularExpression) != nil else {
            banner = "Use a routine id of letters, numbers, and hyphens."
            return
        }
        let routine = Routine(
            id: RoutineID(id),
            agentID: routineAgentID ?? featured?.id ?? "assistant",
            cadence: .every(.seconds(max(routineMinutes, 1) * 60), jitter: 0.1),
            quiet: QuietHours(activeStart: host.quietStart, activeEnd: host.quietEnd, timeZone: host.timeZone),
            isolatedSession: true,
            lightContext: true,
            checklist: routineChecklist,
            catchUp: .runLatest
        )
        do {
            try await scheduler.define(routine)
            await reloadRoutines()
            await runRoutineNow(routine.id.rawValue)
            banner = "Routine saved. The next wake is best effort, not a promise."
        } catch {
            banner = String(describing: error)
        }
    }

    /// The context a bot would get for this message, for the self-test and debugging.
    func contextPreview(for agentID: String, message: String, compact: Bool = true) async -> String {
        guard let brain else { return "" }
        let agent = agents.first { $0.id == agentID }
        return await brain.instructions(for: TurnContext(
            agent: agent,
            conversationID: agent?.conversationID ?? "",
            latestUserText: message,
            kind: .chat,
            compact: compact
        ))
    }

    /// Tool names a bot's conversation has used, in order, including messages to other bots.
    func toolsUsed(by agentID: String) async -> [String] {
        guard let store, let raw = agents.first(where: { $0.id == agentID })?.conversationID else { return [] }
        let events = (try? await store.read(stream: .conversation(ConversationID(raw: raw)))) ?? []
        return events.compactMap { event in
            switch event.type {
            case EventType.effectIntent: event.payload["tool"]?.stringValue
            case EventType.subagentStarted: event.payload["name"]?.stringValue
            default: nil
            }
        }
    }

    /// Runs one routine right away with its bot's model, soul and memories, and keeps the reply.
    func runRoutineNow(_ id: String) async {
        guard let session, let store, let routine = routines.first(where: { $0.id.rawValue == id }) else { return }
        routineResults[id] = "Running…"
        do {
            let request = "routine:\(id):manual:\(UUID().uuidString.lowercased())"
            let prompt = "Routine \(id) for \(routine.agentID).\nChecklist:\n\(routine.checklist)\nCall heartbeat.respond. noReply means nothing to report."
            let result = try await session.currentEngine().submitTurn(prompt, requestID: request, to: nil, budget: RoutingModelStep.turnBudget)
            let events = try await store.read(stream: .conversation(result.conversationID))
            var reply = result.failure ?? result.finalText ?? ""
            for event in events where event.type == EventType.effectResult {
                guard let output = event.payload["output"], let outcome = output["outcome"]?.stringValue else { continue }
                reply = outcome == "notify" ? (output["text"]?.stringValue ?? "") : "Nothing to report."
            }
            routineResults[id] = reply.isEmpty ? "Nothing to report." : reply
            if !reply.isEmpty, reply != "Nothing to report." {
                await AssistantNotifications.post(identifier: request, title: "Routine \(id)", body: reply, collapseID: "routines")
            }
        } catch {
            routineResults[id] = String(describing: error)
        }
    }

    func catchUp() async {
        guard let scheduler = await scheduler() else { return }
        if let journal = await policyJournal() {
            _ = try? await journal.considerApproval(ApprovalSubject(
                tool: "routine.catchup",
                effect: .external,
                toolRequiresApproval: false,
                unattended: host.unattended,
                now: Date()
            ))
        }
        do {
            let firings = try await scheduler.tick()
            if firings.isEmpty {
                lastCatchUp = "Catch-up at \(Date.now.formatted(date: .omitted, time: .shortened)): nothing was due."
            } else {
                lastCatchUp = firings.map { firing in
                    if let skipped = firing.skipped {
                        return "\(firing.routineID.rawValue) skipped (\(skipped))"
                    }
                    return "\(firing.routineID.rawValue) ran"
                }.joined(separator: ", ")
            }
            await reloadRoutines()
            await reload()
            AssistantBackground.scheduleNext()
        } catch {
            banner = String(describing: error)
        }
    }

    func addServer() async {
        guard let supportURL else { return }
        let allow = serverAllow.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let config = MCPServerConfig(
            name: serverName.trimmingCharacters(in: .whitespacesAndNewlines),
            transport: "http",
            url: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            allow: allow
        )
        do {
            try config.validate()
            servers.removeAll { $0.name == config.name }
            servers.append(config)
            try saveServers(servers, to: supportURL)
            banner = "Server saved. Connect downloads no code. An empty allowlist exposes no tools."
        } catch {
            banner = String(describing: error)
        }
    }

    func connectServer(_ config: MCPServerConfig) async {
        guard let session else { return }
        do {
            let count = try await session.connectMCP(config)
            connectedServers.insert(config.name)
            banner = "Connected \(config.name) with \(count) tools."
            await reload()
        } catch {
            banner = String(describing: error)
        }
    }

    func removeServer(_ name: String) async {
        guard let supportURL else { return }
        servers.removeAll { $0.name == name }
        do {
            try saveServers(servers, to: supportURL)
        } catch {
            banner = String(describing: error)
        }
    }

    func decide(token: String, approved: Bool, highRisk: Bool) async {
        guard let session else { return }
        let level: AuthenticationLevel
        if highRisk {
            guard let authed = await DeviceAuth.authenticate(reason: "Approve a high-risk action") else {
                banner = "High-risk approval needs Face ID or a device passcode."
                return
            }
            level = authed
        } else {
            level = .session
        }
        do {
            _ = try await session.decide(
                token: token,
                approved: approved,
                approver: Approver(id: "local", authLevel: level)
            )
            banner = ""
            await reload()
        } catch {
            banner = String(describing: error)
        }
    }

    func saveSettings() async {
        guard let session, let supportURL else { return }
        do {
            try await session.updateSettings(settings)
            let data = try JSONEncoder().encode(host)
            try data.write(to: supportURL.appendingPathComponent("policy.json"), options: .atomic)
            banner = ""
        } catch {
            banner = String(describing: error)
        }
    }

    func useOnDeviceModel() async {
        guard let session, let selectedID else { return }
        do {
            try await session.setProvider(selectedID, .apple)
            await reload()
            banner = "This agent will use the on-device model when Apple Intelligence is available."
        } catch {
            banner = String(describing: error)
        }
    }

    private func reloadIdentity() async {
        guard let library = await identityStore() else { return }
        do {
            documents = try await library.current()
            await brain?.update(layers: documents)
            identityProposals = try await library.pending()
            if identityDraft.isEmpty, let current = documents.first(where: { $0.layer == identityLayer }) {
                identityDraft = current.text
            }
        } catch {
            banner = String(describing: error)
        }
    }

    private func reloadSkills() async {
        guard let library = await skillStore() else { return }
        do {
            skills = try await library.list()
            await brain?.update(skills: skills)
            skillProposals = try await library.pending()
        } catch {
            banner = String(describing: error)
        }
    }

    private func reloadMemory() async {
        guard let memory, let store else { return }
        do {
            try await memory.rebuild(from: store)
            let graph = try await memory.readGraph()
            graphNodes = graph.entities
            graphEdges = graph.edges
            memories = memoryQuery.isEmpty ? try await memory.items() : try await memory.search(memoryQuery)
        } catch {
            banner = String(describing: error)
        }
    }

    private func reloadRoutines() async {
        guard let scheduler = await scheduler() else { return }
        do {
            routines = try await scheduler.routines()
            nextWake = try await scheduler.nextWake()
        } catch {
            banner = String(describing: error)
        }
    }

    private func identityStore() async -> IdentityStore? {
        guard let session, let store else { return nil }
        return IdentityStore(engine: await session.currentEngine(), store: store, clock: clock)
    }

    private func skillStore() async -> SkillLibrary? {
        guard let session, let store else { return nil }
        return SkillLibrary(engine: await session.currentEngine(), store: store, clock: clock)
    }

    private func policyJournal() async -> PolicyJournal? {
        guard let session, let store else { return nil }
        return PolicyJournal(
            notifications: NotificationPolicy(
                quiet: QuietHours(activeStart: host.quietStart, activeEnd: host.quietEnd, timeZone: host.timeZone),
                dailyCap: host.dailyCap
            ),
            approvals: ApprovalPolicy(rules: [
                ApprovalRule(id: "allow-pure", effect: .pure, autoApprove: true),
            ]),
            engine: await session.currentEngine(),
            store: store
        )
    }

    private func scheduler() async -> Scheduler? {
        guard let session, let store, let journal = await policyJournal() else { return nil }
        return Scheduler(
            engine: await session.currentEngine(),
            store: store,
            clock: clock,
            wake: AssistantWake(journal: journal)
        )
    }

    /// UI tests launch with `-ui-sandbox`: a fresh folder and its own keys, so they never touch real chats.
    nonisolated static let sandboxed = ProcessInfo.processInfo.arguments.contains("-ui-sandbox")
    nonisolated static var keyService: String {
        sandboxed ? "dev.thinkdefinecreate.Assistant.uitest.keys" : "dev.thinkdefinecreate.Assistant.keys"
    }

    private func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        if Self.sandboxed {
            let sandbox = base.appendingPathComponent("Assistant-UITest", isDirectory: true)
            // `-ui-sandbox-keep` reopens the same sandbox, so a test can check memory across a restart.
            if !ProcessInfo.processInfo.arguments.contains("-ui-sandbox-keep") {
                try? FileManager.default.removeItem(at: sandbox)
            }
            try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
            return sandbox
        }
        let support = base.appendingPathComponent("Assistant", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    private func loadPolicy(from support: URL) -> HostPolicy {
        let url = support.appendingPathComponent("policy.json")
        guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(HostPolicy.self, from: data) else {
            return HostPolicy()
        }
        return decoded
    }

    private func loadServers(from support: URL) -> [MCPServerConfig] {
        let url = support.appendingPathComponent("mcp.json")
        guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return []
        }
        return decoded
    }

    private func loadLooks(from support: URL) -> [String: BotLook] {
        let url = support.appendingPathComponent("bots.json")
        guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: BotLook].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveLooks() throws {
        guard let supportURL else { return }
        let data = try JSONEncoder().encode(looks)
        try data.write(to: supportURL.appendingPathComponent("bots.json"), options: .atomic)
    }

    private func saveServers(_ servers: [MCPServerConfig], to support: URL) throws {
        let data = try JSONEncoder().encode(servers)
        try data.write(to: support.appendingPathComponent("mcp.json"), options: .atomic)
    }
}

private struct AssistantWake: WakeScheduler {
    var journal: PolicyJournal

    func scheduleWake(at date: Date, identifier: String) async {
        AssistantBackground.scheduleNext()
    }

    func notify(identifier: String, body: String, dedupeKey: String) async {
        let decision = try? await journal.considerNotification(
            dedupeKey: dedupeKey,
            collapseID: "routines",
            now: Date()
        )
        guard decision?.deliver == true else { return }
        await AssistantNotifications.post(
            identifier: identifier,
            title: "Assistant",
            body: body,
            collapseID: decision?.collapseID ?? "routines"
        )
    }
}
