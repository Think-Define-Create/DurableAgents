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

    /// True when Apple's on-device model can answer now.
    public static func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *), case .available = SystemLanguageModel.default.availability {
            return true
        }
        #endif
        return false
    }

    /// Why the on-device model cannot run, or nil when it can.
    public static func unavailableReason() -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *) else { return "The on-device model needs iOS 26 or macOS 26." }
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
        #else
        return "Foundation Models is not available on this platform."
        #endif
    }

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

/// Runs one model turn for `AgentLoopStep` on a `LanguageModelSession`. One `streamResponse`
/// call is one checkpoint, and text streams as deltas while the model generates.
///
/// The session is rebuilt each turn from the journal as a structured `Transcript`: instructions,
/// prompts, responses, tool calls and tool outputs. Tools only record their arguments and stop, so
/// the engine journals the call and runs the real tool. On iOS 27 and macOS 27 any `LanguageModel`
/// works: Apple's on-device model, Private Cloud Compute, or a third-party model that conforms.
@available(iOS 26, macOS 26, *)
public struct FoundationModelsProvider: ModelProvider {
    public typealias SessionFactory = @Sendable (_ tools: [any FoundationModels.Tool], _ transcript: Transcript) async -> LanguageModelSession

    public var instructions: String
    public var makeTools: @Sendable (FoundationToolCapture) -> [any FoundationModels.Tool]
    /// When true, the tools in each request are offered to the model as well, so the engine's tools
    /// reach the model without a hand-written `FoundationModels.Tool` for each one.
    public var bridgesRequestTools: Bool
    /// Characters of history kept, newest first.
    public var historyBudget: Int
    /// True: the history is a structured `Transcript` of prompts, responses, tool calls and outputs.
    /// False: one flat "role: text" prompt. In testing on macOS 27 the small on-device model called
    /// tools more reliably with the flat prompt, so it keeps that. Larger models use the transcript.
    public var structuredHistory: Bool
    private let makeSession: SessionFactory

