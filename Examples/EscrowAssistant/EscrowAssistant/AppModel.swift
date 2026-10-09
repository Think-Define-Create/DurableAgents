import DurableCore
import DurableFoundationModels
import DurableKit
import DurableSecurity
import DurableStore
import Foundation
import Observation
import AgentLoop
import ModelKit
import UserNotifications

enum EscrowProvider: String, CaseIterable, Identifiable {
    case apple
    case anthropic
    case openai
    case scripted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple on-device"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .scripted: "Scripted"
        }
    }
}

@MainActor
enum AppRuntime {
    static var current: AppModel?

    static func handle(_ action: String) async {
        await current?.handleNotification(action)
    }
}

final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await AppRuntime.handle(response.actionIdentifier)
    }
}

@Observable
@MainActor
final class AppModel {
    var conversation: ConversationModel
    let world: EscrowWorld
    var provider: EscrowProvider
    var errorMessage: String?
    private let store: any EventStore
    private let router = NotificationRouter()
    private var postedApprovalToken: String?
    private static let approvalCategory = "escrow.approval"
    private static let providerKey = "escrow.provider"

    init(world: EscrowWorld, conversation: ConversationModel, store: any EventStore, provider: EscrowProvider) {
        self.world = world
        self.conversation = conversation
        self.store = store
        self.provider = provider
    }

