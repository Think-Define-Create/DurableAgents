import AgentAppCore
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
import Observation

struct HostPolicy: Codable, Equatable, Sendable {
    var quietStart: String = "08:00"
    var quietEnd: String = "21:00"
    var timeZone: String = TimeZone.current.identifier
    var dailyCap: Int = 3
    var unattended: Bool = false
}

enum AssistantScreen: String, CaseIterable, Identifiable, Hashable {
    case chat
    case identity
    case skills
    case memory
    case routines
    case mcp
    case approvals
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .identity: "Soul"
        case .skills: "Skills"
        case .memory: "Memory"
        case .routines: "Routines"
        case .mcp: "MCP"
        case .approvals: "Approvals"
        case .settings: "Settings"
        }
    }
}

@MainActor
@Observable
final class AssistantModel {
    var phase: Phase = .loading
    var screen: AssistantScreen = .chat
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

    private var session: AgentSession?
    private var store: (any EventStore)?
    private var memory: MemoryIndex?
    private var supportURL: URL?
    private let secrets = AssistantKeychain(service: "dev.thinkdefinecreate.Assistant.secrets")
    private let clock = SystemDurableClock()

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
            let keys = KeychainKeyProvider(service: "dev.thinkdefinecreate.Assistant.keys")
            let encrypted = EncryptingEventStore(
                inner: sqlite,
                keys: keys,
                redactor: BuiltInRedactor(extra: []),
                omitShredded: true
            )
            let opened = try await AgentSession.open(
                store: encrypted,
                directoryURL: support,
                hosts: .memory(),
                secrets: secrets,
                keys: keys,
                foundationModelsLinked: FoundationModelsSupport.compiledIn,
                apple: { _ in
                    #if canImport(FoundationModels)
                    if #available(iOS 26, macOS 26, *) {
                        return FoundationModelsProvider(instructions: "You are Assistant. Stay on device. Do not invent a tool result.")
                    }
                    #endif
                    return nil
                }
            )
            session = opened
            store = encrypted
            memory = try MemoryIndex(path: support.appendingPathComponent("memory.sqlite").path, embedder: HashEmbedder())
            if await opened.agents().isEmpty {
                settings.onDeviceOnly = true
                settings.completedOnboarding = true
                try await opened.updateSettings(settings)
                _ = try await opened.create(title: "Assistant", provider: .demo)
            }
            await AssistantNotifications.requestPermission()
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
            if selectedID == nil { selectedID = agents.first?.id }
            let overview = try await session.overview(for: selectedID)
            messages = overview.messages
            inbox = overview.inbox
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

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session, let selectedID else { return }
        draft = ""
        do {
            let outcome = try await session.send(selectedID, text: text)
            if let failure = outcome.failure {
                banner = failure
            } else if outcome.resumeToken != nil {
                banner = "Waiting for approval."
            } else {
                banner = ""
            }
            await reload()
        } catch {
            banner = String(describing: error)
        }
    }

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

    func defineRoutine() async {
        guard let scheduler = await scheduler() else { return }
        let id = routineID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.range(of: #"^[a-z0-9-]{1,64}$"#, options: .regularExpression) != nil else {
            banner = "Use a routine id of letters, numbers, and hyphens."
            return
        }
        let routine = Routine(
            id: RoutineID(id),
            agentID: selectedID ?? "assistant",
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
            banner = "Routine saved. The next wake is best effort, not a promise."
        } catch {
            banner = String(describing: error)
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
            banner = "Settings saved."
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
            if !memoryQuery.isEmpty {
                memories = try await memory.search(memoryQuery)
            }
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

    private func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
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