    /// Apple's on-device model. `privateCloud` uses Private Cloud Compute on iOS 27 and macOS 27 when
    /// the app declares the managed entitlement (`FoundationModelsSupport.privateCloudEntitledKey`);
    /// without it the framework would stop the app, so this stays on device.
    public init(
        instructions: String,
        bridgesRequestTools: Bool = false,
        privateCloud: Bool = false,
        makeTools: @escaping @Sendable (FoundationToolCapture) -> [any FoundationModels.Tool] = { _ in [] }
    ) {
        self.instructions = instructions
        self.bridgesRequestTools = bridgesRequestTools
        self.makeTools = makeTools
        if privateCloud, FoundationModelsSupport.privateCloudAvailable, #available(iOS 27, macOS 27, *) {
            let model = PrivateCloudComputeLanguageModel()
            self.historyBudget = 48_000
            self.structuredHistory = true
            self.makeSession = { tools, transcript in
                LanguageModelSession(model: model, tools: tools, transcript: transcript)
            }
        } else {
            // About 4,096 tokens in all, so the history stays short and leaves room for tool schemas.
            self.historyBudget = 6_000
            self.structuredHistory = false
            self.makeSession = { tools, transcript in
                LanguageModelSession(model: SystemLanguageModel.default, tools: tools, transcript: transcript)
            }
        }
    }

    /// Any model that conforms to `LanguageModel`, such as a cloud model from another package.
    @available(iOS 27, macOS 27, *)
    public init(
        model: some LanguageModel,
        instructions: String,
        bridgesRequestTools: Bool = false,
        historyBudget: Int = 48_000,
        structuredHistory: Bool = true,
        makeTools: @escaping @Sendable (FoundationToolCapture) -> [any FoundationModels.Tool] = { _ in [] }
    ) {
        self.instructions = instructions
        self.bridgesRequestTools = bridgesRequestTools
        self.historyBudget = historyBudget
        self.structuredHistory = structuredHistory
        self.makeTools = makeTools
        self.makeSession = { tools, transcript in
            LanguageModelSession(model: model, tools: tools, transcript: transcript)
        }
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
        let makeSession = self.makeSession
        let bridged = bridgesRequestTools ? request.tools : []
        let history: TranscriptHistory
        if structuredHistory {
            history = TranscriptHistory(messages: request.messages, budget: historyBudget)
        } else {
            history = TranscriptHistory(entries: [], prompt: Self.flatPrompt(for: request.messages, budget: historyBudget))
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                let capture = FoundationToolCapture()
                let tools = makeTools(capture) + bridged.compactMap { BridgedTool(definition: $0, capture: capture) }
                let transcript = history.transcript(instructions: instructions, tools: tools)
                let session = await makeSession(tools, transcript)
                do {
                    // Snapshots carry the whole text so far. Only a strict extension of what was
                    // already sent goes out, because consumers concatenate deltas.
                    var sent = ""
                    for try await snapshot in session.streamResponse(to: Prompt(history.prompt)) {
                        let text = snapshot.content
                        guard text.count > sent.count, text.hasPrefix(sent) else { continue }
                        continuation.yield(.textDelta(String(text.dropFirst(sent.count))))
                        sent = text
                    }
                    continuation.yield(.stop(StopReason(raw: "end_turn")))
                    continuation.finish()
                } catch let error as LanguageModelSession.ToolCallError {
                    if let call = capture.take() {
                        continuation.yield(.toolCall(ProviderToolCall(
                            id: "fm-\(UUID().uuidString.lowercased())",
                            name: call.name,
                            argumentsJSON: call.arguments.canonicalJSON()
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

@available(iOS 26, macOS 26, *)
extension FoundationModelsProvider {
    /// One flat prompt for the small on-device model. Tool results are labeled with the tool name.
    /// Keeps the newest messages that fit in `budget` characters, each clipped, so short chats reach
    /// further back while the 4,096-token window keeps room for the instructions and tool schemas.
    static func flatPrompt(for messages: [ModelMessage], keep: Int = 24, clip: Int = 700, budget: Int = 6_000) -> String {
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

/// The journal's messages as a structured `Transcript` plus the prompt for this turn.
///
/// The newest messages that fit in `budget` characters are kept, each clipped. A turn that ends on
/// a tool result has no new prompt from the person, so the prompt restates their latest message and
/// asks for an answer that uses the result. The roles stay structured, so a bot named "Assistant"
/// is never confused with the assistant role.
@available(iOS 26, macOS 26, *)
struct TranscriptHistory: Sendable {
    var entries: [Transcript.Entry]
    var prompt: String

    init(entries: [Transcript.Entry], prompt: String) {
        self.entries = entries
        self.prompt = prompt
    }

    init(messages: [ModelMessage], budget: Int, clip: Int = 2_000) {
        var history = messages
        var prompt = ""
        if let last = history.last, last.role == .user {
            prompt = last.text
            history.removeLast()
        } else if history.last?.role == .tool {
            let asked = messages.last { $0.role == .user }.map { String($0.text.prefix(clip)) } ?? ""
            prompt = "Tell me in one short sentence what the tool result above means for me."
        } else {
            prompt = "Continue."
        }

        func clipped(_ text: String) -> String {
            text.count > clip ? String(text.prefix(clip)) + "…" : text
        }
        func segments(_ text: String) -> [Transcript.Segment] {
            [.text(Transcript.TextSegment(content: clipped(text)))]
        }

        var kept: [Transcript.Entry] = []
        var used = 0
        for message in history.reversed() {
            let size = min(message.text.count, clip) + message.toolCalls.reduce(0) { $0 + $1.argumentsJSON.count }
            if used + size > budget, !kept.isEmpty { break }
            used += size
            switch message.role {
            case .user:
                kept.append(.prompt(Transcript.Prompt(segments: segments(message.text))))
            case .system:
                // Engine notes such as "Approve sendGift before it runs?" are for the app. Shown to the
                // model as the person's words they can trip the on-device guardrail, so they stay out.
                continue
            case .assistant:
                if !message.toolCalls.isEmpty {
                    let calls = message.toolCalls.map { call in
                        Transcript.ToolCall(
                            id: call.id,
                            toolName: call.name,
                            arguments: (try? GeneratedContent(json: call.argumentsJSON)) ?? GeneratedContent(call.argumentsJSON)
                        )
                    }
                    kept.append(.toolCalls(Transcript.ToolCalls(calls)))
                }
                if !message.text.isEmpty {
                    kept.append(.response(Transcript.Response(assetIDs: [], segments: segments(message.text))))
                }
            case .tool:
                kept.append(.toolOutput(Transcript.ToolOutput(
                    id: message.toolCallID ?? UUID().uuidString,
                    toolName: message.toolName ?? "tool",
                    segments: segments(message.text)
                )))
            }
        }
        // Entries were collected newest first. A tool output whose call was cut off would be orphaned.
        var ordered = Array(kept.reversed())
        while let first = ordered.first, case .toolOutput = first {
            ordered.removeFirst()
        }
        // The framework rejects two prompts or two responses in a row (GenerationError -1). That
        // happens after a turn that failed, or when an older tool result is passed back as text.
        var merged: [Transcript.Entry] = []
        for entry in ordered {
            switch (merged.last, entry) {
            case (.prompt(let previous)?, .prompt(let next)):
                merged[merged.count - 1] = .prompt(Transcript.Prompt(segments: previous.segments + next.segments))
            case (.response(let previous)?, .response(let next)):
                merged[merged.count - 1] = .response(Transcript.Response(assetIDs: [], segments: previous.segments + next.segments))
            default:
                merged.append(entry)
            }
        }
        // An unanswered prompt at the end would sit next to this turn's prompt, so the two are joined.
        if case .prompt(let last)? = merged.last {
            merged.removeLast()
            let earlier = last.segments.compactMap { segment -> String? in
                if case .text(let text) = segment { return text.content }
                return nil
            }
            prompt = (earlier + [prompt]).joined(separator: "\n")
        }
        self.entries = merged
        self.prompt = prompt
    }

    func transcript(instructions: String, tools: [any FoundationModels.Tool]) -> Transcript {
        let header = Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: instructions))],
            toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
        )
        return Transcript(entries: [.instructions(header)] + entries)
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
