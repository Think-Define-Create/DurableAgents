import DurableCore
import DurableFoundationModels
import DurableKit
import DurableStore
import Foundation
import Observation
import UserNotifications

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
    let conversation: ConversationModel
    let world: EscrowWorld
    var errorMessage: String?
    private let router = NotificationRouter()
    private var postedApprovalToken: String?
    private static let approvalCategory = "escrow.approval"

    init(world: EscrowWorld, conversation: ConversationModel) {
        self.world = world
        self.conversation = conversation
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
        let store = try SQLiteEventStore(path: database)
        let world = EscrowWorld(directory: directory)
        let backend = makeBackend()
        let conversation = try await ConversationModel.open(
            store: store,
            tools: world.tools(),
            model: backend.model,
            backendLabel: backend.label
        )
        let app = AppModel(world: world, conversation: conversation)
        AppRuntime.current = app
        await app.installNotifications()
        return app
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

    private static func makeBackend() -> (model: any ModelStep, label: String) {
        if ProcessInfo.processInfo.arguments.contains("-UseScriptedModel") {
            return (EscrowScriptedModel(), "Scripted model (launch argument)")
        }
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            if FoundationModelsStep.isAvailable() {
                return (EscrowOnDeviceModel.make(), "On-device Foundation Model")
            }
            let reason = FoundationModelsStep.unavailableReason() ?? "The on-device model is unavailable."
            return (EscrowScriptedModel(), "Scripted fallback. \(reason)")
        }
        #endif
        return (EscrowScriptedModel(), "Scripted fallback. Foundation Models is not in this build.")
    }
}
