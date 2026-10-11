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
    /// Definitions offered to the model in addition to the engine's tools, such as a subagent
    /// tool with its own parameters.
    public var extraTools: [ModelToolDefinition]

    public init(
        provider: any ModelProvider,
        modelName: String,
        instructions: String = "",
        maxOutputTokens: Int = 1024,
        compactAfterMessages: Int = .max,
        keepRecentMessages: Int = 2,
        subagentTools: Set<String> = [],
        extraTools: [ModelToolDefinition] = []
    ) {
        self.provider = provider
        self.modelName = modelName
        self.instructions = instructions
        self.maxOutputTokens = maxOutputTokens
        self.compactAfterMessages = compactAfterMessages
        self.keepRecentMessages = max(0, keepRecentMessages)
        self.subagentTools = subagentTools
        self.extraTools = extraTools
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
        for extra in extraTools where !tools.contains(where: { $0.name == extra.name }) {
            tools.append(extra)
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

    /// Rebuilds provider messages from the journal. The engine journals a step's tool results
    /// before the step's own text, so each run of tool results gets an assistant message carrying
    /// the calls (and that step's text) in front of it, as the cloud APIs require. Results from
    /// earlier runs, whose calls are no longer in the context, are passed as plain user text.
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
                var group: [TranscriptMessage] = []
                while index < source.count, source[index].role == "tool" {
                    group.append(source[index])
                    index += 1
                }
                let paired = group.filter { $0.callID.flatMap { records[$0] } != nil }
                let claimed = messages.last.map { last in
                    last.role == .assistant && paired.allSatisfy { tool in last.toolCalls.contains { $0.id == tool.callID } }
                } ?? false
                if !paired.isEmpty, !claimed {
                    var text = ""
                    if index < source.count, source[index].role == "assistant", source[index].messageID.hasPrefix("m_turn_") {
                        text = source[index].text
                        index += 1
                    }
                    let calls = paired.compactMap { tool -> ProviderToolCall? in
                        guard let callID = tool.callID, let record = records[callID] else { return nil }
                        return ProviderToolCall(id: callID, name: record.name, argumentsJSON: record.arguments.canonicalJSON())
                    }
                    if let last = messages.last, last.role == .assistant, last.toolCalls.isEmpty {
                        // Two assistant messages in a row would read as a prefill; attach the calls instead.
                        messages[messages.count - 1].toolCalls = calls
                        if !text.isEmpty {
                            messages[messages.count - 1].text += (last.text.isEmpty ? "" : "\n") + text
                        }
                    } else {
                        messages.append(ModelMessage(role: .assistant, text: text, toolCalls: calls))
                    }
                }
                for tool in group {
                    if let callID = tool.callID, let record = records[callID] {
                        messages.append(ModelMessage(role: .tool, text: tool.text, toolCallID: callID, toolName: record.name))
                    } else {
                        messages.append(ModelMessage(role: .user, text: "Tool result from earlier: \(tool.text)"))
                    }
                }
                continue
            }
            let role: ModelMessage.Role
            switch message.role {
            case "assistant": role = .assistant
            case "system": role = .system
            default: role = .user
            }
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
