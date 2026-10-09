import AgentAppCore
import DurableCore
import DurableFoundationModels
import DurableMCP
import DurableSecurity
import DurableStore
import Foundation
import Observation
import PiAI

#if canImport(UserNotifications)
import UserNotifications
#endif

@MainActor
@Observable
final class AgentModel {
    enum Phase: Equatable {
        case loading
        case onboarding
        case locked
        case ready
        case failed(String)
    }

    var phase: Phase = .loading
    var agents: [AgentProfile] = []
    var selectedID: String?
    var messages: [TranscriptMessage] = []
    var liveText = ""
    var inbox: [InboxItem] = []
    var recovered = false
    var usageNote = ""
    var usageDollars = 0.0
    var events: [RunEvent] = []
    var settings = AppSettings()
    var mcpPort: Int?
    var banner: String?
    var isSending = false

    private var session: AgentSession?
    private var transcript: LiveTranscript?
    private var secrets = KeychainSecretStore(service: "dev.thinkdefinecreate.Lumen.secrets")

    func bootstrap() async {
        if session != nil {
            await reload()
            return
        }
        do {
            let support = try supportDirectory()
            let saved = try AgentDirectory.load(from: support)
            settings = saved.settings
            if saved.settings.appLock {
                phase = .locked
            }
            let patterns = saved.settings.extraRedaction.enumerated().map { index, regex in
                RedactionPattern(name: "custom-\(index)", regex: regex)
            }
            let sqlite = try SQLiteEventStore(path: support.appendingPathComponent("lumen.sqlite").path)
            let keys = KeychainKeyProvider(service: "dev.thinkdefinecreate.Lumen.keys")
            let store = EncryptingEventStore(
                inner: sqlite,
                keys: keys,
                redactor: BuiltInRedactor(extra: patterns),
                omitShredded: true
            )
            let hosts = AppleToolHosts.make()
            let opened = try await AgentSession.open(
                store: store,
                directoryURL: support,
                hosts: hosts,
                secrets: secrets,
                keys: keys,
                foundationModelsLinked: FoundationModelsSupport.compiledIn,
                apple: { _ in
                    #if canImport(FoundationModels)
                    if #available(iOS 26, macOS 26, *) {
                        return FoundationModelsProvider(instructions: "You are Lumen, a personal agent. Prefer on-device tools.")
                    }
                    #endif
                    return nil
                }
            )
            session = opened
            transcript = await opened.liveTranscript()
            recovered = await opened.didRecover
            if recovered {
                banner = String(localized: "Recovered unfinished work from the journal.")
            }
            await reload()
            if saved.settings.completedOnboarding {
                if phase != .locked { phase = .ready }
            } else if phase != .locked {
                phase = .onboarding
            }
            await refreshActivity()
            await writeWidget()
            AppleBackground.register()
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func unlock() async {
        let ok = await DeviceAuth.authenticate(reason: String(localized: "Unlock Lumen"))
        if ok {
            phase = settings.completedOnboarding ? .ready : .onboarding
        }
    }

    func finishOnboarding(anthropic: String, openAI: String, hosts: String) async {
        if !anthropic.isEmpty { try? secrets.save(account: "ANTHROPIC_API_KEY", secret: anthropic) }
        if !openAI.isEmpty { try? secrets.save(account: "OPENAI_API_KEY", secret: openAI) }
        settings.completedOnboarding = true
        settings.webAllowHosts = hosts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        try? await session?.updateSettings(settings)
        phase = .ready
        await reload()
    }

    func create(title: String, provider: ProviderChoice) async {
        guard let session else { return }
        if let agent = try? await session.create(title: title, provider: provider) {
            selectedID = agent.id
            await reload()
        }
    }

    func archiveSelected() async {
        guard let session, let selectedID else { return }
        try? await session.archive(selectedID)
        self.selectedID = nil
        await reload()
    }

    func forkSelected() async {
        guard let session, let selectedID else { return }
        if let copy = try? await session.fork(selectedID) {
            self.selectedID = copy.id
            await reload()
        }
    }

    func setProvider(_ choice: ProviderChoice) async {
        guard let session, let selectedID else { return }
        try? await session.setProvider(selectedID, choice)
        await reload()
    }

    func send(_ text: String) async {
        guard let session, let selectedID, !text.isEmpty else { return }
        isSending = true
        liveText = ""
        let handle = transcript
        let pump = Task { @MainActor in
            while !Task.isCancelled {
                liveText = await handle?.latest() ?? ""
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        do {
            _ = try await session.send(selectedID, text: text)
            AppleBackground.submitContinued(title: agents.first { $0.id == selectedID }?.title ?? "Lumen")
            await notifyInbox()
        } catch {
            banner = String(describing: error)
        }
        pump.cancel()
        isSending = false
        liveText = ""
        await reload()
        await refreshActivity()
        await writeWidget()
    }

    func decide(token: String, approved: Bool, highRisk: Bool) async {
        guard let session else { return }
        var level = AuthenticationLevel.session
        if highRisk {
            let ok = await DeviceAuth.authenticate(reason: String(localized: "Approve a high-risk action"))
            guard ok else { return }
            level = .biometric
        }
        _ = try? await session.decide(
            token: token,
            approved: approved,
            approver: Approver(id: "local", authLevel: level),
            reason: approved ? "" : "Denied in Lumen"
        )
        await reload()
        await refreshActivity()
        await writeWidget()
    }

    func reload() async {
        guard let session else { return }
        agents = await session.agents()
        settings = await session.settings()
        mcpPort = await session.mcpPort
        inbox = (try? await session.inbox()) ?? []
        if let selectedID {
            messages = (try? await session.transcript(for: selectedID)) ?? []
            events = (try? await session.events(for: selectedID)) ?? []
            if let usage = try? await session.usage(for: selectedID) {
                usageNote = usage.note
                usageDollars = usage.estimatedUSD
            }
        } else {
            messages = []
            events = []
        }
    }

    func select(_ id: String) async {
        selectedID = id
        await reload()
    }

    func saveSettings() async {
        try? await session?.updateSettings(settings)
        await reload()
    }

    func setHold(_ held: Bool) async {
        guard let selectedID else { return }
        try? await session?.setHold(selectedID, held: held)
        banner = held ? String(localized: "Legal hold is on for this conversation.") : String(localized: "Legal hold is off.")
    }

    func purge() async {
        guard let selectedID else { return }
        let count = (try? await session?.purge(selectedID)) ?? 0
        banner = String(localized: "Purged \(count) old events.")
        await reload()
    }

    func shred() async {
        guard let selectedID else { return }
        let ok = await DeviceAuth.authenticate(reason: String(localized: "Delete this conversation permanently"))
        guard ok else { return }
        try? await session?.shred(selectedID)
        self.selectedID = nil
        banner = String(localized: "The conversation key was shredded. The ciphertext cannot be read.")
        await reload()
    }

    func exportAudit() async -> String? {
        guard let bundle = try? await session?.exportAudit() else { return nil }
        let verdict = bundle.intact ? "intact" : "broken"
        return "hash-chain \(verdict) tip \(bundle.tip)\n\(bundle.jsonl)"
    }

    func connectMCP(_ config: MCPServerConfig) async -> String {
        do {
            let count = try await session?.connectMCP(config) ?? 0
            await reload()
            return String(localized: "Attached \(count) tools.")
        } catch {
            return String(describing: error)
        }
    }

    func exposeMCP(_ on: Bool) async {
        mcpPort = try? await session?.exposeMCP(on)
        await reload()
    }

    func ingest(text: String) async {
        let body = "Scanned document:\n" + text
        await send(body)
    }

    private func notifyInbox() async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        let approve = UNNotificationAction(identifier: "approve", title: String(localized: "Approve"), options: [])
        let deny = UNNotificationAction(identifier: "deny", title: String(localized: "Deny"), options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: "APPROVAL", actions: [approve, deny], intentIdentifiers: [])])
        for item in inbox {
            let content = UNMutableNotificationContent()
            content.title = item.agentTitle
            content.body = item.prompt
            content.categoryIdentifier = "APPROVAL"
            content.userInfo = ["token": item.token, "risk": item.risk]
            let request = UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
            try? await center.add(request)
        }
        #endif
    }

    private func writeWidget() async {
        let url = widgetURL()
        try? await session?.writeWidgetSnapshot(to: url)
    }

    private func refreshActivity() async {
        #if canImport(ActivityKit)
        await LumenActivityCenter.sync(inbox: inbox, agents: agents)
        #endif
    }

    private func supportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("Lumen", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func widgetURL() -> URL {
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.thinkdefinecreate.Lumen")
        let folder = group ?? FileManager.default.temporaryDirectory
        return folder.appendingPathComponent("lumen-widget.json")
    }
}

enum LumenRuntime {
    @MainActor static var model: AgentModel?
}
