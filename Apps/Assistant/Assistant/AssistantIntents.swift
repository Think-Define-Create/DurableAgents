import AppIntents
import Foundation

struct AskAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Assistant"
    static let description = IntentDescription("Send a message to Assistant.")

    @Parameter(title: "Message")
    var message: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = self.message
        let text: String
        if #available(iOS 27, macOS 27, *) {
            // A reply can outlast Siri's foreground window. iOS 27 lets it finish in the background.
            text = try await performBackgroundTask { await AssistantActions.ask(message) }
        } else {
            text = await AssistantActions.ask(message)
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

@available(iOS 27, macOS 27, *)
extension AskAssistantIntent: LongRunningIntent {}

struct RunRoutineIntent: AppIntent {
    static let title: LocalizedStringResource = "Run routine now"
    static let description = IntentDescription("Catch up due routines. This does not promise a future wake.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text: String
        if #available(iOS 27, macOS 27, *) {
            text = try await performBackgroundTask { await AssistantActions.catchUp() }
        } else {
            text = await AssistantActions.catchUp()
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

@available(iOS 27, macOS 27, *)
extension RunRoutineIntent: LongRunningIntent {}

struct ApprovePendingIntent: AppIntent {
    static let title: LocalizedStringResource = "Approve pending request"
    static let description = IntentDescription("Approve the oldest standard-risk request. High-risk requests stay in the app.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = await AssistantActions.approveFirst()
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct AssistantShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAssistantIntent(),
            phrases: ["Ask \(.applicationName)"],
            shortTitle: "Ask Assistant",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: RunRoutineIntent(),
            phrases: ["Run a routine in \(.applicationName)"],
            shortTitle: "Run routine now",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: ApprovePendingIntent(),
            phrases: ["Approve a request in \(.applicationName)"],
            shortTitle: "Approve pending request",
            systemImageName: "checkmark.shield"
        )
    }
}

@MainActor
enum AssistantActions {
    static func ask(_ message: String) async -> String {
        guard let model = AssistantRuntime.model else { return "Assistant is not open yet." }
        if model.phase == .loading { await model.bootstrap() }
        model.draft = message
        await model.send()
        return model.messages.last(where: { $0.role != "user" })?.text ?? "Sent."
    }

    static func catchUp() async -> String {
        guard let model = AssistantRuntime.model else { return "Assistant is not open yet." }
        if model.phase == .loading { await model.bootstrap() }
        await model.catchUp()
        return model.lastCatchUp
    }

    static func approveFirst() async -> String {
        guard let model = AssistantRuntime.model else { return "Assistant is not open yet." }
        await model.reload()
        guard let item = model.inbox.first(where: { $0.risk != "high" }) else {
            return model.inbox.isEmpty ? "Nothing is waiting." : "The waiting request is high risk. Open Assistant to approve it."
        }
        await model.decide(token: item.token, approved: true, highRisk: false)
        return "Resolved \(item.prompt)"
    }
}
