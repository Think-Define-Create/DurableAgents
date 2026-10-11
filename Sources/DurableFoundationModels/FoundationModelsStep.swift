import DurableCore
import Foundation
import ModelKit
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum FoundationModelsSupport {
    #if canImport(FoundationModels)
    public static let compiledIn = true
    #else
    public static let compiledIn = false
    #endif

    /// Info.plist key a host sets to true once Apple has granted it the managed
    /// `com.apple.developer.private-cloud-compute` entitlement. Without that entitlement the framework
    /// stops the process with a fatal error instead of throwing, so nothing here calls it unless the key is set.
    public static let privateCloudEntitledKey = "DurableAgentsPrivateCloudEntitled"

    /// True when the app declares the entitlement and Apple's Private Cloud Compute model can answer now (iOS 27, macOS 27).
    public static var privateCloudAvailable: Bool {
        #if canImport(FoundationModels)
        guard Bundle.main.object(forInfoDictionaryKey: privateCloudEntitledKey) as? Bool == true else { return false }
        if #available(iOS 27, macOS 27, *) {
            return PrivateCloudComputeLanguageModel().isAvailable
        }
        #endif
        return false
    }
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
public struct HaltForJournal: Error, Sendable {
    public init() {}
}

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
        } catch {
            if isContextOverflow(error) {
                throw DurableError.invariant(
                    "on-device context window exceeded (4096 tokens, including tool schemas)"
                )
            }
            throw error
        }
    }

    /// `LanguageModelError` replaces `GenerationError` from macOS 27; check both.
    @available(iOS 26, macOS 26, *)
    private static func isContextOverflow(_ error: any Error) -> Bool {
        if #available(iOS 27, macOS 27, *),
           let error = error as? LanguageModelError,
           case .contextSizeExceeded = error {
            return true
        }
        if let error = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = error {
            return true
        }
        return false
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

/// On-device provider for `AgentLoopStep`. One `streamResponse` call is one checkpoint.
/// Text streams as deltas so the UI can show it while the model is still generating.
@available(iOS 26, macOS 26, *)
public struct FoundationModelsProvider: ModelProvider {
    public var instructions: String
    public var makeTools: @Sendable (FoundationToolCapture) -> [any FoundationModels.Tool]
    /// When true, the tools in each request are offered to the model as well, so the engine's tools
    /// reach the on-device model without a hand-written `FoundationModels.Tool` for each one.
    public var bridgesRequestTools: Bool
    /// Uses Apple's Private Cloud Compute model on iOS 27 and macOS 27 instead of the on-device one.
    /// Its window is larger, so the prompt keeps more history. It needs Apple's managed entitlement,
    /// declared with `FoundationModelsSupport.privateCloudEntitledKey`. Otherwise this stays on device.
    public var privateCloud: Bool

    public init(
        instructions: String,
        bridgesRequestTools: Bool = false,
        privateCloud: Bool = false,
        makeTools: @escaping @Sendable (FoundationToolCapture) -> [any FoundationModels.Tool] = { _ in [] }
    ) {
        self.instructions = instructions
        self.bridgesRequestTools = bridgesRequestTools
        self.privateCloud = privateCloud
        self.makeTools = makeTools
    }


    /// Loads the on-device model ahead of the first turn. Each turn still uses a fresh session.
    public func prewarm() {
        LanguageModelSession(model: SystemLanguageModel.default, tools: makeTools(FoundationToolCapture())) {
            instructions
        }
        .prewarm()
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let instructions = request.instructions.isEmpty ? self.instructions : request.instructions
        let makeTools = self.makeTools
        let bridged = bridgesRequestTools ? request.tools : []
        let messages = request.messages
        let privateCloud = self.privateCloud
        return AsyncThrowingStream { continuation in
            let task = Task {
                let capture = FoundationToolCapture()
                let tools = makeTools(capture) + bridged.compactMap { BridgedTool(definition: $0, capture: capture) }
                let session: LanguageModelSession
                var prompt = Self.prompt(for: messages)
                // Without the entitlement the framework would stop the app, so stay on device.
                if privateCloud, FoundationModelsSupport.privateCloudAvailable, #available(iOS 27, macOS 27, *) {
                    let model = PrivateCloudComputeLanguageModel()
                    // About three characters a token, with room left for instructions, tools and the reply.
                    let tokens = (try? await model.contextSize) ?? 16_384
                    prompt = Self.prompt(for: messages, keep: 80, clip: 4_000, budget: max(6_000, tokens * 3 - 12_000))
                    session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
                } else {
                    session = LanguageModelSession(model: SystemLanguageModel.default, tools: tools) {
                        instructions
                    }
                }
                do {
                    // Snapshots carry the whole text so far. Only a strict extension of what was
                    // already sent goes out, because consumers concatenate deltas.
                    var sent = ""
                    for try await snapshot in session.streamResponse(to: Prompt(prompt)) {
                        let text = snapshot.content
                        guard text.count > sent.count, text.hasPrefix(sent) else { continue }
                        continuation.yield(.textDelta(String(text.dropFirst(sent.count))))
                        sent = text
                    }
                    continuation.yield(.stop(StopReason(raw: "end_turn")))
                    continuation.finish()
                } catch let error as LanguageModelSession.ToolCallError {
                    if let call = capture.take() {
                        let arguments = call.arguments.canonicalJSON()
                        continuation.yield(.toolCall(ProviderToolCall(
                            id: "fm-\(UUID().uuidString.lowercased())",
                            name: call.name,
                            argumentsJSON: arguments
                        )))
                        continuation.yield(.stop(StopReason(raw: "tool_use")))
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: OnDeviceModelError(error))
                    }
                } catch {
                    continuation.finish(throwing: OnDeviceModelError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A readable reason in place of `Error Domain=FoundationModels…`, which the chat would show as is.
@available(iOS 26, macOS 26, *)
public struct OnDeviceModelError: Error, CustomStringConvertible {
    public var underlying: any Error
    public var description: String

    init(_ error: any Error) {
        underlying = error
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize:
                description = "This chat is too long for the on-device model. Start a new bot or use a cloud model."
            case .guardrailViolation:
                description = "The on-device model declined to answer that. Try rewording it."
            case .refusal:
                description = "The on-device model declined to answer that."
            case .assetsUnavailable:
                description = "The on-device model is not ready yet. Check that Apple Intelligence is on and finished downloading."
            case .unsupportedLanguageOrLocale:
                description = "The on-device model does not support this language yet."
            case .rateLimited, .concurrentRequests:
                description = "The on-device model is busy. Try again in a moment."
            default:
                description = "The on-device model could not answer that. Try again or rephrase."
            }
        } else if #available(iOS 27, macOS 27, *), let cloud = error as? PrivateCloudComputeLanguageModel.Error {
            switch cloud {
            case .networkFailure:
                description = "Apple's Private Cloud Compute could not be reached. Check the connection, or switch this bot to on-device."
            case .quotaLimitReached:
                description = "This device has used its Private Cloud Compute allowance for now. Try again later, or switch this bot to on-device."
            case .serviceUnavailable:
                description = "Apple's Private Cloud Compute is unavailable right now. Try again in a moment."
            @unknown default:
                description = "Apple's Private Cloud Compute could not answer: \(cloud.localizedDescription)"
            }
        } else {
            description = "The on-device model could not answer: \(error.localizedDescription)"
        }
    }
}

@available(iOS 26, macOS 26, *)
extension FoundationModelsProvider {
    /// One flat prompt. Tool results are labeled with the tool name so the model can use them.
    /// Keeps the newest messages that fit in `budget` characters, each clipped, so short chats reach
    /// further back while the 4,096-token window keeps room for the instructions and tool schemas.
    static func prompt(for messages: [ModelMessage], keep: Int = 24, clip: Int = 700, budget: Int = 6_000) -> String {
        var lines: [String] = []
        var used = 0
        for message in messages.suffix(keep).reversed() {
            let text = message.text.count > clip ? String(message.text.prefix(clip)) + "…" : message.text
            let line: String
            switch message.role {
            case .tool:
                line = "tool result (\(message.toolName ?? "tool")): \(text)"
            case .assistant where message.text.isEmpty && !message.toolCalls.isEmpty:
                line = "assistant called: " + message.toolCalls.map(\.name).joined(separator: ", ")
            default:
                line = "\(message.role.rawValue): \(text)"
            }
            if used + line.count > budget, !lines.isEmpty { break }
            used += line.count
            lines.insert(line, at: 0)
        }
        if messages.last?.role == .tool {
            // With a longer history the small model tends to repeat its previous answer, so restate
            // what the person just asked and point at the newest tool result.
            let asked = messages.last { $0.role == .user }.map { String($0.text.prefix(clip)) } ?? ""
            lines.append("The user's latest message was: \(asked)")
            lines.append("Answer that message now in a new reply. Use the last tool result above, and do not repeat earlier replies.")
        }
        return lines.joined(separator: "\n")
    }
}

/// Offers one engine tool to the on-device model. The JSON schema is rebuilt as a dynamic
/// generation schema. Calling it records the arguments and halts, so the engine runs the real tool.
@available(iOS 26, macOS 26, *)
struct BridgedTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let capture: FoundationToolCapture
    let includesSchemaInInstructions = true

    init?(definition: ModelToolDefinition, capture: FoundationToolCapture) {
        guard let schema = Self.schema(name: definition.name, json: definition.parametersJSON) else { return nil }
        self.name = definition.name
        self.description = definition.description
        self.parameters = schema
        self.capture = capture
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let value = (try? JSONValue.parse(arguments.jsonString)) ?? .object([:])
        capture.record(name: name, arguments: value)
        throw HaltForJournal()
    }

    /// Supports flat object schemas: string, integer, number, boolean and string enums.
    /// Other property types are offered as strings.
    static func schema(name: String, json: String) -> GenerationSchema? {
        guard let root = try? JSONValue.parse(json).objectValue else { return nil }
        let required = Set(root["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let properties = root["properties"]?.objectValue ?? [:]
        let members = properties.keys.sorted().map { key -> DynamicGenerationSchema.Property in
            let spec = properties[key]?.objectValue ?? [:]
            let note = spec["description"]?.stringValue
            let type = spec["type"]?.stringValue ?? "string"
            let schema: DynamicGenerationSchema
            if let choices = spec["enum"]?.arrayValue?.compactMap(\.stringValue), !choices.isEmpty {
                schema = DynamicGenerationSchema(name: "\(name)_\(key)", anyOf: choices)
            } else {
                switch type {
                case "integer": schema = DynamicGenerationSchema(type: Int.self)
                case "number": schema = DynamicGenerationSchema(type: Double.self)
                case "boolean": schema = DynamicGenerationSchema(type: Bool.self)
                default: schema = DynamicGenerationSchema(type: String.self)
                }
            }
            return DynamicGenerationSchema.Property(name: key, description: note, schema: schema, isOptional: !required.contains(key))
        }
        let object = DynamicGenerationSchema(name: name, properties: members)
        return try? GenerationSchema(root: object, dependencies: [])
    }
}
#endif
