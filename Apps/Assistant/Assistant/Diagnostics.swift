import AgentAppCore
import Contacts
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
import EventKit
#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation
import ModelKit
import Observation
import Security
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// One check of one DurableAgents module, run on this device.
struct DiagnosticResult: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case passed, failed, skipped
    }

    var module: String
    var name: String
    var status: Status
    var detail: String
    var seconds: Double

    var id: String { module + "/" + name }
}

struct DiagnosticReport: Codable, Sendable {
    var startedAt: Date
    var finishedAt: Date?
    var device: String
    var results: [DiagnosticResult]
    var passed: Int { results.filter { $0.status == .passed }.count }
    var failed: Int { results.filter { $0.status == .failed }.count }
}

/// Runs a check per module. Checks use throwaway stores, so bots, memories and the person's own
/// data are only read, never changed. Write checks on Reminders and Calendar are opt-in and clean up.
@MainActor
@Observable
final class Diagnostics {
    var report: DiagnosticReport?
    var running = false
    var current = ""
    var includeWrites = false
    var includeCloud = false
    var background: DiagnosticReport?

    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-diagnostics") }
    static let backgroundFlag = "diagnostics.background"

    init() {
        background = Self.load("diagnostics-background.json")
        report = Self.load("diagnostics.json")
    }

    func run(_ model: AssistantModel) async {
        guard !running else { return }
        running = true
        defer {
            running = false
            current = ""
        }
        report = DiagnosticReport(startedAt: Date(), device: Self.deviceName(), results: [])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Storage and the engine.
        await check("DurableStore", "Conversation survives close and reopen") { try await Checks.storeReopen(scratch) }
        await check("DurableCore", "Approved tool runs once after a restart") { try await Checks.approvalAcrossRestart(scratch) }
        await check("DurableSecurity", "Encrypts with a Keychain key and reads it back") { try await Checks.keychainRoundTrip() }
        await check("DurableSecurity", "Deleted conversation is skipped, not fatal") { try await Checks.shredIsSkipped() }
        await check("DurableSecurity", "App keys readable while locked") { try await Checks.keyAccessibility() }
        await check("DurableStore", "Every stored event in the app decrypts") { try await Checks.appStoreDecrypts(model.diagnosticsSupportURL) }

        // Bots.
        await check("AgentAppCore", "Bot asks another bot") { try await Checks.botToBot(scratch) }
        await check("AgentAppCore", "Reminder takes its time from the message") { try await Checks.reminderTime(scratch) }
        await check("AgentAppCore", "Soul and memory reach each bot") { try await Checks.botContext(model) }
        await check("DurableFoundationModels", "On-device model answers and remembers") { try await Checks.onDeviceRecall(scratch) }
        await check("DurableFoundationModels", "On-device model calls a tool") { try await Checks.onDeviceTool(scratch) }
        await check("DurableFoundationModels", "Private Cloud Compute reads past the on-device window") { try await Checks.privateCloudRecall(scratch) }

        // The agent's mind.
        await check("DurableMemory", "Saved fact is found by search") { try await Checks.memorySearch(scratch) }
        await check("DurableRetrieval", "Similar text ranks first") { try await Checks.retrieval() }
        await check("DurableRetrieval", "Search matches meaning, not just words") { try await Checks.semanticSearch(scratch) }
        await check("DurableIdentity", "Soul edit waits for approval") { try await Checks.identityProposal() }
        await check("DurableSkills", "Skill installs and is listed") { try await Checks.skillInstall() }

        // Running on its own.
        await check("DurableSchedule", "Routine fires once per slot") { try await Checks.routineTick() }
        await check("DurableSchedule", "iOS accepted the background wake requests") { try Checks.backgroundScheduling() }
        await check("DurablePolicy", "Daily notification cap and quiet hours") { try await Checks.notificationPolicy() }
        await check("Notifications", "Permission granted") { try await Checks.notificationPermission() }

        // Connections.
        await check("DurableMCP", "Our MCP server answers in-process") { try await Checks.mcpLoopback() }
        await check("DurableMCP", "MCP 2026-07-28 discover and call") { try await Checks.mcpModern() }
        for server in model.servers where server.transport == "http" {
            await check("DurableMCP", "Server \(server.name) lists tools") { try await Checks.mcpServer(server, model: model) }
        }
        for provider in [BotProvider.anthropic, .openAI] {
            await check("ModelKit", "\(provider.title) key lists models") { try await Checks.listModels(provider, model: model) }
            if includeCloud {
                await check("ModelKit", "\(provider.title) answers (paid)") { try await Checks.cloudReply(provider, model: model) }
            }
        }

        // The phone's own data, through the same code the bots' tools use.
        await check("Apple tools", "Calendar access and read") { try await Checks.calendarRead() }
        await check("Apple tools", "Contacts access and search") { try await Checks.contactsSearch() }
        await check("Apple tools", "Reminders access") { try Checks.remindersAccess() }
        if includeWrites {
            await check("Apple tools", "Reminder gets a due time and alert (then deleted)") { try await Checks.reminderWrite() }
            await check("Apple tools", "Event lands at the asked time (then deleted)") { try await Checks.eventWrite() }
        }

        report?.finishedAt = Date()
        save()
    }

