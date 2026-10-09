import DurableCore
import Foundation
import PiAI

public enum FoundationModelsSupport {
    #if canImport(FoundationModels)
    public static let compiledIn = true
    #else
    public static let compiledIn = false
    #endif
}

/// `FoundationModelsProvider` exists only when the Apple framework is importable.
/// This Linux build does not compile that adapter. It uses `respond(to:)`, which this
/// repo has checked against Apple's docs, and yields one text or tool-call checkpoint.
public enum FoundationModelsProviderSupport {
    public static let compiledIn = FoundationModelsSupport.compiledIn
}

#if canImport(FoundationModels)
import FoundationModels

/// Records the first tool call and stops the session before any side effect.
public final class FoundationToolCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (name: String, arguments: JSONValue)?

    public init() {}

    public func record(name: String, arguments: JSONValue) {
        lock.lock()
        if stored == nil {
            stored = (name, arguments)
        }
        lock.unlock()
    }

    func take() -> (name: String, arguments: JSONValue)? {
        lock.lock()
        defer { lock.unlock() }
        let value = stored
        stored = nil
        return value
    }
}

/// Thrown by a capturing tool so `respond` stops before the engine journals the call.
public struct HaltForJournal: Error, Sendable {}

/// On-device planner. Tool bodies only capture arguments; the engine runs the real tools.
public struct FoundationModelsStep: ModelStep {
    public struct ApprovalGate: Sendable {
        public var approvalID: String
        public var prompt: String

        public init(approvalID: String, prompt: String) {
            self.approvalID = approvalID
            self.prompt = prompt
        }
    }

    private let planBody: @Sendable (ModelContext) async throws -> ScriptedStep

    public func plan(context: ModelContext) async throws -> ScriptedStep {
        try await planBody(context)
    }

    @available(iOS 26, macOS 26, *)
    public init(
        instructions: String,
        gates: [String: ApprovalGate] = [:],
        makeTools: @escaping @Sendable (FoundationToolCapture) -> [any FoundationModels.Tool]
    ) {
        self.planBody = { context in
            try await Self.respond(
                context: context,
                instructions: instructions,
                gates: gates,
                makeTools: makeTools
            )
        }
    }

    @available(iOS 26, macOS 26, *)
    public static func isAvailable() -> Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    /// Why the on-device model cannot run, or nil when it can.
    @available(iOS 26, macOS 26, *)
    public static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off."
        case .unavailable(.deviceNotEligible):
            return "This device does not support Apple Intelligence."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading."
        case .unavailable(let other):
            return "The on-device model is unavailable (\(String(describing: other)))."
        }
    }

    @available(iOS 26, macOS 26, *)
    private static func respond(
        context: ModelContext,
        instructions: String,
        gates: [String: ApprovalGate],
        makeTools: @escaping @Sendable (FoundationToolCapture) -> [any FoundationModels.Tool]
    ) async throws -> ScriptedStep {
        let capture = FoundationToolCapture()
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            tools: makeTools(capture)
        ) {
            instructions
        }
        do {
            let response = try await session.respond(to: Prompt(prompt(for: context)))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                return .finish("I don't have anything else to add.")
            }
            return .finish(text)
        } catch let error as LanguageModelSession.ToolCallError {
            guard let call = capture.take() else {
                throw error
            }
            return step(for: call, context: context, gates: gates)
        } catch let error as LanguageModelError {
            if case .contextSizeExceeded = error {
                throw DurableError.invariant(
                    "on-device context window exceeded (4096 tokens, including tool schemas)"
                )
            }
            throw error
        }
    }

    private static func step(
        for call: (name: String, arguments: JSONValue),
        context: ModelContext,
        gates: [String: ApprovalGate]
    ) -> ScriptedStep {
        if let gate = gates[call.name], !context.grantedApprovalIDs.contains(gate.approvalID) {
            return .approval(id: gate.approvalID, prompt: gate.prompt)
        }
        return .tool(
            name: call.name,
            callID: "fm-\(call.name)-\(context.completedSteps)",
            arguments: call.arguments
        )
    }

    /// History comes from the durable log. A fresh session avoids the transcript rollback on tool errors.
    private static func prompt(for context: ModelContext) -> String {
        var lines: [String] = []
        if context.tools.isEmpty {
            lines.append("No tools are registered.")
        } else {
            let described = context.tools.map { spec in
                let summary = spec.summary.isEmpty ? spec.effect.rawValue : spec.summary
                return "\(spec.name): \(summary)"
            }
            lines.append("Tools: " + described.joined(separator: "; "))
        }
        if !context.grantedApprovalIDs.isEmpty {
            lines.append(
                "The person approved these ids in this turn: \(context.grantedApprovalIDs.joined(separator: ", ")). Call the matching tool now."
            )
        }
        for message in context.messages.suffix(12) {
            lines.append("\(message.role): \(String(message.text.prefix(500)))")
        }
        lines.append("Call at most one tool, or answer if the tool results above are enough.")
        return lines.joined(separator: "\n")
    }
}

/// On-device provider for `PiAgentStep`. One `respond` call is one checkpoint.
/// Streaming partial tokens from Foundation Models is not used here; that API was not
/// compiled in this environment.
@available(iOS 26, macOS 26, *)
public struct FoundationModelsProvider: ModelProvider {
    public var instructions: String
    public var makeTools: @Sendable (FoundationToolCapture) -> [any FoundationModels.Tool]

    public init(
        instructions: String,
        makeTools: @escaping @Sendable (FoundationToolCapture) -> [any FoundationModels.Tool] = { _ in [] }
    ) {
        self.instructions = instructions
        self.makeTools = makeTools
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let instructions = request.instructions.isEmpty ? self.instructions : request.instructions
        let makeTools = self.makeTools
        let prompt = request.messages.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")
        return AsyncThrowingStream { continuation in
            let task = Task {
                let capture = FoundationToolCapture()
                let session = LanguageModelSession(
                    model: SystemLanguageModel.default,
                    tools: makeTools(capture)
                ) {
                    instructions
                }
                do {
                    let response = try await session.respond(to: Prompt(prompt))
                    continuation.yield(.textDelta(response.content))
                    continuation.yield(.stop(StopReason(raw: "end_turn")))
                    continuation.finish()
                } catch let error as LanguageModelSession.ToolCallError {
                    if let call = capture.take() {
                        let arguments = call.arguments.canonicalJSON()
                        continuation.yield(.toolCall(ProviderToolCall(
                            id: "fm-\(call.name)",
                            name: call.name,
                            argumentsJSON: arguments
                        )))
                        continuation.yield(.stop(StopReason(raw: "tool_use")))
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
