import DurableCore
import Foundation
import ModelKit

/// Why a conversation is running. Bot messages and routines run in their own conversations.
public enum TurnKind: Sendable, Equatable {
    case chat
    case botMessage(from: String)
    case routine
}

/// What the app needs to build the extra instructions for one model call.
public struct TurnContext: Sendable {
    public var agent: AgentProfile?
    public var conversationID: String
    public var latestUserText: String
    public var kind: TurnKind
    /// True for the on-device model, whose whole context window is about 4,096 tokens.
    public var compact: Bool

    public init(agent: AgentProfile?, conversationID: String, latestUserText: String, kind: TurnKind, compact: Bool) {
        self.agent = agent
        self.conversationID = conversationID
        self.latestUserText = latestUserText
        self.kind = kind
        self.compact = compact
    }
}

/// Returns text appended to the instructions of every model call, such as the soul, memories and skills.
public typealias ContextBuilder = @Sendable (TurnContext) async -> String

/// The session's agents, readable from the model step without calling back into the session.
public actor AgentRoster {
    private var agents: [AgentProfile] = []
    private var byConversation: [String: String] = [:]
    private var pending: String?

    public init() {}

    public func update(_ agents: [AgentProfile]) {
        self.agents = agents
        for agent in agents {
            if let conversationID = agent.conversationID {
                byConversation[conversationID] = agent.id
            }
        }
    }

    /// The agent the next new conversation belongs to.
    public func prepare(_ agentID: String) {
        pending = agentID
    }

    public func agent(id: String) -> AgentProfile? {
        agents.first { $0.id == id }
    }

    public func active() -> [AgentProfile] {
        agents.filter { !$0.archived }
    }

    /// The agent that owns a chat conversation. A conversation seen for the first time belongs
    /// to the agent the session prepared, as `ProviderTable` does for providers.
    public func owner(of conversationID: String) -> AgentProfile? {
        if let id = byConversation[conversationID] {
            return agent(id: id)
        }
        guard let pending else { return nil }
        byConversation[conversationID] = pending
        return agent(id: pending)
    }

    public func named(_ title: String) -> AgentProfile? {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return active().first { $0.title.lowercased() == needle }
    }
}

/// The first message of a bot-to-bot conversation carries who it is for, so the routing step can
/// pick the receiving bot's model and context even after a restart.
public enum BotMessage {
    public static let toolName = "bots.ask"

    static let prefix = "\u{27E6}bot "
    static let suffix = "\u{27E7}\n"

    public static func encode(to: String, from: String, text: String) -> String {
        prefix + to + " from " + from + suffix + text
    }

    /// Returns the receiver id, the sender id and the message without the header.
    public static func decode(_ text: String) -> (to: String, from: String, text: String)? {
        guard text.hasPrefix(prefix), let end = text.range(of: suffix) else { return nil }
        let header = text[text.index(text.startIndex, offsetBy: prefix.count)..<end.lowerBound]
        let parts = header.components(separatedBy: " from ")
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1], String(text[end.upperBound...]))
    }

    static func definition(for others: [AgentProfile]) -> ModelToolDefinition {
        let names = others.map(\.title)
        let list = names.map { "\"\($0)\"" }.joined(separator: ", ")
        return ModelToolDefinition(
            name: toolName,
            description: "Send a message to another bot and get its reply. Bots: \(names.joined(separator: ", ")).",
            parametersJSON: #"{"type":"object","properties":{"bot":{"type":"string","enum":["# + list + #"]},"message":{"type":"string"}},"required":["bot","message"]}"#
        )
    }
}

/// `Scheduler` starts each routine prompt with "Routine <id> for <agentID>."
public enum RoutinePrompt {
    /// The checklist alone, without the scheduler's bookkeeping lines.
    public static func checklist(in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "Checklist:") else { return text }
        return lines[(start + 1)...]
            .filter { !$0.hasPrefix("Call heartbeat.respond") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func agentID(in text: String) -> String? {
        for line in text.split(separator: "\n").prefix(3) where line.hasPrefix("Routine ") {
            guard let range = line.range(of: " for "), line.hasSuffix(".") else { continue }
            let id = line[range.upperBound...].dropLast()
            return id.isEmpty ? nil : String(id)
        }
        return nil
    }
}

/// The on-device model has a 4,096-token window and follows long tool lists poorly, so it is
/// offered only the tools a message is about. Cloud models see every tool.
public enum ToolRelevance {
    static let keywords: [String: [String]] = [
        BuiltinToolID.calendarRead: ["calendar", "schedule", "agenda", "event", "meeting", "appointment", "busy", "free", "today", "tomorrow", "this week", "next week", "weekend"],
        BuiltinToolID.calendarWrite: ["calendar", "schedule", "book", "event", "meeting", "appointment"],
        BuiltinToolID.reminder: ["remind", "reminder", "to-do", "todo", "don't forget", "dont forget"],
        BuiltinToolID.contactsSearch: ["phone", "number", "email", "contact", "address", "call ", "text "],
        BuiltinToolID.webFetch: ["http://", "https://", "www.", "website", "web page", "webpage"],
        "memory.remember": ["remember that", "don't forget that", "note that", "my name is", "call me", "i'm ", "i am ", "my favorite", "my favourite", "i like", "i love", "i hate", "my wife", "my husband", "my partner", "my dog", "my cat", "my son", "my daughter", "my birthday", "i live", "i work"],
    ]

    /// Tools with no keyword list, such as MCP tools the person added, are always offered.
    public static func filter(_ tools: [ModelToolSpec], message: String, botNames: [String]) -> [ModelToolSpec] {
        let text = message.lowercased()
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        // "Remind me tomorrow" is about Reminders, not the calendar.
        let reminder = keywords[BuiltinToolID.reminder]!.contains { text.contains($0) }
        return tools.filter { spec in
            guard let words = keywords[spec.name] else { return true }
            // "What is my favorite color?" asks; it does not tell a new fact.
            if spec.name == "memory.remember", question || reminder, !text.contains("remember that") { return false }
            if reminder, spec.name.hasPrefix("calendar.") || spec.name == BuiltinToolID.contactsSearch { return false }
            return words.contains { text.contains($0) }
        }
    }

    /// Whole words only, so a bot named "Cal" is not mentioned by "calendar".
    public static func mentionsBot(_ message: String, botNames: [String]) -> Bool {
        let text = message.lowercased()
        return botNames.contains { name in
            let needle = name.lowercased().trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { return false }
            var start = text.startIndex
            while let found = text.range(of: needle, range: start..<text.endIndex) {
                let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
                let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
                if !(before?.isLetter ?? false || before?.isNumber ?? false),
                   !(after?.isLetter ?? false || after?.isNumber ?? false) {
                    return true
                }
                start = found.upperBound
            }
            return false
        }
    }
}