    /// Posts a notification in 5 seconds so the person can lock the phone and see it arrive.
    func sendTestNotification() async {
        #if canImport(UserNotifications)
        await AssistantNotifications.requestPermission()
        let content = UNMutableNotificationContent()
        content.title = "Diagnostics"
        content.body = "Test notification from DurableAgents."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "diagnostics-\(UUID().uuidString)", content: content, trigger: trigger))
        #endif
    }

    /// Asks iOS for a background wake. When it comes, `backgroundProbe` records what was readable.
    func armBackgroundCheck() {
        UserDefaults.standard.set(true, forKey: Self.backgroundFlag)
        AssistantBackground.scheduleNext()
    }

    /// Where the app keeps its store, for a background wake that starts before the model is open.
    nonisolated static func supportURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Assistant", isDirectory: true)
    }

    /// Runs inside a background wake, often while the phone is locked.
    static func backgroundProbe(support: URL?) async {
        guard UserDefaults.standard.bool(forKey: backgroundFlag) else { return }
        var report = DiagnosticReport(startedAt: Date(), device: deviceName(), results: [])
        #if canImport(UIKit)
        let protected = UIApplication.shared.isProtectedDataAvailable
        report.results.append(DiagnosticResult(module: "Background", name: "Phone unlocked", status: .passed, detail: protected ? "yes" : "no, locked", seconds: 0))
        #endif
        do {
            report.results.append(DiagnosticResult(module: "Background", name: "App keys readable", status: .passed, detail: try await Checks.keyAccessibility(), seconds: 0))
        } catch {
            report.results.append(DiagnosticResult(module: "Background", name: "App keys readable", status: .failed, detail: String(describing: error), seconds: 0))
        }
        let started = Date()
        do {
            let detail = try await Checks.appStoreDecrypts(support)
            report.results.append(DiagnosticResult(module: "Background", name: "Every stored event decrypts", status: .passed, detail: detail, seconds: Date().timeIntervalSince(started)))
        } catch {
            report.results.append(DiagnosticResult(module: "Background", name: "Every stored event decrypts", status: .failed, detail: String(describing: error), seconds: Date().timeIntervalSince(started)))
        }
        report.finishedAt = Date()
        write(report, to: "diagnostics-background.json")
        UserDefaults.standard.set(false, forKey: backgroundFlag)
    }

    /// A check that does not answer in time fails, so one stuck call cannot stall the whole run.
    private func check(_ module: String, _ name: String, limit: Duration = .seconds(180), _ work: @escaping () async throws -> String) async {
        current = "\(module): \(name)"
        let started = Date()
        var result = DiagnosticResult(module: module, name: name, status: .passed, detail: "", seconds: 0)
        do {
            result.detail = try await Self.within(limit, work)
        } catch let skip as DiagnosticSkip {
            result.status = .skipped
            result.detail = skip.reason
        } catch {
            result.status = .failed
            result.detail = String(describing: error)
        }
        result.seconds = Date().timeIntervalSince(started)
        report?.results.append(result)
        save()
    }

    private static func within(_ limit: Duration, _ work: @escaping () async throws -> String) async throws -> String {
        let outcome: Result<String, any Error> = await withCheckedContinuation { continuation in
            var settled = false
            let job = Task { @MainActor in
                let result: Result<String, any Error>
                do { result = .success(try await work()) } catch { result = .failure(error) }
                guard !settled else { return }
                settled = true
                continuation.resume(returning: result)
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                guard !settled else { return }
                settled = true
                job.cancel()
                continuation.resume(returning: .failure(DiagnosticFailure("no answer after \(limit.components.seconds) seconds")))
            }
        }
        return try outcome.get()
    }

    private func save() {
        if let report { Self.write(report, to: "diagnostics.json") }
    }

    nonisolated static func write(_ report: DiagnosticReport, to name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: documents.appendingPathComponent(name), options: .atomic)
    }

    nonisolated static func load(_ name: String) -> DiagnosticReport? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: documents.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DiagnosticReport.self, from: data)
    }

    nonisolated static func deviceName() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if canImport(UIKit)
        return "\(UIDevice.current.model) \(os)"
        #else
        return "Mac \(os)"
        #endif
    }
}

struct DiagnosticSkip: Error {
    var reason: String
}

struct DiagnosticFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw DiagnosticFailure(message()) }
}

