import AgentLoop
import DurableCore
import Foundation
import ModelKit

#if canImport(FoundationModels)
import FoundationModels

/// An ordinary FoundationModels tool, plus how the engine treats its side effect.
///
/// The tool's own `call` runs only after the engine has journaled the intent. After a crash the
/// effect kind decides what happens: `pure` and `idempotent` tools run again, a `transactional`
/// tool's writes commit with its result, and an `external` tool calls `reconcile`, or waits for a
/// person when there is none, instead of running twice.
@available(iOS 26, macOS 26, *)
public struct DurableTool: Sendable {
    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    public var effect: EffectKind
    public var requiresApproval: Bool
    public var approvalRisk: ApprovalRisk
    public var reconcile: (@Sendable (EffectKey, EffectContext) async throws -> Reconciliation)?
    private let body: @Sendable (JSONValue) async throws -> String

    public init<T: FoundationModels.Tool>(
        _ tool: T,
        effect: EffectKind,
        requiresApproval: Bool = false,
        approvalRisk: ApprovalRisk = .standard,
        reconcile: (@Sendable (EffectKey, EffectContext) async throws -> Reconciliation)? = nil
    ) {
        self.name = tool.name
        self.description = tool.description
        self.parameters = tool.parameters
        self.effect = effect
        self.requiresApproval = requiresApproval
        self.approvalRisk = approvalRisk
        self.reconcile = reconcile
        self.body = { input in
            let arguments = try T.Arguments(try GeneratedContent(json: input.canonicalJSON()))
            return Self.text(try await tool.call(arguments: arguments))
        }
    }

    /// The engine tool that runs the wrapped tool.
    public var engineTool: DurableCore.Tool {
        let body = self.body
        return DurableCore.Tool(
            name: name,
            effect: effect,
            summary: description,
            requiresApproval: requiresApproval,
            approvalRisk: approvalRisk,
            reconcile: reconcile
        ) { input, _ in
            ToolReturn(output: .string(try await body(input)))
        }
    }

    /// What the model is offered: the same name and schema, but calling it only records the
    /// arguments and stops the session, so the engine can journal the call first.
    func standIn(_ capture: FoundationToolCapture) -> any FoundationModels.Tool {
        CapturingTool(name: name, description: description, parameters: parameters, capture: capture)
    }

    static func text(_ output: some PromptRepresentable) -> String {
        if let text = output as? String { return text }
        if let content = output as? GeneratedContent { return content.jsonString }
        if let content = output as? any ConvertibleToGeneratedContent { return content.generatedContent.jsonString }
        return String(describing: output)
    }
}

@available(iOS 26, macOS 26, *)
struct CapturingTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let capture: FoundationToolCapture

    func call(arguments: GeneratedContent) async throws -> String {
        capture.record(name: name, arguments: (try? JSONValue.parse(arguments.jsonString)) ?? .object([:]))
        throw HaltForJournal()
    }
}

