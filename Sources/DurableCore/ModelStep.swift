import Foundation

/// Who chooses the next step. Absent on older `run.started` events, which means `script`.
public enum RunDriver: String, Sendable, Equatable, Codable {
    case script
    case model
}

public struct ModelToolSpec: Sendable, Equatable {
    public var name: String
    public var effect: EffectKind
    public var summary: String

    public init(name: String, effect: EffectKind, summary: String) {
        self.name = name
        self.effect = effect
        self.summary = summary
    }
}

public struct CompletedToolCall: Sendable, Equatable {
    public var name: String
    public var callID: String
    public var arguments: JSONValue
    public var output: JSONValue

    public init(name: String, callID: String, arguments: JSONValue, output: JSONValue) {
        self.name = name
        self.callID = callID
        self.arguments = arguments
        self.output = output
    }
}

/// What a model is allowed to see. Built from the log, not from provider memory.
public struct ModelContext: Sendable {
    public var conversationID: ConversationID
    public var messages: [TranscriptMessage]
    /// Tool results committed in the current run.
    public var completedTools: [CompletedToolCall]
    /// Human approvals granted in the current run. Reconciliation approvals are not included.
    public var grantedApprovalIDs: [String]
    public var tools: [ModelToolSpec]
    public var completedSteps: Int

    public init(
        conversationID: ConversationID,
        messages: [TranscriptMessage],
        completedTools: [CompletedToolCall],
        grantedApprovalIDs: [String],
        tools: [ModelToolSpec],
        completedSteps: Int
    ) {
        self.conversationID = conversationID
        self.messages = messages
        self.completedTools = completedTools
        self.grantedApprovalIDs = grantedApprovalIDs
        self.tools = tools
        self.completedSteps = completedSteps
    }
}

/// One planning call. The engine journals the returned step before it runs.
///
/// `plan` runs while the engine holds its lock. It must not call back into the engine.
/// A crash before that journal entry is committed calls `plan` again. A crash after it
/// replays the journaled step and does not call `plan`.
public protocol ModelStep: Sendable {
    func plan(context: ModelContext) async throws -> ScriptedStep
}

/// Fixed script indexed by `context.completedSteps`. Past the end, the run finishes.
public struct ScriptedModelStep: ModelStep {
    public var steps: [ScriptedStep]

    public init(steps: [ScriptedStep]) {
        self.steps = steps
    }

    public func plan(context: ModelContext) async throws -> ScriptedStep {
        guard context.completedSteps >= 0, context.completedSteps < steps.count else {
            return .finish("")
        }
        return steps[context.completedSteps]
    }
}