/// Answers from a closure, so engine and routing checks do not depend on a model's mood.
private struct ScriptProvider: ModelProvider {
    var reply: @Sendable (ModelRequest) -> [ModelStreamEvent]

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let events = reply(request) + [.stop(StopReason(raw: "end_turn"))]
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Counts real runs, so a check can tell a replay from a second execution.
private actor CountingNotes: NotesClient {
    private(set) var runs = 0
    private(set) var lastDue: Date?

    func upsertReminder(title: String, effectKey: String) async throws -> String {
        try await upsertReminder(title: title, due: nil, effectKey: effectKey)
    }

    func upsertReminder(title: String, due: Date?, effectKey: String) async throws -> String {
        runs += 1
        lastDue = due
        return "rem_\(runs)"
    }
}

private struct KeychainSecrets: MCPSecretStore {
    var model: AssistantModel

    func secret(account: String) async throws -> String? {
        await model.diagnosticsSecret(account)
    }
}

private enum Checks {
    static let approver = Approver(id: "diagnostics", authLevel: .session)

    static func session(
        _ folder: URL,
        store: any EventStore,
        hosts: ToolHosts = .memory(),
        provider: @escaping @Sendable (ProviderChoice) -> (any ModelProvider)?
    ) async throws -> AgentSession {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await AgentSession.open(
            store: store,
            directoryURL: folder,
            hosts: hosts,
            foundationModelsLinked: true,
            apple: provider,
            instructions: "You are a helpful assistant. Answer directly and briefly."
        )
    }

    static func storeReopen(_ scratch: URL) async throws -> String {
        let folder = scratch.appendingPathComponent("reopen")
        let path = folder.appendingPathComponent("events.sqlite").path
        let pong: @Sendable (ProviderChoice) -> (any ModelProvider)? = { _ in ScriptProvider { _ in [.textDelta("pong")] } }
        var session = try await session(folder, store: SQLiteEventStore(path: path), provider: pong)
        let bot = try await session.create(title: "Echo", provider: .apple)
        _ = try await session.send(bot.id, text: "ping")
        await session.close()
        session = try await Self.session(folder, store: SQLiteEventStore(path: path), provider: pong)
        let messages = try await session.transcript(for: bot.id)
        await session.close()
        try expect(messages.map(\.text) == ["ping", "pong"], "after reopening: \(messages.map(\.text))")
        return "2 messages back after reopening SQLite"
    }

