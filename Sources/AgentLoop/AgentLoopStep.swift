import DurableCore
import Foundation
import ModelKit

/// Multi-step agent loop. Each model response is one journaled checkpoint.
///
/// `plan` calls `ModelProvider.complete`, so token deltas stay in memory. Tool calls
/// go through the effect journal. Pure and idempotent calls in one turn run together.
/// External and transactional calls stay serial. Names in `subagentTools` start a child
/// conversation instead of a tool body. When the prompt is longer than
/// `compactAfterMessages`, the oldest messages are summarized, the summary is journaled,
/// and those messages stay in the log but leave the next prompt.
public struct AgentLoopStep: ModelStep {
    public var provider: any ModelProvider
    public var modelName: String
    public var instructions: String
    public var maxOutputTokens: Int
    public var compactAfterMessages: Int
    public var keepRecentMessages: Int
    public var subagentTools: Set<String>

    public init(
        provider: any ModelProvider,
        modelName: String,
        instructions: String = "",
        maxOutputTokens: Int = 1024,
        compactAfterMessages: Int = .max,
        keepRecentMessages: Int = 2,
        subagentTools: Set<String> = []
    ) {
        self.provider = provider
        self.modelName = modelName
        self.instructions = instructions
        self.maxOutputTokens = maxOutputTokens
        self.compactAfterMessages = compactAfterMessages
        self.keepRecentMessages = max(0, keepRecentMessages)
        self.subagentTools = subagentTools
    }

    public func plan(context: ModelContext) async throws -> ScriptedStep {
        if let compact = try await compactionStep(context) {
            return compact
        }
        let turn = try await provider.complete(request(for: context, tools: toolDefinitions(context)))
        let calls = turn.toolCalls.map { call in
            PlannedCall(
                name: call.name,
                callID: call.id,
                arguments: Self.arguments(call.argumentsJSON),
                subagent: subagentTools.contains(call.name)
            )
        }
        if calls.isEmpty {
            return .finish(turn.text)
        }
        return .providerTurn(ProviderTurnStep(
            text: turn.text,
            thinking: turn.thinking,
            calls: calls,
            inputTokens: turn.usage.inputTokens,
            outputTokens: turn.usage.outputTokens,
            stopRaw: turn.stop?.raw
        ))
    }

    private func compactionStep(_ context: ModelContext) async throws -> ScriptedStep? {
        let count = context.messages.count
        let keep = keepRecentMessages
        guard count > compactAfterMessages, count > keep else { return nil }
        let cutoff = count - keep
        guard cutoff > 0, cutoff <= context.messages.count else { return nil }
        let through = context.messages[cutoff - 1]
        let older = Array(context.messages.prefix(cutoff))
        let summary = try await provider.complete(ModelRequest(
            model: modelName,
            instructions: "Summarize the conversation so a later turn can continue. Keep decisions, names, and tool results. Do not call tools.",
            messages: Self.modelMessages(ModelContext(
                conversationID: context.conversationID,
                messages: older,
                completedTools: context.completedTools,
                grantedApprovalIDs: [],
                tools: [],
                completedSteps: context.completedSteps
            )),
            tools: [],
            maxOutputTokens: maxOutputTokens
        ))
        let text = summary.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .compact(
            summary: text.isEmpty ? "Earlier conversation omitted." : text,
            throughMessageID: through.messageID
        )
    }

    private func request(for context: ModelContext, tools: [ModelToolDefinition]) -> ModelRequest {
        var guidance = instructions
        if !context.grantedApprovalIDs.isEmpty {
            let ids = context.grantedApprovalIDs.joined(separator: ", ")
            guidance += "\nApproved ids in this turn: \(ids). Call the matching tool."
        }
        return ModelRequest(
            model: modelName,
            instructions: guidance,
            messages: Self.modelMessages(context),
            tools: tools,
            maxOutputTokens: maxOutputTokens
        )
    }

    private func toolDefinitions(_ context: ModelContext) -> [ModelToolDefinition] {
        var tools = context.tools.map { spec in
            ModelToolDefinition(
                name: spec.name,
                description: spec.summary.isEmpty ? spec.effect.rawValue : spec.summary,
                parametersJSON: spec.parametersJSON
            )
        }
        for name in subagentTools.sorted() where !tools.contains(where: { $0.name == name }) {
            tools.append(ModelToolDefinition(
                name: name,
                description: "Delegate the goal to a subagent and return its answer.",
                parametersJSON: #"{"type":"object","properties":{"goal":{"type":"string"}},"required":["goal"]}"#
            ))
        }
        return tools
    }

    static func modelMessages(_ context: ModelContext) -> [ModelMessage] {
        var records: [String: CompletedToolCall] = [:]
        for call in context.completedTools {
            records[call.callID] = call
        }
        var messages: [ModelMessage] = []
        var index = 0
        let source = context.messages
        while index < source.count {
            let message = source[index]
            if message.role == "tool" {
                let name = message.callID.flatMap { records[$0]?.name }
                messages.append(ModelMessage(
                    role: .tool,
                    text: message.text,
                    toolCallID: message.callID,
                    toolName: name
                ))
                index += 1
                continue
            }
            if message.role == "assistant" {
                var calls: [ProviderToolCall] = []
                var look = index + 1
                while look < source.count, source[look].role == "tool" {
                    let toolMessage = source[look]
                    if let callID = toolMessage.callID, let record = records[callID] {
                        calls.append(ProviderToolCall(
                            id: callID,
                            name: record.name,
                            argumentsJSON: record.arguments.canonicalJSON()
                        ))
                    }
                    look += 1
                }
                messages.append(ModelMessage(role: .assistant, text: message.text, toolCalls: calls))
                index += 1
                continue
            }
            let role: ModelMessage.Role = message.role == "system" ? .system : .user
            messages.append(ModelMessage(role: role, text: message.text))
            index += 1
        }
        return messages
    }

    private static func arguments(_ json: String) -> JSONValue {
        if let value = try? JSONValue.parse(json) {
            return value
        }
        return .string(json)
    }
}

@available(*, deprecated, renamed: "AgentLoopStep")
public typealias PiAgentStep = AgentLoopStep