    static func launch() async throws -> AppModel {
        let directory = try EscrowWorld.supportDirectory()
        if ProcessInfo.processInfo.arguments.contains("-ResetJournal") {
            let files = ["escrow.sqlite", "escrow.sqlite-wal", "escrow.sqlite-shm", "outbox.json", "closings.json"]
            for name in files {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        let database = directory.appendingPathComponent("escrow.sqlite").path
        let sqlite = try SQLiteEventStore(path: database)
        let keys = try makeKeys(directory: directory)
        let store = EncryptingEventStore(inner: sqlite, keys: keys, redactor: BuiltInRedactor())
        let world = EscrowWorld(directory: directory)
        let provider = selectedProvider()
        let backend = makeBackend(provider)
        let conversation = try await ConversationModel.open(
            store: store,
            tools: world.tools(),
            model: backend.model,
            backendLabel: backend.label
        )
        let app = AppModel(world: world, conversation: conversation, store: store, provider: provider)
        AppRuntime.current = app
        await app.installNotifications()
        return app
    }

    func select(_ provider: EscrowProvider) async {
        self.provider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
        await conversation.close()
        let backend = Self.makeBackend(provider)
        do {
            conversation = try await ConversationModel.open(
                store: store,
                tools: world.tools(),
                model: backend.model,
                backendLabel: backend.label
            )
            errorMessage = nil
            await postApprovalIfNeeded()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    var showsRecovery: Bool {
        let events = conversation.events
        let reconciled = events.filter {
            $0.type == EventType.effectResult && $0.payload["reconciled"]?.boolValue == true
        }
        for result in reconciled {
            let callID = result.payload["callID"]?.stringValue
            let intent = events.first {
                $0.type == EventType.effectIntent && $0.payload["callID"]?.stringValue == callID
            }
            if intent?.payload["tool"]?.stringValue == "sendEmail" {
                return true
            }
        }
        return false
    }

    func send(_ text: String) async {
        do {
            try await conversation.send(text)
            errorMessage = nil
            await postApprovalIfNeeded()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func approve() async {
        do {
            guard let pending = conversation.pendingApproval else { return }
            if pending.risk == .high {
                #if canImport(LocalAuthentication)
                guard let level = await EscrowBiometricGate.evaluate(reason: pending.prompt) else {
                    errorMessage = "Face ID or a device passcode is required for this approval."
                    return
                }
                guard level >= pending.requiredAuth else {
                    errorMessage = "This approval needs \(pending.requiredAuth.rawValue) authentication."
                    return
                }
                try await conversation.approve(as: Approver(id: "device-owner", authLevel: level))
                #else
                errorMessage = "This build cannot confirm a high-risk approval."
                return
                #endif
            } else {
                try await conversation.approve(as: Approver(id: "app-user", authLevel: .session))
            }
            errorMessage = nil
            await postApprovalIfNeeded()
            await syncLiveActivity()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func reject() async {
        do {
            try await conversation.reject("denied in the app")
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func crashNow() async {
        world.armCrash()
        let callID = "crash-" + UUID().uuidString.lowercased()
        let submission = Submission(
            requestID: "crash-" + UUID().uuidString.lowercased(),
            text: "Send the escrow email to the buyer.",
            script: Script(steps: [
                .tool(
                    name: "sendEmail",
                    callID: callID,
                    arguments: .object([
                        "to": .string("buyer@example.com"),
                        "subject": .string("Escrow update"),
                        "body": .string("The wire instructions are ready."),
                    ])
                ),
                .finish("Email handed to the outbox."),
            ])
        )
        do {
            try await conversation.submitScripted(submission)
            errorMessage = "The process was supposed to terminate after the outbox write."
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func handleNotification(_ action: String) async {
        switch action {
        case "approve":
            await approve()
        case "reject":
            await reject()
        default:
            break
        }
    }

    private func installNotifications() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = router
        let approve = UNNotificationAction(identifier: "approve", title: "Approve", options: [.foreground])
        let reject = UNNotificationAction(
            identifier: "reject",
            title: "Reject",
            options: [.destructive, .foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.approvalCategory,
            actions: [approve, reject],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await postApprovalIfNeeded()
    }

    private func postApprovalIfNeeded() async {
        guard let pending = conversation.pendingApproval else { return }
        if postedApprovalToken == pending.token.raw { return }
        postedApprovalToken = pending.token.raw
        let notice = ApprovalNotice(
            conversationID: "",
            runID: "",
            approvalID: pending.approvalID,
            prompt: pending.prompt,
            risk: pending.risk,
            purpose: "human",
            token: pending.token.raw,
            expiresAt: nil,
            audience: nil
        )
        let draft = LocalNotificationDraft.make(notice)
        let content = UNMutableNotificationContent()
        content.title = draft.title
        content.body = draft.body
        content.sound = .default
        content.categoryIdentifier = Self.approvalCategory
        content.userInfo = ["token": pending.token.raw]
        await syncLiveActivity()
        let request = UNNotificationRequest(identifier: pending.token.raw, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func syncLiveActivity() async {
        if #available(iOS 16.2, *) {
            if let pending = conversation.pendingApproval {
                EscrowLiveActivity.showPending(prompt: pending.prompt)
            } else if conversation.status == .running {
                EscrowLiveActivity.showProgress("Working")
            } else {
                EscrowLiveActivity.end(detail: conversation.status == .failed ? "Failed" : "Done")
            }
        }
    }

    private static func selectedProvider() -> EscrowProvider {
        if ProcessInfo.processInfo.arguments.contains("-UseScriptedModel") {
            return .scripted
        }
        let raw = UserDefaults.standard.string(forKey: providerKey) ?? EscrowProvider.scripted.rawValue
        return EscrowProvider(rawValue: raw) ?? .scripted
    }

    private static func makeKeys(directory: URL) throws -> any ConversationKeyProvider {
        #if canImport(Security)
        return KeychainKeyProvider(service: "EscrowAssistant.keys")
        #else
        return try FileKeyProvider(directory: directory.appendingPathComponent("keys", isDirectory: true))
        #endif
    }

    private static func makeBackend(_ provider: EscrowProvider) -> (model: any ModelStep, label: String) {
        let instructions = """
        You are an escrow assistant in a demo. Use only the provided tools. \
        lookupProperty is read-only. sendEmail sends one message. scheduleClosing books a closing \
        and needs approval id \(EscrowScriptedModel.closingApprovalID) first. \
        Do not invent records, emails, or dates.
        """
        switch provider {
        case .scripted:
            return (EscrowScriptedModel(), "Scripted planner")
        case .anthropic:
            let step = gated(AgentLoopStep(
                provider: AnthropicMessages(
                    apiKey: NamedSecret(account: "ANTHROPIC_API_KEY"),
                    secrets: secretStore()
                ),
                modelName: "claude-sonnet-4-5",
                instructions: instructions
            ))
            return (step, "Anthropic via AgentLoop. Key: ANTHROPIC_API_KEY")
        case .openai:
            let step = gated(AgentLoopStep(
                provider: OpenAIResponses(
                    apiKey: NamedSecret(account: "OPENAI_API_KEY"),
                    secrets: secretStore()
                ),
                modelName: "gpt-4.1",
                instructions: instructions
            ))
            return (step, "OpenAI via AgentLoop. Key: OPENAI_API_KEY")
        case .apple:
            #if canImport(FoundationModels)
            if #available(iOS 26, macOS 26, *), FoundationModelsStep.isAvailable() {
                let step = gated(AgentLoopStep(
                    provider: FoundationModelsProvider(
                        instructions: instructions,
                        makeTools: { capture in
                            [
                                LookupPropertyFMTool(capture: capture),
                                SendEmailFMTool(capture: capture),
                                ScheduleClosingFMTool(capture: capture),
                            ]
                        }
                    ),
                    modelName: "apple-on-device",
                    instructions: instructions
                ))
                return (step, "Apple on-device via AgentLoop")
            }
            let reason = FoundationModelsStep.unavailableReason() ?? "The on-device model is unavailable."
            return (EscrowScriptedModel(), "Scripted fallback. \(reason)")
            #else
            return (EscrowScriptedModel(), "Scripted fallback. Foundation Models is not in this build.")
            #endif
        }
    }

    private static func secretStore() -> any SecretStore {
        #if canImport(Security)
        return KeychainSecretStore(service: "EscrowAssistant")
        #else
        return EnvironmentSecretStore()
        #endif
    }

    private static func gated(_ step: AgentLoopStep) -> any ModelStep {
        ClosingApprovalGate(inner: step)
    }
}

/// Holds scheduleClosing until this run has the closing approval.
private struct ClosingApprovalGate: ModelStep {
    var inner: AgentLoopStep

    func plan(context: ModelContext) async throws -> ScriptedStep {
        let step = try await inner.plan(context: context)
        guard case .providerTurn(let turn) = step else { return step }
        let wantsClosing = turn.calls.contains { $0.name == "scheduleClosing" }
        let approved = context.grantedApprovalIDs.contains(EscrowScriptedModel.closingApprovalID)
        if wantsClosing && !approved {
            return .approval(
                id: EscrowScriptedModel.closingApprovalID,
                prompt: EscrowScriptedModel.closingPrompt,
                risk: .high
            )
        }
        return step
    }
}
