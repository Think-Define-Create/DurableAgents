import AppIntents
import AgentAppCore

struct AskAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask my agent"
    static let description = IntentDescription("Send a message to a Lumen agent.")

    @Parameter(title: "Message")
    var message: String

    @Parameter(title: "Agent")
    var agent: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await LumenActions.ask(agent: agent, message: message)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct ApprovePendingIntent: AppIntent {
    static let title: LocalizedStringResource = "Approve pending request"
    static let description = IntentDescription("Approve the oldest standard-risk request.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await LumenActions.approveFirst()
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct AgentStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "What is my agent doing"
    static let description = IntentDescription("Summarize running agents and pending approvals.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = await LumenActions.status()
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct LumenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAgentIntent(),
            phrases: ["Ask my agent with \(.applicationName)"],
            shortTitle: "Ask my agent",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: ApprovePendingIntent(),
            phrases: ["Approve pending request in \(.applicationName)"],
            shortTitle: "Approve pending request",
            systemImageName: "checkmark.shield"
        )
        AppShortcut(
            intent: AgentStatusIntent(),
            phrases: ["What is my agent doing in \(.applicationName)"],
            shortTitle: "What is my agent doing",
            systemImageName: "waveform"
        )
    }
}

enum LumenActions {
    @MainActor
    static func ask(agent: String, message: String) async throws -> String {
        guard let model = LumenRuntime.model else { return "Lumen is not open yet." }
        if model.phase == .loading { await model.bootstrap() }
        if let match = model.agents.first(where: { $0.title.caseInsensitiveCompare(agent) == .orderedSame }) {
            await model.select(match.id)
        } else if model.selectedID == nil, let first = model.agents.first {
            await model.select(first.id)
        }
        await model.send(message)
        return model.messages.last(where: { $0.role != "user" })?.text ?? "Sent."
    }

    @MainActor
    static func approveFirst() async throws -> String {
        guard let model = LumenRuntime.model else { return "Lumen is not open yet." }
        await model.reload()
        guard let item = model.inbox.first(where: { $0.risk != "high" }) ?? model.inbox.first else {
            return "Nothing is waiting."
        }
        await model.decide(token: item.token, approved: true, highRisk: item.risk == "high")
        return "Resolved \(item.prompt)"
    }

    @MainActor
    static func status() async -> String {
        guard let model = LumenRuntime.model else { return "Lumen is not open yet." }
        await model.reload()
        return "\(model.agents.count) agents, \(model.inbox.count) waiting for approval."
    }
}