/// A `LanguageModelSession` whose turns survive a crash.
///
/// Every model turn and tool call is written to the event log before anything runs. If the app is
/// killed mid-turn, `recover()` continues from the log on the next launch without repeating a side
/// effect. A tool that needs approval suspends the turn until `approve` or `deny`, across restarts.
///
/// ```swift
/// let session = try await DurableLanguageModelSession(
///     store: try SQLiteEventStore(path: url.path),
///     instructions: "You help with travel plans.",
///     tools: [DurableTool(BookFlight(), effect: .external, requiresApproval: true)]
/// )
/// switch try await session.respond(to: "Book the 9am flight to Lisbon") { … }
/// ```
@available(iOS 26, macOS 26, *)
public actor DurableLanguageModelSession {
    public enum Reply: Sendable, Equatable {
        /// The model answered.
        case text(String)
        /// A tool needs a person's approval. Pass the token to `approve` or `deny`, now or after a restart.
        case needsApproval(prompt: String, token: ResumeToken)
        /// A step failed and a retry is scheduled. The answer appears in `transcript()` when it lands.
        case retrying
        /// The turn ended with an error.
        case failed(String)
    }

    private let engine: Engine
    public let conversationID: ConversationID

    /// Apple's on-device model.
    public init(
        store: any EventStore,
        conversation: String = "default",
        instructions: String,
        tools: [DurableTool] = []
    ) async throws {
        let provider = FoundationModelsProvider(instructions: instructions) { capture in
            tools.map { $0.standIn(capture) }
        }
        try await self.init(store: store, conversation: conversation, provider: provider, instructions: instructions, tools: tools)
    }

    /// Any model that conforms to `LanguageModel`, such as Private Cloud Compute or a cloud model.
    @available(iOS 27, macOS 27, *)
    public init(
        store: any EventStore,
        conversation: String = "default",
        model: some LanguageModel,
        instructions: String,
        tools: [DurableTool] = []
    ) async throws {
        let provider = FoundationModelsProvider(model: model, instructions: instructions) { capture in
            tools.map { $0.standIn(capture) }
        }
        try await self.init(store: store, conversation: conversation, provider: provider, instructions: instructions, tools: tools)
    }

    private init(
        store: any EventStore,
        conversation: String,
        provider: FoundationModelsProvider,
        instructions: String,
        tools: [DurableTool]
    ) async throws {
        let timers = TimerPump()
        engine = try await Engine(
            store: store,
            tools: tools.map(\.engineTool),
            model: AgentLoopStep(provider: provider, modelName: "foundation-models", instructions: instructions),
            retryPolicy: .standard,
            timers: timers
        )
        await timers.attach(engine)
        conversationID = ConversationID(raw: conversation)
    }

    /// Sends one message. Sending the same `requestID` again returns the first answer instead of a second turn.
    public func respond(to text: String, requestID: String = UUID().uuidString) async throws -> Reply {
        let result = try await engine.submitTurn(text, requestID: requestID, to: conversationID)
        return try await reply(status: result.runStatus, token: result.resumeToken, text: result.finalText, failure: result.failure)
    }

    public func approve(_ token: ResumeToken, approver: Approver = Approver(id: "local", authLevel: .session)) async throws -> Reply {
        let result = try await engine.resume(token: token, decision: .approved, approver: approver)
        return try await reply(status: result.runStatus, token: result.resumeToken, text: result.finalText, failure: result.failure)
    }

    public func deny(_ token: ResumeToken, reason: String = "denied") async throws -> Reply {
        let result = try await engine.resume(token: token, decision: .denied(reason))
        return try await reply(status: result.runStatus, token: result.resumeToken, text: result.finalText, failure: result.failure)
    }

    /// Call once at launch. Finishes a turn the last process was killed in, and reports a pending approval.
    public func recover() async throws -> Reply? {
        let actions = try await engine.recover()
        guard let action = actions.first(where: { $0.conversationID == conversationID }) else { return nil }
        return try await reply(status: action.runStatus, token: action.resumeToken, text: action.finalText, failure: action.failure)
    }

    /// The conversation as journaled: the person's messages, replies, tool results and approval prompts.
    public func transcript() async throws -> [TranscriptMessage] {
        try await engine.transcript(conversationID)
    }

    /// Releases the store. Call before opening another session on the same store.
    public func close() async {
        await engine.close()
    }

    private func reply(status: RunStatus?, token: ResumeToken?, text: String?, failure: String?) async throws -> Reply {
        switch status {
        case .completed:
            return .text(text ?? "")
        case .suspended:
            guard let token else { return .failed("suspended without a resume token") }
            let prompt = try await engine.transcript(conversationID).last { $0.role == "system" }?.text ?? ""
            return .needsApproval(prompt: prompt, token: token)
        case .running:
            return .retrying
        case .failed, .none:
            // The tool already ran and its result is journaled. If the model then refuses to word a
            // reply (the on-device guardrail sometimes does), the result itself is the answer.
            if let failure, failure.contains("declined"),
               let last = try await engine.transcript(conversationID).last, last.role == "tool" {
                return .text(last.text)
            }
            return .failed(failure ?? "the turn did not finish")
        }
    }
}
#endif