    static func approvalAcrossRestart(_ scratch: URL) async throws -> String {
        let folder = scratch.appendingPathComponent("approval")
        let path = folder.appendingPathComponent("events.sqlite").path
        let notes = CountingNotes()
        var hosts = ToolHosts.memory()
        hosts.notes = notes
        let bot: @Sendable (ProviderChoice) -> (any ModelProvider)? = { _ in
            ScriptProvider { request in
                if request.messages.last?.role == .tool { return [.textDelta("Done")] }
                return [.toolCall(ProviderToolCall(id: "r1", name: "notes_reminder", argumentsJSON: #"{"title":"diagnostics","due":"2030-01-01T09:00"}"#))]
            }
        }
        var session = try await session(folder, store: SQLiteEventStore(path: path), hosts: hosts, provider: bot)
        let profile = try await session.create(title: "Ada", provider: .apple)
        let sent = try await session.send(profile.id, text: "remind me")
        let token = try sent.resumeToken ?? { throw DiagnosticFailure("no approval was asked, status \(sent.runStatus ?? "none")") }()
        try expect(await notes.runs == 0, "the tool ran before approval")
        await session.close()

        session = try await Self.session(folder, store: SQLiteEventStore(path: path), hosts: hosts, provider: bot)
        let resumed = try await session.decide(token: token, approved: true, approver: approver)
        await session.close()
        let runs = await notes.runs
        try expect(runs == 1, "the tool ran \(runs) times")
        try expect(resumed.finalText == "Done", "final text \(resumed.finalText ?? "none")")
        return "suspended, closed, reopened, approved; tool ran once"
    }

    static func keychainRoundTrip() async throws -> String {
        let keys = SecureEnclaveKeyProvider(service: "dev.thinkdefinecreate.Assistant.diagnostics")
        let inner = InMemoryEventStore(storeID: "diag-keychain")
        let store = EncryptingEventStore(inner: inner, keys: keys)
        let lease = try await store.acquireLease(owner: UUID(), pid: 1, ttl: .seconds(60))
        let stream = StreamID("diag-\(UUID().uuidString)")
        _ = try await store.commit(fence: FenceToken(owner: lease.owner, epoch: lease.epoch), stream: stream, events: [
            EventDraft(type: EventType.messageAppended, payload: .object(["text": .string("secret phrase 42")])),
        ])
        let atRest = try await inner.readAll().map { $0.payload.canonicalJSON() }.joined()
        let back = try await store.read(stream: stream).first?.payload["text"]?.stringValue
        try await keys.shred(stream.raw)
        try expect(!atRest.contains("secret phrase"), "plaintext was stored")
        try expect(atRest.contains("AES-GCM"), "not encrypted")
        try expect(back == "secret phrase 42", "read back \(back ?? "nothing")")
        return "stored as AES-GCM, read back with the Keychain key"
    }

    static func shredIsSkipped() async throws -> String {
        let keys = SecureEnclaveKeyProvider(service: "dev.thinkdefinecreate.Assistant.diagnostics")
        let inner = InMemoryEventStore(storeID: "diag-shred")
        let writer = EncryptingEventStore(inner: inner, keys: keys)
        let lease = try await writer.acquireLease(owner: UUID(), pid: 1, ttl: .seconds(60))
        let fence = FenceToken(owner: lease.owner, epoch: lease.epoch)
        let kept = StreamID("diag-kept-\(UUID().uuidString)")
        let gone = StreamID("diag-gone-\(UUID().uuidString)")
        for stream in [kept, gone] {
            _ = try await writer.commit(fence: fence, stream: stream, events: [
                EventDraft(type: EventType.messageAppended, payload: .object(["text": .string(stream.raw)])),
            ])
        }
        try await keys.shred(gone.raw)
        let fresh = SecureEnclaveKeyProvider(service: "dev.thinkdefinecreate.Assistant.diagnostics")
        let reader = EncryptingEventStore(inner: inner, keys: fresh, omitShredded: true)
        let events = try await reader.readAll()
        try await fresh.shred(kept.raw)
        try await fresh.shred(gone.raw)
        try expect(events.count == 1 && events.first?.stream == kept, "read \(events.count) events")
        return "the kept conversation reads, the deleted one is skipped"
    }

    /// Keys must be readable after the first unlock, or locked background wakes lose messages.
    static func keyAccessibility() async throws -> String {
        let inventory = try await SecureEnclaveKeyProvider(service: AssistantModel.keyService).inventory()
        if inventory.total == 0 { return "no keys yet" }
        let strict = inventory.total - inventory.readableAfterFirstUnlock
        try expect(strict == 0, "\(strict) of \(inventory.total) keys are readable only while unlocked. Open each bot once to update them.")
        #if !targetEnvironment(simulator)
        try expect(inventory.secureEnclave, "this device reports no Secure Enclave, so keys are stored plain")
        try expect(inventory.plain == 0, "\(inventory.plain) of \(inventory.total) keys are not wrapped by the Secure Enclave yet")
        #endif
        let wrapped = inventory.secureEnclave ? ", \(inventory.wrapped) wrapped by the Secure Enclave" : ", stored plain (no Secure Enclave here)"
        return "\(inventory.total) keys\(wrapped), all readable after first unlock"
    }

    /// Reads the app's own log without skipping anything, so a key problem shows up as a failure.
    static func appStoreDecrypts(_ support: URL?) async throws -> String {
        guard let support else { throw DiagnosticSkip(reason: "the app store is not open") }
        let sqlite = try SQLiteEventStore(path: support.appendingPathComponent("assistant.sqlite").path)
        let raw = try await sqlite.readAll()
        let store = EncryptingEventStore(
            inner: sqlite,
            keys: SecureEnclaveKeyProvider(service: AssistantModel.keyService),
            omitShredded: true
        )
        let opened = try await store.readAll()
        let streams = Set(raw.map(\.stream)).count
        let skipped = raw.count - opened.count
        return "\(opened.count) events in \(streams) streams decrypt" + (skipped > 0 ? ", \(skipped) from deleted bots skipped" : "")
    }

    static func botToBot(_ scratch: URL) async throws -> String {
        let folder = scratch.appendingPathComponent("bots")
        let bots: @Sendable (ProviderChoice) -> (any ModelProvider)? = { choice in
            if choice.model == "bea" { return ScriptProvider { _ in [.textDelta("hi from Bea")] } }
            return ScriptProvider { request in
                if request.messages.last?.role == .tool { return [.textDelta("Bea says: \(request.messages.last?.text ?? "")")] }
                return [.toolCall(ProviderToolCall(id: "a1", name: "bots_ask", argumentsJSON: #"{"bot":"Bea","message":"Say hi"}"#))]
            }
        }
        let session = try await session(folder, store: InMemoryEventStore(storeID: "diag-bots"), provider: bots)
        let ada = try await session.create(title: "Ada", provider: ProviderChoice(kind: .apple, model: "ada"))
        _ = try await session.create(title: "Bea", provider: ProviderChoice(kind: .apple, model: "bea"))
        let sent = try await session.send(ada.id, text: "ask Bea to say hi")
        await session.close()
        try expect(sent.finalText == "Bea says: hi from Bea", "reply \(sent.finalText ?? sent.failure ?? "none")")
        return "Ada asked Bea and relayed \"hi from Bea\""
    }

    static func reminderTime(_ scratch: URL) async throws -> String {
        let folder = scratch.appendingPathComponent("reminder")
        let notes = CountingNotes()
        var hosts = ToolHosts.memory()
        hosts.notes = notes
        let bot: @Sendable (ProviderChoice) -> (any ModelProvider)? = { _ in
            ScriptProvider { request in
                if request.messages.last?.role == .tool { return [.textDelta("Done")] }
                return [.toolCall(ProviderToolCall(id: "r1", name: "notes_reminder", argumentsJSON: #"{"title":"buy milk"}"#))]
            }
        }
        let session = try await session(folder, store: InMemoryEventStore(storeID: "diag-reminder"), hosts: hosts, provider: bot)
        let profile = try await session.create(title: "Ada", provider: .apple)
        let sent = try await session.send(profile.id, text: "Remind me to buy milk tomorrow at 9am")
        if let token = sent.resumeToken {
            _ = try await session.decide(token: token, approved: true, approver: approver)
        }
        await session.close()
        let due = await notes.lastDue
        let hour = due.map { Calendar.current.component(.hour, from: $0) }
        try expect(hour == 9, "due \(due.map { ToolDates.describe($0) } ?? "missing")")
        return "model left the time out; due set to \(due.map { ToolDates.describe($0) } ?? "")"
    }

    @MainActor static func botContext(_ model: AssistantModel) async throws -> String {
        guard let bot = model.featured else { throw DiagnosticSkip(reason: "no bots yet") }
        let context = await model.contextPreview(for: bot.id, message: "What do you know about me?")
        try expect(context.contains("Now: "), "no date in the context")
        try expect(context.count < 4_000, "context is \(context.count) characters, too big for the on-device window")
        let soul = context.contains("Your soul")
        let memories = context.contains("What you remember")
        return "\(context.count) characters; soul \(soul ? "included" : "not set"), memories \(memories ? "included" : "none saved")"
    }

    static func onDeviceRecall(_ scratch: URL) async throws -> String {
        let provider = try onDevice()
        let session = try await session(scratch.appendingPathComponent("recall"), store: InMemoryEventStore(storeID: "diag-fm"), provider: { _ in provider })
        let bot = try await session.create(title: "Assistant", provider: .apple)
        _ = try await session.send(bot.id, text: "My sister's name is Ana and she lives in Lisbon.")
        _ = try await session.send(bot.id, text: "What's a good gift for a sister?")
        let reply = try await session.send(bot.id, text: "What is my sister's name, and where does she live?")
        await session.close()
        let text = reply.finalText ?? reply.failure ?? ""
        try expect(text.contains("Ana") && text.contains("Lisbon"), "reply: \(text)")
        return text
    }

    static func onDeviceTool(_ scratch: URL) async throws -> String {
        let provider = try onDevice()
        var hosts = ToolHosts.memory()
        hosts.contacts = MemoryContacts(names: ["Testy McTestface: 555-0100"])
        let session = try await session(scratch.appendingPathComponent("tool"), store: InMemoryEventStore(storeID: "diag-fm-tool"), hosts: hosts, provider: { _ in provider })
        let bot = try await session.create(title: "Assistant", provider: .apple)
        let reply = try await session.send(bot.id, text: "What is Testy McTestface's phone number?")
        await session.close()
        let text = reply.finalText ?? reply.failure ?? ""
        try expect(text.contains("555"), "reply: \(text)")
        return text
    }

    static func privateCloudRecall(_ scratch: URL) async throws -> String {
        #if targetEnvironment(simulator)
        throw DiagnosticSkip(reason: "Private Cloud Compute does not run in the simulator")
        #elseif canImport(FoundationModels)
        guard #available(iOS 27, macOS 27, *) else { throw DiagnosticSkip(reason: "needs iOS 27") }
        guard Bundle.main.object(forInfoDictionaryKey: FoundationModelsSupport.privateCloudEntitledKey) as? Bool == true else {
            throw DiagnosticSkip(reason: "this app does not have Apple's Private Cloud Compute entitlement yet")
        }
        guard FoundationModelsSupport.privateCloudAvailable else { throw DiagnosticSkip(reason: "Private Cloud Compute is not available on this device right now") }
        let provider = FoundationModelsProvider(instructions: "", bridgesRequestTools: true, privateCloud: true)
        let session = try await session(scratch.appendingPathComponent("pcc"), store: InMemoryEventStore(storeID: "diag-pcc"), provider: { _ in provider })
        let bot = try await session.create(title: "Assistant", provider: .applePrivateCloud)
        // Proof that the cloud model answered: about 7,000 tokens of notes with one code word in the
        // middle. That is past the on-device model's 4,096-token window, so only Private Cloud Compute
        // can see the word and answer with it.
        let filler = (1...250).map { "Note \($0): the weekly report lists routine maintenance, nothing unusual, all systems normal." }
        var notes = filler
        notes.insert("Note 125b: the code word is PELICAN-42.", at: 125)
        _ = try await session.send(bot.id, text: notes.joined(separator: "\n") + "\nRead these notes. Reply only with OK.")
        let reply = try await session.send(bot.id, text: "What is the code word in note 125b?")
        await session.close()
        let text = reply.finalText ?? reply.failure ?? ""
        try expect(text.contains("PELICAN-42"), "reply: \(text)")
        let quota = PrivateCloudComputeLanguageModel().quotaUsage
        return "found the code word in a prompt larger than the on-device window. Quota: \(quota.status)"
        #else
        throw DiagnosticSkip(reason: "Foundation Models is not in this build")
        #endif
    }

    static func onDevice() throws -> any ModelProvider {
        #if targetEnvironment(simulator)
        throw DiagnosticSkip(reason: "Apple's model does not run in the simulator")
        #elseif canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            guard FoundationModelsSupport.isAvailable() else {
                throw DiagnosticSkip(reason: FoundationModelsSupport.unavailableReason() ?? "Apple Intelligence is unavailable")
            }
            return FoundationModelsProvider(instructions: "", bridgesRequestTools: true)
        }
        #endif
        throw DiagnosticSkip(reason: "needs iOS 26 with Apple Intelligence")
    }

    static func memorySearch(_ scratch: URL) async throws -> String {
        let store = InMemoryEventStore(storeID: "diag-memory")
        let engine = try await Engine(store: store, leaseTTL: .seconds(600))
        try await engine.record([
            MemoryIndex.rememberDraft(id: "m1", text: "The person's dog is named Rex.", kind: "fact", conversationID: "diag", importance: 0.5),
            MemoryIndex.rememberDraft(id: "m2", text: "The person prefers tea over coffee.", kind: "fact", conversationID: "diag", importance: 0.5),
        ], stream: StreamID("memory"))
        let index = try MemoryIndex(path: scratch.appendingPathComponent("memory.sqlite").path, embedder: HashEmbedder())
        try await index.rebuild(from: store)
        let hits = try await index.search("dog")
        await engine.close()
        try expect(hits.first?.text.contains("Rex") == true, "top hit: \(hits.first?.text ?? "none")")
        return "\"dog\" found: \(hits.first?.text ?? "")"
    }

    static func retrieval() async throws -> String {
        let embedder = HashEmbedder(dimensions: 64)
        let vectors = try await embedder.embed(["walk the dog in the park", "quarterly tax filing", "dog park walk"])
        let near = RetrievalMath.cosine(vectors[0], vectors[2])
        let far = RetrievalMath.cosine(vectors[0], vectors[1])
        try expect(near > far, "similar \(near) vs different \(far)")
        return String(format: "similar %.2f > different %.2f", near, far)
    }

    static func semanticSearch(_ scratch: URL) async throws -> String {
        let embedder = await Embedders.preferred(requestAssets: false)
        guard embedder.id.hasPrefix("nl-contextual") else {
            throw DiagnosticSkip(reason: "Apple's sentence model is not downloaded yet, so search uses word hashes")
        }
        let vectors = try await embedder.embed(["my dog is sick", "the puppy has a vet appointment on Friday", "file the quarterly taxes"])
        let near = RetrievalMath.cosine(vectors[0], vectors[1])
        let far = RetrievalMath.cosine(vectors[0], vectors[2])
        try expect(near > far, "dog/puppy \(near) vs dog/taxes \(far)")
        return String(format: "dog/puppy %.2f > dog/taxes %.2f with %@", near, far, embedder.id)
    }

    static func backgroundScheduling() throws -> String {
        if let error = UserDefaults.standard.string(forKey: AssistantBackground.submitErrorKey) {
            if error.contains("BGTaskSchedulerErrorDomain Code=1") {
                throw DiagnosticFailure("iOS will not wake Assistant in the background: Background App Refresh is off for Assistant (Settings → General → Background App Refresh), or Low Power Mode is on. Routines then run only when the app is open.")
            }
            throw DiagnosticFailure("iOS refused the last request: \(error)")
        }
        return "refresh and processing requests accepted"
    }

    static func identityProposal() async throws -> String {
        let clock = ManualClock()
        let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
        let engine = try await Engine(store: store, clock: clock, leaseTTL: .seconds(600))
        let identity = IdentityStore(engine: engine, store: store, clock: clock)
        _ = try await identity.replace(layer: .soul, text: "Be brief.", editor: "person")
        let proposal = try await identity.propose(layer: .soul, text: "Be verbose.", author: "agent")
        let before = try await identity.assemble(budget: ContextBudget(maxTokens: 400), lightContext: false).system
        _ = try await identity.decide(proposalID: proposal.id, approved: true, approver: "person")
        let after = try await identity.assemble(budget: ContextBudget(maxTokens: 400), lightContext: false).system
        await engine.close()
        try expect(before.contains("Be brief.") && !before.contains("Be verbose."), "a proposal reached the prompt before approval")
        try expect(after.contains("Be verbose."), "the approved edit is missing")
        return "proposal stayed out until approved, then applied"
    }

    static func skillInstall() async throws -> String {
        let clock = ManualClock()
        let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
        let engine = try await Engine(store: store, clock: clock, leaseTTL: .seconds(600))
        let skills = SkillLibrary(engine: engine, store: store, clock: clock)
        let markdown = "---\nname: diagnostics-skill\ndescription: Checks that skills load.\n---\nSay hello.\n"
        _ = try await skills.install(directoryName: "diagnostics-skill", markdown: markdown, editor: "person")
        let listed = try await skills.list().map(\.name)
        let block = try await skills.metadataBlock()
        await engine.close()
        try expect(listed.contains("diagnostics-skill"), "listed \(listed)")
        try expect(block.contains("diagnostics-skill"), "missing from the prompt block")
        return "installed and listed in the prompt block"
    }

    static func routineTick() async throws -> String {
        let clock = ManualClock()
        let remainder = clock.now().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
        if remainder != 0 { clock.advance(by: 60 - remainder) }
        let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
        let engine = try await Engine(
            store: store,
            tools: [HeartbeatTool.make()],
            model: ScriptedModelStep(steps: [
                .tool(name: HeartbeatTool.name, callID: "h1", arguments: .object(["outcome": .string("noReply")])),
                .finish("done"),
            ]),
            clock: clock,
            leaseTTL: .seconds(600)
        )
        let scheduler = Scheduler(engine: engine, store: store, clock: clock)
        try await scheduler.define(Routine(id: RoutineID("diag"), agentID: "agent", cadence: .every(.seconds(60), jitter: 0), checklist: "look"))
        let first = try await scheduler.tick()
        let again = try await scheduler.tick()
        await engine.close()
        try expect(first.count == 1, "fired \(first.count) times on the first tick")
        try expect(again.isEmpty, "fired again in the same slot")
        try expect(first.first?.outcome == .noReply, "outcome \(String(describing: first.first?.outcome))")
        return "fired once, silent heartbeat, no repeat in the same slot"
    }

    static func notificationPolicy() async throws -> String {
        let clock = ManualClock()
        let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
        let engine = try await Engine(store: store, clock: clock, leaseTTL: .seconds(600))
        let journal = PolicyJournal(
            notifications: NotificationPolicy(quiet: nil, dailyCap: 1),
            approvals: ApprovalPolicy(rules: []),
            engine: engine,
            store: store
        )
        let first = try await journal.considerNotification(dedupeKey: "a", collapseID: "c", now: clock.now())
        let second = try await journal.considerNotification(dedupeKey: "b", collapseID: "c", now: clock.now())
        await engine.close()
        try expect(first.deliver, "the first notification was held: \(first.ruleID)")
        try expect(!second.deliver && second.ruleID == "daily-cap", "the second was \(second.ruleID)")
        let zone = TimeZone.current.identifier
        let quiet = QuietHours(activeStart: "09:00", activeEnd: "17:00", timeZone: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let night = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: Date())!
        try expect(quiet.isActive(at: noon) && !quiet.isActive(at: night), "quiet hours window is wrong")
        return "cap holds the second notification; 09:00–17:00 window allows noon, not 23:00"
    }

    static func notificationPermission() async throws -> String {
        #if canImport(UserNotifications)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "allowed"
        case .denied: throw DiagnosticFailure("denied in Settings, so routine alerts from this app cannot show")
        default: throw DiagnosticSkip(reason: "not asked yet. Tap Send Test Notification to be asked.")
        }
        #else
        throw DiagnosticSkip(reason: "not available")
        #endif
    }

    static func mcpLoopback() async throws -> String {
        let store = InMemoryEventStore(storeID: "diag-mcp")
        let engine = try await Engine(store: store, leaseTTL: .seconds(600))
        let server = DurableMCPServer(engine: engine, store: store, approverIDs: ["diagnostics"])
        let client = try await server.loopbackClient()
        let tools = try await client.listTools().map(\.name)
        await client.close()
        await server.stop()
        await engine.close()
        try expect(tools.contains("start_run"), "tools: \(tools)")
        return "\(tools.count) tools: \(tools.joined(separator: ", "))"
    }

    static func mcpModern() async throws -> String {
        let store = InMemoryEventStore(storeID: "diag-mcp-modern")
        let engine = try await Engine(store: store, leaseTTL: .seconds(600))
        let server = DurableMCPServer(engine: engine, store: store, approverIDs: ["diagnostics"])
        let client = try await server.modernLoopbackClient()
        let version = await client.protocolVersion
        let tools = try await client.listTools().map(\.name)
        await client.close()
        await engine.close()
        try expect(version == "2026-07-28", "negotiated \(version)")
        try expect(tools.contains("start_run"), "tools: \(tools)")
        return "spoke \(version), \(tools.count) tools"
    }

    static func mcpServer(_ config: MCPServerConfig, model: AssistantModel) async throws -> String {
        let client = try await MCPClientSession.connect(config, secrets: KeychainSecrets(model: model))
        let tools = try await client.listTools().map(\.name)
        await client.close()
        return "\(tools.count) tools" + (tools.isEmpty ? "" : ": " + tools.prefix(8).joined(separator: ", "))
    }

    static func listModels(_ provider: BotProvider, model: AssistantModel) async throws -> String {
        guard let account = provider.keyAccount, let key = await model.diagnosticsSecret(account) else {
            throw DiagnosticSkip(reason: "no \(provider.title) key saved")
        }
        let models = try await ModelDirectory.fetch(provider, key: key)
        try expect(!models.isEmpty, "no models listed")
        return "\(models.count) models, newest \(models[0].id)"
    }

    @MainActor static func cloudReply(_ provider: BotProvider, model: AssistantModel) async throws -> String {
        guard let account = provider.keyAccount, await model.diagnosticsSecret(account) != nil else {
            throw DiagnosticSkip(reason: "no \(provider.title) key saved")
        }
        let secrets = DiagnosticsSecretStore(model: model)
        let client: any ModelProvider = provider == .anthropic
            ? AnthropicMessages(apiKey: NamedSecret(account: account), secrets: secrets)
            : OpenAIResponses(apiKey: NamedSecret(account: account), secrets: secrets)
        let name = model.defaultModel(for: provider)
        var text = ""
        for try await event in client.stream(ModelRequest(
            model: name,
            messages: [ModelMessage(role: .user, text: "Reply with the single word pong.")],
            maxOutputTokens: 16
        )) {
            if case .textDelta(let delta) = event { text += delta }
        }
        try expect(text.lowercased().contains("pong"), "\(name) replied: \(text)")
        return "\(name): \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    static func calendarRead() async throws -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw DiagnosticSkip(reason: "Calendar access is not granted. Ask a bot about your calendar to be prompted.")
        }
        let events = try await AppleToolHosts.make().calendar.upcoming(days: 7, limit: 50)
        let timed = events.filter { $0.start != nil }.count
        try expect(timed == events.count, "\(events.count - timed) events came back without a time")
        return "\(events.count) events in the next 7 days, all with times"
    }

    static func contactsSearch() async throws -> String {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status == .limited else {
            throw DiagnosticSkip(reason: "Contacts access is not granted. Ask a bot for a phone number to be prompted.")
        }
        let found = try await AppleToolHosts.make().contacts.search(name: "a")
        return "\(found.count) matches for \"a\"" + (found.isEmpty ? "" : ", first has details: \(found[0].contains(":") ? "yes" : "no")")
    }

    static func remindersAccess() throws -> String {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return "granted"
        case .denied, .restricted: throw DiagnosticFailure("denied in Settings, so bots cannot create reminders")
        default: throw DiagnosticSkip(reason: "not asked yet. Ask a bot to remind you of something to be asked.")
        }
    }

    static func reminderWrite() async throws -> String {
        let key = "diagnostics-\(UUID().uuidString)"
        let due = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        _ = try await AppleToolHosts.make().notes.upsertReminder(title: "DurableAgents diagnostics", due: due, effectKey: key)
        let found = await AppleData.removeReminder(notes: key)
        try expect(found.exists, "the reminder was not saved")
        try expect(found.hasDue, "the reminder has no due time")
        try expect(found.hasAlarm, "the reminder has no alert")
        return "created with due time and alert, then deleted"
    }

    static func eventWrite() async throws -> String {
        let key = "diagnostics-\(UUID().uuidString)"
        var calendar = Calendar.current
        calendar.timeZone = .current
        let start = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: Date())!)!
        _ = try await AppleToolHosts.make().calendar.upsert(title: "DurableAgents diagnostics", start: start, minutes: 30, effectKey: key)
        let found = AppleData.removeEvent(notes: key)
        try expect(found.start == start && found.end == start.addingTimeInterval(1800), "landed at \(found.start.map { ToolDates.describe($0) } ?? "nowhere")")
        return "created tomorrow 15:00–15:30, then deleted"
    }
}

private struct DiagnosticsSecretStore: SecretStore {
    var model: AssistantModel

    func secret(for reference: any SecretReference) async throws -> String {
        guard let value = await model.diagnosticsSecret(reference.account) else {
            throw DiagnosticFailure("no key for \(reference.account)")
        }
        return value
    }
}

/// EventKit calls back on its own queue, so these helpers are not main-actor isolated.
private enum AppleData {
    struct ReminderState: Sendable {
        var exists = false
        var hasDue = false
        var hasAlarm = false
    }

    nonisolated static func removeReminder(notes: String) async -> ReminderState {
        let store = EKEventStore()
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: nil)) { @Sendable found in
                var state = ReminderState()
                for reminder in found ?? [] where reminder.notes == notes {
                    state = ReminderState(exists: true, hasDue: reminder.dueDateComponents?.hour != nil, hasAlarm: !(reminder.alarms ?? []).isEmpty)
                    try? store.remove(reminder, commit: true)
                }
                continuation.resume(returning: state)
            }
        }
    }

    nonisolated static func removeEvent(notes: String) -> (start: Date?, end: Date?) {
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(3 * 86_400), calendars: nil)
        var result: (Date?, Date?) = (nil, nil)
        for event in store.events(matching: predicate) where event.notes == notes {
            result = (event.startDate, event.endDate)
            try? store.remove(event, span: .thisEvent, commit: true)
        }
        return result
    }
}
