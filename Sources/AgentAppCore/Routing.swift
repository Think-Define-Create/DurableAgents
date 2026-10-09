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

    public init(
        table: ProviderTable,
        policy: PolicyBox,
        secrets: any SecretStore,
        transcript: LiveTranscript,
        foundationModelsLinked: Bool = false,
        apple: (@Sendable (ProviderChoice) -> (any ModelProvider)?)? = nil,
        builds: ProviderBuildCounter = ProviderBuildCounter()
    ) {
        self.table = table
        self.policy = policy
        self.secrets = secrets
        self.transcript = transcript
        self.foundationModelsLinked = foundationModelsLinked
        self.apple = apple
        self.builds = builds
    }

    /// A run that plans this many steps is stopped. A model that keeps asking for tools would
    /// otherwise run forever, and recovery would resume it on every launch.
    public static let maxStepsPerRun = 25

    public func plan(context: ModelContext) async throws -> ScriptedStep {
        if context.completedSteps >= Self.maxStepsPerRun {
            return .finish("Stopped after \(Self.maxStepsPerRun) steps without a final answer.")
        }
        let choice = await table.choice(for: context.conversationID.raw)
        if await policy.onDeviceOnly, OnDevicePolicy.blocksCloud(choice) {
            return .finish("On-device only is on. Switch this agent to Apple or the offline demo before using a cloud model.")
        }
        let provider = makeProvider(choice)
        builds.count += 1
        let publishing = PublishingProvider(inner: provider, transcript: transcript, conversationID: context.conversationID.raw)
        let step = AgentLoopStep(
            provider: publishing,
            modelName: choice.model,
            instructions: "You are Lumen, a personal agent. Use tools when they help. Do not invent tool results."
        )
        return try await step.plan(context: context)
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
