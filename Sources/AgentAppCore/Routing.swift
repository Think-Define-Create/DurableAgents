import DurableCore
import Foundation
import AgentLoop
import ModelKit

public actor LiveTranscript {
    private var text: [String: String] = [:]
    private var latestID: String = ""

    public init() {}

    public func append(conversationID: String, delta: String) {
        latestID = conversationID
        text[conversationID, default: ""] += delta
    }

    public func snapshot(conversationID: String) -> String {
        text[conversationID] ?? ""
    }

    public func latest() -> String {
        text[latestID] ?? ""
    }

    public func clear(conversationID: String) {
        text[conversationID] = nil
    }

    /// Starts a turn so `latest()` shows only this turn's text, not an earlier reply.
    public func beginTurn(conversationID: String?) {
        if let conversationID {
            text[conversationID] = nil
        }
        latestID = conversationID ?? ""
    }
}

public struct PublishingProvider: ModelProvider {
    public var inner: any ModelProvider
    public var transcript: LiveTranscript
    public var conversationID: String

    public init(inner: any ModelProvider, transcript: LiveTranscript, conversationID: String) {
        self.inner = inner
        self.transcript = transcript
        self.conversationID = conversationID
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let inner = self.inner
        let transcript = self.transcript
        let conversationID = self.conversationID
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in inner.stream(request) {
                        if case .textDelta(let delta) = event {
                            await transcript.append(conversationID: conversationID, delta: delta)
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Offline stand-in. A URL in the user text asks for `web.fetch`. "remind" asks for `notes.reminder`.
/// After a tool result it answers in text, or the same request would ask for the tool again forever.
public struct DemoChatProvider: ModelProvider {
    public var appleFallbackNote: Bool

    public init(appleFallbackNote: Bool = false) {
        self.appleFallbackNote = appleFallbackNote
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let text = request.messages.last(where: { $0.role == .user })?.text ?? ""
        let afterTool = request.messages.last?.role == .tool
        let note = appleFallbackNote
        return AsyncThrowingStream { continuation in
            let task = Task {
                if afterTool {
                    continuation.yield(.textDelta("Done."))
                } else if let url = Self.firstURL(in: text) {
                    let arguments = JSONValue.object(["url": .string(url)]).canonicalJSON()
                    continuation.yield(.toolCall(ProviderToolCall(id: "demo-web", name: BuiltinToolID.webFetch, argumentsJSON: arguments)))
                } else if text.lowercased().contains("remind") {
                    let arguments = JSONValue.object(["title": .string(text)]).canonicalJSON()
                    continuation.yield(.toolCall(ProviderToolCall(id: "demo-remind", name: BuiltinToolID.reminder, argumentsJSON: arguments)))
                } else {
                    let reply = (note ? "Offline demo. " : "") + "I can keep working after this app closes. You said: " + text
                    for word in reply.split(separator: " ") {
                        continuation.yield(.textDelta(String(word) + " "))
                    }
                    continuation.yield(.usage(ModelUsage(inputTokens: 0, outputTokens: reply.split(separator: " ").count)))
                }
                continuation.yield(.stop(StopReason(raw: "end_turn")))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func firstURL(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(token)
            if word.hasPrefix("https://") || word.hasPrefix("http://") {
                return word
            }
        }
        return nil
    }
}

public final class ProviderBuildCounter: @unchecked Sendable {
    public var count = 0
    public init() {}
}

/// Picks a provider per conversation. Cloud choices finish early when on-device only is on.
public struct RoutingModelStep: ModelStep {
    public var table: ProviderTable
    public var policy: PolicyBox
    public var secrets: any SecretStore
    public var transcript: LiveTranscript
    public var foundationModelsLinked: Bool
    public var apple: (@Sendable (ProviderChoice) -> (any ModelProvider)?)?
    public var builds: ProviderBuildCounter
    public var instructions: String
    public var roster: AgentRoster
    public var context: ContextBuilder?

    public static let defaultInstructions = "You are a personal agent. Use tools when they help. Do not invent tool results."

    /// Cloud models think before they answer, and thinking shares this budget with the reply.
    public static let cloudMaxOutputTokens = 16_000

    public init(
        table: ProviderTable,
        policy: PolicyBox,
        secrets: any SecretStore,
        transcript: LiveTranscript,
        foundationModelsLinked: Bool = false,
        apple: (@Sendable (ProviderChoice) -> (any ModelProvider)?)? = nil,
        builds: ProviderBuildCounter = ProviderBuildCounter(),
        instructions: String = RoutingModelStep.defaultInstructions,
        roster: AgentRoster = AgentRoster(),
        context: ContextBuilder? = nil
    ) {
        self.table = table
        self.policy = policy
        self.secrets = secrets
        self.transcript = transcript
        self.foundationModelsLinked = foundationModelsLinked
        self.apple = apple
        self.builds = builds
        self.instructions = instructions
        self.roster = roster
        self.context = context
    }

    /// Tools no model is offered. Document text needs the file's bytes, which the composer reads instead.
    public static let hiddenTools: Set<String> = [BuiltinToolID.documentOCR]
    /// Offered only to scheduled routines.
    public static let routineOnlyTools: Set<String> = ["heartbeat.respond"]

    /// The session passes this to the engine as `RunBudget.maxSteps`. The engine stops the run
    /// before the next plan, so a model that keeps asking for tools cannot run forever.
    public static let maxStepsPerRun = 25

    public static var turnBudget: RunBudget {
        RunBudget(maxSteps: maxStepsPerRun, onExceeded: .fail)
    }

    public func plan(context: ModelContext) async throws -> ScriptedStep {
        let raw = context.conversationID.raw
        var working = context
        var kind = TurnKind.chat
        var agent: AgentProfile?
        let firstUser = context.messages.first { $0.role == "user" }?.text ?? ""
        let latestIndex = context.messages.lastIndex { $0.role == "user" }
        // Messages from other bots carry a routing header. The newest one decides whether this
        // turn answers a bot; older ones are shown to the model as plain lines from that bot.
        for index in working.messages.indices where working.messages[index].role == "user" && index != latestIndex {
            if let message = BotMessage.decode(working.messages[index].text) {
                let sender = await roster.agent(id: message.from)?.title ?? "Another bot"
                // "Assistant" is also a role label in the on-device prompt, so the sender is named in full.
                working.messages[index].text = "Message from the bot named \(sender): \(message.text)"
            }
        }
        if let latestIndex, let message = BotMessage.decode(context.messages[latestIndex].text) {
            guard let receiver = await roster.agent(id: message.to), !receiver.archived else {
                let names = await roster.active().map(\.title).joined(separator: ", ")
                return .finish("There is no bot named \(message.to). The bots are: \(names).")
            }
            agent = receiver
            let sender = await roster.agent(id: message.from)?.title ?? "Another bot"
            kind = .botMessage(from: sender)
            // Said as "user:" the question reads as the person's own words, and a small model then
            // copies its last reply to the person. Naming the sender keeps the two apart.
            working.messages[latestIndex].text = "\(sender) (another bot) asks: \(message.text)"
        } else if let id = RoutinePrompt.agentID(in: firstUser), let owner = await roster.agent(id: id) {
            agent = owner
            kind = .routine
            if let index = working.messages.firstIndex(where: { $0.role == "user" }) {
                working.messages[index].text = "Scheduled routine. Checklist:\n" + RoutinePrompt.checklist(in: firstUser)
            }
        } else {
            agent = await roster.owner(of: raw)
        }
        // The routing header added to a bot message is not shown back to the asking model.
        for index in working.completedTools.indices where working.completedTools[index].name == BotMessage.toolName {
            if var arguments = working.completedTools[index].arguments.objectValue {
                arguments["goal"] = nil
                arguments["conversation"] = nil
                working.completedTools[index].arguments = .object(arguments)
            }
        }
        let choice: ProviderChoice
        if kind != .chat, let agent {
            choice = agent.provider
        } else {
            choice = await table.choice(for: raw)
        }
        if await policy.onDeviceOnly, OnDevicePolicy.blocksCloud(choice) {
            return .finish("On-device only is on. Switch this agent to Apple on-device or the offline demo before using a cloud model.")
        }
        let onDevice = OnDevicePolicy.isSmallModel(choice)
        let offline = await policy.onDeviceOnly
        working.tools = context.tools.filter { spec in
            if Self.hiddenTools.contains(spec.name) { return false }
            if Self.routineOnlyTools.contains(spec.name) { return kind == .routine }
            if spec.name == BuiltinToolID.webFetch, offline { return false }
            return true
        }
        var extra: [ModelToolDefinition] = []
        var others: [AgentProfile] = []
        if case .botMessage = kind {
            // A bot answering another bot does not start a third conversation.
        } else if let agent {
            others = await roster.active().filter { $0.id != agent.id }
        }
        let latest = working.messages.last { $0.role == "user" }?.text ?? ""
        if onDevice {
            if !working.completedTools.isEmpty {
                // The small model tends to call the same tool again. Once a result is in, it answers.
                working.tools = []
                others = []
            } else if kind == .routine {
                // The reply text becomes the notification, so the small model skips heartbeat.respond.
                working.tools = ToolRelevance.filter(working.tools, message: RoutinePrompt.checklist(in: firstUser), botNames: [])
                    .filter { ToolRelevance.keywords[$0.name] != nil && $0.name != "memory.remember" }
                others = []
            } else {
                working.tools = ToolRelevance.filter(working.tools, message: latest, botNames: others.map(\.title))
                if !ToolRelevance.mentionsBot(latest, botNames: others.map(\.title)) {
                    others = []
                }
            }
        }
        if !others.isEmpty {
            extra.append(BotMessage.definition(for: others))
        }
        let text = await instructions(for: agent, kind: kind, context: working, compact: onDevice)
        let provider = makeProvider(choice)
        builds.count += 1
        let publishing = PublishingProvider(
            inner: WireToolNames(inner: provider),
            transcript: transcript,
            conversationID: raw
        )
        let step = AgentLoopStep(
            provider: publishing,
            modelName: choice.model,
            instructions: text,
            maxOutputTokens: OnDevicePolicy.blocksCloud(choice) ? Self.cloudMaxOutputTokens : 1024,
            subagentTools: extra.isEmpty ? [] : [BotMessage.toolName],
            extraTools: extra
        )
        var planned = try await step.plan(context: working)
        if case .finish(let text) = planned {
            let offered = working.tools.map(\.name) + extra.map(\.name)
            if let call = Self.toolCallWrittenAsText(text, offered: offered) {
                planned = .providerTurn(ProviderTurnStep(text: "", calls: [
                    PlannedCall(name: call.name, callID: "text-" + UUID().uuidString.lowercased(), arguments: call.arguments, subagent: call.name == BotMessage.toolName),
                ]))
            }
        }
        // "Ask Cal …" is an instruction to message Cal. The small model sometimes answers from
        // shared memory instead, so a direct request to a named bot is sent even then.
        if case .finish = planned, working.completedTools.isEmpty, extra.contains(where: { $0.name == BotMessage.toolName }),
           let direct = Self.directBotRequest(latest, botNames: others.map(\.title)) {
            planned = .providerTurn(ProviderTurnStep(text: "", calls: [
                PlannedCall(
                    name: BotMessage.toolName,
                    callID: "direct-" + UUID().uuidString.lowercased(),
                    arguments: .object(["bot": .string(direct.bot), "message": .string(direct.message)]),
                    subagent: true
                ),
            ]))
        }
        if case .finish(let text) = planned {
            planned = .finish(Self.withoutSpeakerLabel(text, names: ["assistant", agent?.title ?? ""]))
        }
        guard case .providerTurn(var turn) = planned, let sender = agent else { return planned }
        // The small model sometimes repeats its previous call's bot or question. When the person
        // wrote "ask <bot> …", that bot is used, and a question that shares no word with the request
        // is replaced by the person's own words.
        if working.completedTools.isEmpty, let direct = Self.directBotRequest(latest, botNames: others.map(\.title)) {
            for index in turn.calls.indices where turn.calls[index].name == BotMessage.toolName {
                var arguments = turn.calls[index].arguments.objectValue ?? [:]
                arguments["bot"] = .string(direct.bot)
                let asked = arguments["message"]?.stringValue ?? ""
                if !Self.sharesContentWord(asked, latest) {
                    arguments["message"] = .string(direct.message)
                }
                turn.calls[index].arguments = .object(arguments)
            }
        }
        for index in turn.calls.indices where turn.calls[index].name == BotMessage.toolName {
            let arguments = turn.calls[index].arguments.objectValue ?? [:]
            let name = arguments["bot"]?.stringValue ?? ""
            let message = arguments["message"]?.stringValue ?? ""
            let found = await roster.named(name)
            let receiver = found?.id ?? name
            var rewritten = arguments
            rewritten["goal"] = .string(BotMessage.encode(to: receiver, from: sender.id, text: message))
            // The message goes into the other bot's own chat, so the person sees it there.
            if let conversationID = found?.conversationID, found?.id != sender.id {
                rewritten["conversation"] = .string(conversationID)
            }
            turn.calls[index].arguments = .object(rewritten)
        }
        // Small models often drop the time from "remind me tomorrow at 9am". Without it a reminder
        // never alerts and an event lands at the wrong time, so take it from the person's own words.
        let timed = [BuiltinToolID.reminder: "due", BuiltinToolID.calendarWrite: "start"]
        let said = working.messages.last { $0.role == "user" }?.text ?? ""
        for index in turn.calls.indices {
            guard let key = timed[turn.calls[index].name] else { continue }
            var arguments = turn.calls[index].arguments.objectValue ?? [:]
            let given = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard given.isEmpty, let date = ToolDates.natural(said) else { continue }
            arguments[key] = .string(ToolDates.local(date))
            turn.calls[index].arguments = .object(arguments)
        }
        return .providerTurn(turn)
    }

    private static let commonWords: Set<String> = [
        "what", "when", "where", "which", "while", "with", "that", "this", "these", "those", "your", "yours",
        "have", "does", "know", "about", "tell", "from", "there", "their", "they", "them", "will", "would",
        "could", "should", "please", "person", "wants", "just", "like", "some",
    ]

    /// True when both texts share a word of four or more letters that is not a common question word.
    static func sharesContentWord(_ left: String, _ right: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 && !commonWords.contains($0) })
        }
        return !words(left).isDisjoint(with: words(right))
    }

    /// "Ask Cal what my dog's name is" gives ("Cal", "The person wants to know what my dog's name is.").
    /// Only a message that starts with ask, tell or message and a bot's exact name counts.
    public static func directBotRequest(_ text: String, botNames: [String]) -> (bot: String, message: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for verb in ["ask", "tell", "message"] {
            for name in botNames.sorted(by: { $0.count > $1.count }) {
                let prefix = "\(verb) \(name)"
                guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { continue }
                var rest = trimmed.dropFirst(prefix.count)
                guard rest.isEmpty || rest.first?.isLetter == false else { continue }
                rest = rest.drop { $0 == " " || $0 == "," || $0 == ":" }
                let body = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                let lead = verb == "ask" ? "The person wants to know " : "The person says: "
                return (name, lead + body)
            }
        }
        return nil
    }

    /// The on-device model sometimes writes a call as text, such as `memory_remember{fact: "green"}`,
    /// instead of calling the tool. Only a tool offered on this turn is accepted. Keys may be unquoted.
    public static func toolCallWrittenAsText(_ text: String, offered: [String]) -> (name: String, arguments: JSONValue)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "{"), trimmed.hasSuffix("}") else { return nil }
        let written = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        guard !written.isEmpty, written.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }) else { return nil }
        guard let name = offered.first(where: { $0 == written || WireToolNames.wireName($0) == written }) else { return nil }
        let body = String(trimmed[open...])
        if let value = try? JSONValue.parse(body), value.objectValue != nil {
            return (name, value)
        }
        // Quote bare keys: {fact: "x"} becomes {"fact": "x"}.
        let quoted = body.replacingOccurrences(
            of: #"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#,
            with: "$1\"$2\":",
            options: .regularExpression
        )
        guard let value = try? JSONValue.parse(quoted), value.objectValue != nil else { return nil }
        return (name, value)
    }

    /// The on-device prompt is a flat "role: text" transcript, so replies sometimes start with
    /// "assistant:" or the bot's name. The label is not part of the answer.
    static func withoutSpeakerLabel(_ text: String, names: [String]) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for name in names where !name.isEmpty {
            let label = name.lowercased() + ":"
            if trimmed.lowercased().hasPrefix(label) {
                trimmed = String(trimmed.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed
    }

    private func instructions(for agent: AgentProfile?, kind: TurnKind, context: ModelContext, compact: Bool) async -> String {
        var parts = [instructions]
        if let agent {
            parts.append("Your name is \(agent.title).")
        }
        switch kind {
        case .chat:
            break
        case .botMessage(let from):
            parts.append("\(from), another bot, sent you the last message. Answer it directly from what you know, including what the person told you earlier in this chat. Give the actual answer, not an acknowledgement. Your reply goes back to \(from).")
        case .routine where compact:
            parts.append("This is a scheduled routine, not a chat. Do the checklist and reply with one short message for the person. Reply with exactly NO_REPLY when there is nothing to report.")
        case .routine:
            parts.append("This is a scheduled routine, not a chat. Do the checklist, then call heartbeat.respond with notify and a short text, or noReply when there is nothing to report.")
        }
        if let builder = self.context {
            let latest = context.messages.last { $0.role == "user" }?.text ?? ""
            let extra = await builder(TurnContext(
                agent: agent,
                conversationID: context.conversationID.raw,
                latestUserText: latest,
                kind: kind,
                compact: compact
            ))
            if !extra.isEmpty {
                parts.append(extra)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private func makeProvider(_ choice: ProviderChoice) -> any ModelProvider {
        switch choice.kind {
        case .scripted:
            return DemoChatProvider()
        case .apple:
            if foundationModelsLinked, let apple, let provider = apple(choice) {
                return provider
            }
            return DemoChatProvider(appleFallbackNote: true)
        case .anthropic:
            return AnthropicMessages(
                apiKey: NamedSecret(account: choice.secretAccount ?? "ANTHROPIC_API_KEY"),
                secrets: secrets
            )
        case .openai:
            return OpenAIResponses(
                apiKey: NamedSecret(account: choice.secretAccount ?? "OPENAI_API_KEY"),
                secrets: secrets
            )
        case .compatible:
            let base = URL(string: choice.baseURL ?? CompatibleChatEndpoint.ollama.absoluteString) ?? CompatibleChatEndpoint.ollama
            return OpenAICompatibleChat(
                apiKey: NamedSecret(account: choice.secretAccount ?? "OPENAI_API_KEY"),
                secrets: secrets,
                baseURL: base
            )
        }
    }
}

public struct UsageSummary: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var estimatedUSD: Double
    /// Always an illustration. Scripted and Apple on-device prices are zero.
    public var note: String

    public init(inputTokens: Int, outputTokens: Int, estimatedUSD: Double, note: String) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedUSD = estimatedUSD
        self.note = note
    }
}

public enum UsageLedger {
    public static let note = "Illustrative estimate, not a bill. Scripted and on-device Apple usage is priced at zero."

    /// Dollars per million tokens, input then output. Labeled estimates only.
    public static func rates(for kind: ProviderKind) -> (input: Double, output: Double) {
        switch kind {
        case .anthropic: (3, 15)
        case .openai: (2.5, 10)
        case .compatible: (1, 3)
        case .scripted, .apple: (0, 0)
        }
    }

    public static func summarize(events: [EventEnvelope], provider: ProviderKind) -> UsageSummary {
        var input = 0
        var output = 0
        for event in events where event.type == EventType.stepPlanned {
            guard let step = event.payload["step"]?.objectValue else { continue }
            input += Int(step["inputTokens"]?.intValue ?? 0)
            output += Int(step["outputTokens"]?.intValue ?? 0)
        }
        let rates = rates(for: provider)
        let dollars = (Double(input) * rates.input + Double(output) * rates.output) / 1_000_000
        return UsageSummary(inputTokens: input, outputTokens: output, estimatedUSD: dollars, note: note)
    }
}

public struct InboxItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var agentID: String
    public var agentTitle: String
    public var prompt: String
    public var risk: String
    public var requiredAuth: String
    public var purpose: String
    public var expiresAt: Date?
    public var escalateTo: String?
    public var conversationID: String
    public var token: String

    public init(
        id: String,
        agentID: String,
        agentTitle: String,
        prompt: String,
        risk: String,
        requiredAuth: String,
        purpose: String,
        expiresAt: Date?,
        escalateTo: String?,
        conversationID: String,
        token: String
    ) {
        self.id = id
        self.agentID = agentID
        self.agentTitle = agentTitle
        self.prompt = prompt
        self.risk = risk
        self.requiredAuth = requiredAuth
        self.purpose = purpose
        self.expiresAt = expiresAt
        self.escalateTo = escalateTo
        self.conversationID = conversationID
        self.token = token
    }
}

public enum ApprovalInbox {
    public static func pending(events: [EventEnvelope], agents: [AgentProfile], now: Date = Date()) -> [InboxItem] {
        var resolved: Set<String> = []
        for event in events where event.type == EventType.approvalResolved {
            if let id = event.payload["approvalID"]?.stringValue {
                resolved.insert(event.stream.raw + ":" + id)
            }
        }
        var items: [InboxItem] = []
        for event in events where event.type == EventType.approvalRequested {
            guard let approvalID = event.payload["approvalID"]?.stringValue else { continue }
            let key = event.stream.raw + ":" + approvalID
            if resolved.contains(key) { continue }
            var expiresAt: Date?
            if let raw = seconds(event.payload["expiresAt"]) {
                expiresAt = Date(timeIntervalSince1970: raw)
            }
            if let expiresAt, expiresAt <= now { continue }
            let conversationID = event.stream.raw
            let agent = agents.first { $0.conversationID == conversationID }
            items.append(InboxItem(
                id: key,
                agentID: agent?.id ?? "",
                agentTitle: agent?.title ?? conversationID,
                prompt: event.payload["prompt"]?.stringValue ?? "",
                risk: event.payload["risk"]?.stringValue ?? ApprovalRisk.standard.rawValue,
                requiredAuth: event.payload["requiredAuth"]?.stringValue ?? AuthenticationLevel.session.rawValue,
                purpose: event.payload["purpose"]?.stringValue ?? "",
                expiresAt: expiresAt,
                escalateTo: event.payload["escalateTo"]?.stringValue,
                conversationID: conversationID,
                token: event.payload["token"]?.stringValue ?? ""
            ))
        }
        return items
    }

    private static func seconds(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        if let int = value.intValue { return Double(int) }
        if case .double(let number) = value { return number }
        return nil
    }
}

public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public var pendingApprovals: Int
    public var runningAgents: Int
    public var prompts: [String]

    public init(pendingApprovals: Int, runningAgents: Int, prompts: [String]) {
        self.pendingApprovals = pendingApprovals
        self.runningAgents = runningAgents
        self.prompts = prompts
    }

    public func write(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> WidgetSnapshot {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

public struct AuditBundle: Sendable, Equatable {
    public var jsonl: String
    public var intact: Bool
    public var tip: String
    public var problems: [String]

    public init(jsonl: String, intact: Bool, tip: String, problems: [String]) {
        self.jsonl = jsonl
        self.intact = intact
        self.tip = tip
        self.problems = problems
    }
}

public struct RunEvent: Sendable, Equatable, Identifiable {
    public var id: UInt64
    public var type: String
    public var summary: String

    public init(id: UInt64, type: String, summary: String) {
        self.id = id
        self.type = type
        self.summary = summary
    }
}
