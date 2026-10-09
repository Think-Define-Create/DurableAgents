import Foundation

public enum EventType {
    public static let conversationOpened = "conversation.opened"
    public static let submissionAccepted = "submission.accepted"
    public static let runStarted = "run.started"
    public static let stepPlanned = "model.step.planned"
    public static let stepCompleted = "model.step.completed"
    public static let effectIntent = "effect.intent"
    public static let effectResult = "effect.result"
    public static let approvalRequested = "approval.requested"
    public static let approvalResolved = "approval.resolved"
    public static let runCompleted = "run.completed"
    public static let runFailed = "run.failed"
    public static let messageAppended = "message.appended"
    public static let stateWrote = "state.wrote"
    public static let timerRequested = "timer.requested"
    public static let timerFired = "timer.fired"
    public static let effectRetry = "effect.retry"
    public static let waitStarted = "wait.started"
    public static let waitResolved = "wait.resolved"
    public static let signalDelivered = "signal.delivered"
    public static let signalConsumed = "signal.consumed"
    public static let contextCompacted = "context.compacted"
    public static let subagentStarted = "subagent.started"
    public static let subagentFinished = "subagent.finished"
    public static let retentionHold = "retention.hold"
    public static let retentionPurged = "retention.purged"
    public static let approvalEscalated = "approval.escalated"
    public static let importNote = "import.note"
    /// The delivery effect exhausted its attempts, or the receiver refused it.
    public static let deliveryDeadLettered = "delivery.deadLettered"

    public static let messageAppendedCurrentVersion = 2
}

/// How a tool behaves when the process dies after the effect has started.
public enum EffectKind: String, Sendable, Equatable, Codable {
    /// Re-run the body. It must not change the outside world.
    case pure
    /// Re-run the body with the same engine-minted key. The callee dedupes on that key.
    case idempotent
    /// State writes commit in the same transaction as the raw result. A crash leaves no write.
    case transactional
    /// Call `reconcile` on recovery. Do not guess, and do not ask a model what happened.
    case external
}

public enum Reconciliation: Sendable, Equatable {
    /// The outside world already has this result. Journal it and do not run the body again.
    case done(JSONValue)
    /// Nothing landed. Run the body again with the same effect key.
    case notDone
    /// The host cannot tell. Suspend for a human instead of asking a model.
    case unknown(reason: String)
}

public struct EffectContext: Sendable {
    public var key: EffectKey
    public var conversationID: ConversationID
    public var callID: CallID
    public var attempt: Int
    public var isReplay: Bool

    public init(key: EffectKey, conversationID: ConversationID, callID: CallID, attempt: Int, isReplay: Bool) {
        self.key = key
        self.conversationID = conversationID
        self.callID = callID
        self.attempt = attempt
        self.isReplay = isReplay
    }
}

public struct StateWrite: Sendable, Equatable {
    public var namespace: String
    public var key: String
    public var value: JSONValue

    public init(namespace: String, key: String, value: JSONValue) {
        self.namespace = namespace
        self.key = key
        self.value = value
    }
}

public struct ToolReturn: Sendable, Equatable {
    public var output: JSONValue
    public var writes: [StateWrite]

    public init(output: JSONValue, writes: [StateWrite] = []) {
        self.output = output
        self.writes = writes
    }
}

/// Side-effect-aware tool. The engine journals intent before `run` and the raw return value immediately after.
///
/// `run` must not call back into the engine. Doing so deadlocks the single-owner actor.
public struct Tool: Sendable {
    public var name: String
    public var effect: EffectKind
    /// Short text a model can read. The engine does not interpret it.
    public var summary: String
    /// JSON Schema for the model. The engine does not validate it.
    public var parametersJSON: String
    /// When true, the engine suspends for approval before journaling the intent.
    public var requiresApproval: Bool
    public var approvalRisk: ApprovalRisk
    public var reconcile: (@Sendable (EffectKey, EffectContext) async throws -> Reconciliation)?
    public var run: @Sendable (JSONValue, EffectContext) async throws -> ToolReturn

    public init(
        name: String,
        effect: EffectKind,
        summary: String = "",
        parametersJSON: String = #"{"type":"object","properties":{}}"#,
        requiresApproval: Bool = false,
        approvalRisk: ApprovalRisk = .standard,
        reconcile: (@Sendable (EffectKey, EffectContext) async throws -> Reconciliation)? = nil,
        run: @escaping @Sendable (JSONValue, EffectContext) async throws -> ToolReturn
    ) {
        self.name = name
        self.effect = effect
        self.summary = summary
        self.parametersJSON = parametersJSON
        self.requiresApproval = requiresApproval
        self.approvalRisk = approvalRisk
        self.reconcile = reconcile
        self.run = run
    }
}

public enum RunStatus: String, Sendable, Equatable, Codable {
    case running
    case suspended
    case completed
    case failed
}

public struct TranscriptMessage: Sendable, Equatable {
    public var messageID: String
    public var role: String
    public var text: String
    public var callID: String?

    public init(messageID: String, role: String, text: String, callID: String? = nil) {
        self.messageID = messageID
        self.role = role
        self.text = text
        self.callID = callID
    }
}

/// Recorded on `run.started`. Automatic retries apply only to `automaticKinds`.
/// External effects follow reconcile, not this backoff, unless the tool throws `DeliveryRetry`.
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var initialBackoffSeconds: Double
    public var multiplier: Double
    /// Fraction of the backoff added or subtracted. `0` keeps the delay exact.
    public var jitterRatio: Double
    public var automaticKinds: Set<EffectKind>

    public init(
        maxAttempts: Int,
        initialBackoffSeconds: Double,
        multiplier: Double,
        jitterRatio: Double = 0,
        automaticKinds: Set<EffectKind> = [.pure, .idempotent, .transactional]
    ) {
        self.maxAttempts = maxAttempts
        self.initialBackoffSeconds = initialBackoffSeconds
        self.multiplier = multiplier
        self.jitterRatio = jitterRatio
        self.automaticKinds = automaticKinds
    }

    /// One attempt, so a thrown tool error fails the run. Kept for existing journals.
    /// This remains the engine default. Opt in with `standard` when a run should retry.
    public static let stub = RetryPolicy(maxAttempts: 1, initialBackoffSeconds: 1, multiplier: 2)

    /// Opt-in schedule: five attempts, starting at half a second and doubling, with 20% jitter.
    /// `pure`, `idempotent`, and `transactional` retry on their own. `external` does not,
    /// unless the body throws `DeliveryRetry`. Journaled deliveries use this schedule
    /// even when the engine itself was created with `stub`.
    public static let standard = RetryPolicy(
        maxAttempts: 5,
        initialBackoffSeconds: 0.5,
        multiplier: 2,
        jitterRatio: 0.2
    )

    public func allowsAutomaticRetry(_ kind: EffectKind) -> Bool {
        automaticKinds.contains(kind) && kind != .external
    }

    /// `attempt` is the try that is about to start. The first retry is attempt 2.
    public func delaySeconds(forAttempt attempt: Int, jitterUnit: Double) -> Double {
        let exponent = Double(max(0, attempt - 2))
        let base = initialBackoffSeconds * pow(multiplier, exponent)
        let unit = min(1, max(0, jitterUnit))
        let delta = base * jitterRatio * (unit * 2 - 1)
        return max(0, base + delta)
    }

    func json() -> JSONValue {
        .object([
            "maxAttempts": .int(Int64(maxAttempts)),
            "initialBackoffSeconds": .double(initialBackoffSeconds),
            "multiplier": .double(multiplier),
            "jitterRatio": .double(jitterRatio),
            "automaticKinds": .array(automaticKinds.map { .string($0.rawValue) }.sorted { $0.canonicalJSON() < $1.canonicalJSON() }),
        ])
    }

    static func parse(_ value: JSONValue) throws -> RetryPolicy {
        guard let fields = value.objectValue,
              let maxAttempts = fields["maxAttempts"]?.intValue,
              let initial = fields["initialBackoffSeconds"],
              let multiplier = fields["multiplier"]
        else {
            throw DurableError.invariant("retry policy payload is incomplete")
        }
        let jitter = try fields["jitterRatio"].map { try JSONNumbers.double($0) } ?? 0
        let kinds: Set<EffectKind>
        if let listed = fields["automaticKinds"]?.arrayValue {
            kinds = Set(listed.compactMap { item in
                item.stringValue.flatMap(EffectKind.init(rawValue:))
            })
        } else {
            kinds = [.pure, .idempotent, .transactional]
        }
        return RetryPolicy(
            maxAttempts: Int(maxAttempts),
            initialBackoffSeconds: try JSONNumbers.double(initial),
            multiplier: try JSONNumbers.double(multiplier),
            jitterRatio: jitter,
            automaticKinds: kinds
        )
    }
}

public protocol DurableClock: Sendable {
    func now() -> Date
}

public struct SystemDurableClock: DurableClock {
    public init() {}

    public func now() -> Date { Date() }
}

public protocol JitterSource: Sendable {
    /// A unit in `0...1` mixed into the backoff.
    func unit() -> Double
}

public struct ZeroJitter: JitterSource {
    public init() {}

    public func unit() -> Double { 0 }
}

/// Host hook for an OS wake. The journal is still the source of truth; `Engine.pumpTimers` fires due timers.
public protocol BackgroundWakeScheduling: Sendable {
    func scheduleBackgroundWake(earliest date: Date, identifier: String) async
}

public struct NoOpBackgroundWake: BackgroundWakeScheduling {
    public init() {}

    public func scheduleBackgroundWake(earliest date: Date, identifier: String) async {}
}

enum JSONNumbers {
    static func double(_ value: JSONValue) throws -> Double {
        switch value {
        case .double(let number):
            return number
        case .int(let number):
            return Double(number)
        default:
            throw DurableError.invariant("expected a JSON number")
        }
    }
}

/// Hook for a future timer wheel. The default records nothing and waits for nobody.
public protocol TimerScheduling: Sendable {
    func schedule(name: String, fireAt: Date) async
}

public struct NoOpTimerScheduling: TimerScheduling {
    public init() {}

    public func schedule(name: String, fireAt: Date) async {}
}

public struct ApprovalSpec: Sendable, Equatable {
    public var id: String
    public var prompt: String
    public var risk: ApprovalRisk
    public var expiresAt: Date?
    public var escalateTo: String?

    public init(
        id: String,
        prompt: String,
        risk: ApprovalRisk = .standard,
        expiresAt: Date? = nil,
        escalateTo: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.risk = risk
        self.expiresAt = expiresAt
        self.escalateTo = escalateTo
    }
}

public enum ScriptedStep: Sendable, Equatable {
    case assistant(String)
    case tool(name: String, callID: String, arguments: JSONValue)
    case approval(ApprovalSpec)
    case finish(String)
    /// Suspend until `Engine.pumpTimers` (or recover) passes this instant.
    case sleepUntil(Date)
    /// Suspend until `Engine.signal(_:payload:)` delivers `name`.
    case waitSignal(name: String)
    /// One model checkpoint: assistant text plus every tool call from that turn.
    case providerTurn(ProviderTurnStep)
    /// Summarize history. The original messages stay in the log and drop out of the prompt.
    case compact(summary: String, throughMessageID: String)

    public static func approval(
        id: String,
        prompt: String,
        risk: ApprovalRisk = .standard,
        expiresAt: Date? = nil,
        escalateTo: String? = nil
    ) -> ScriptedStep {
        .approval(ApprovalSpec(
            id: id,
            prompt: prompt,
            risk: risk,
            expiresAt: expiresAt,
            escalateTo: escalateTo
        ))
    }

    var canonical: String {
        switch self {
        case .assistant(let text):
            return "assistant:\(text)"
        case .tool(let name, let callID, let arguments):
            return "tool:\(name):\(callID):\(arguments.canonicalJSON())"
        case .approval(let spec):
            var text = "approval:\(spec.id):\(spec.prompt)"
            if spec.risk != .standard || spec.expiresAt != nil || spec.escalateTo != nil {
                let expiry = spec.expiresAt?.timeIntervalSince1970 ?? 0
                text += ":\(spec.risk.rawValue):\(expiry):\(spec.escalateTo ?? "")"
            }
            return text
        case .finish(let text):
            return "finish:\(text)"
        case .sleepUntil(let date):
            return "sleep:\(date.timeIntervalSince1970)"
        case .waitSignal(let name):
            return "signal:\(name)"
        case .providerTurn(let turn):
            return "turn:\(turn.text):\(turn.calls.map(\.callID).joined(separator: ","))"
        case .compact(let summary, let throughMessageID):
            return "compact:\(throughMessageID):\(summary)"
        }
    }

    func json() -> JSONValue {
        switch self {
        case .assistant(let text):
            return .object(["type": .string("assistant"), "text": .string(text)])
        case .tool(let name, let callID, let arguments):
            return .object([
                "type": .string("tool"),
                "name": .string(name),
                "callID": .string(callID),
                "arguments": arguments,
            ])
        case .approval(let spec):
            var fields: [String: JSONValue] = [
                "type": .string("approval"),
                "id": .string(spec.id),
                "prompt": .string(spec.prompt),
            ]
            if spec.risk != .standard {
                fields["risk"] = .string(spec.risk.rawValue)
            }
            if let expiresAt = spec.expiresAt {
                fields["expiresAt"] = .double(expiresAt.timeIntervalSince1970)
            }
            if let escalateTo = spec.escalateTo {
                fields["escalateTo"] = .string(escalateTo)
            }
            return .object(fields)
        case .finish(let text):
            return .object(["type": .string("finish"), "text": .string(text)])
        case .sleepUntil(let date):
            return .object([
                "type": .string("sleepUntil"),
                "at": .double(date.timeIntervalSince1970),
            ])
        case .waitSignal(let name):
            return .object(["type": .string("waitSignal"), "name": .string(name)])
        case .providerTurn(let turn):
            return turn.json()
        case .compact(let summary, let throughMessageID):
            return .object([
                "type": .string("compact"),
                "summary": .string(summary),
                "throughMessageID": .string(throughMessageID),
            ])
        }
    }

    static func parse(_ value: JSONValue) throws -> ScriptedStep {
        guard let fields = value.objectValue, let type = fields["type"]?.stringValue else {
            throw DurableError.invariant("script step is not an object")
        }
        switch type {
        case "assistant":
            guard let text = fields["text"]?.stringValue else {
                throw DurableError.invariant("assistant step is missing text")
            }
            return .assistant(text)
        case "tool":
            guard let name = fields["name"]?.stringValue, let callID = fields["callID"]?.stringValue,
                  let arguments = fields["arguments"]
            else {
                throw DurableError.invariant("tool step is missing fields")
            }
            return .tool(name: name, callID: callID, arguments: arguments)
        case "approval":
            guard let id = fields["id"]?.stringValue, let prompt = fields["prompt"]?.stringValue else {
                throw DurableError.invariant("approval step is missing fields")
            }
            var expiresAt: Date?
            if let raw = fields["expiresAt"] {
                expiresAt = Date(timeIntervalSince1970: try JSONNumbers.double(raw))
            }
            let risk = fields["risk"]?.stringValue.flatMap(ApprovalRisk.init(rawValue:)) ?? .standard
            return .approval(ApprovalSpec(
                id: id,
                prompt: prompt,
                risk: risk,
                expiresAt: expiresAt,
                escalateTo: fields["escalateTo"]?.stringValue
            ))
        case "finish":
            guard let text = fields["text"]?.stringValue else {
                throw DurableError.invariant("finish step is missing text")
            }
            return .finish(text)
        case "sleepUntil":
            guard let at = fields["at"] else {
                throw DurableError.invariant("sleep step is missing at")
            }
            return .sleepUntil(Date(timeIntervalSince1970: try JSONNumbers.double(at)))
        case "waitSignal":
            guard let name = fields["name"]?.stringValue, !name.isEmpty else {
                throw DurableError.invariant("wait step is missing name")
            }
            return .waitSignal(name: name)
        case "providerTurn":
            return .providerTurn(try ProviderTurnStep.parse(value))
        case "compact":
            guard let summary = fields["summary"]?.stringValue,
                  let throughMessageID = fields["throughMessageID"]?.stringValue
            else {
                throw DurableError.invariant("compact step is missing fields")
            }
            return .compact(summary: summary, throughMessageID: throughMessageID)
        default:
            throw DurableError.invariant("unknown script step \(type)")
        }
    }
}

/// One tool or subagent call inside a journaled model turn.
public struct PlannedCall: Sendable, Equatable {
    public var name: String
    public var callID: String
    public var arguments: JSONValue
    /// When set, the engine runs a child conversation instead of a tool body.
    public var subagent: Bool

    public init(name: String, callID: String, arguments: JSONValue, subagent: Bool = false) {
        self.name = name
        self.callID = callID
        self.arguments = arguments
        self.subagent = subagent
    }

    func json() -> JSONValue {
        .object([
            "arguments": arguments,
            "callID": .string(callID),
            "name": .string(name),
            "subagent": .bool(subagent),
        ])
    }

    static func parse(_ value: JSONValue) throws -> PlannedCall {
        guard let fields = value.objectValue,
              let name = fields["name"]?.stringValue,
              let callID = fields["callID"]?.stringValue,
              let arguments = fields["arguments"]
        else {
            throw DurableError.invariant("planned call is missing fields")
        }
        return PlannedCall(
            name: name,
            callID: callID,
            arguments: arguments,
            subagent: fields["subagent"]?.boolValue ?? false
        )
    }
}

/// Durable checkpoint for one provider response. Token deltas are not stored.
public struct ProviderTurnStep: Sendable, Equatable {
    public var text: String
    public var thinking: String
    public var calls: [PlannedCall]
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var stopRaw: String?

    public init(
        text: String,
        thinking: String = "",
        calls: [PlannedCall],
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        stopRaw: String? = nil
    ) {
        self.text = text
        self.thinking = thinking
        self.calls = calls
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.stopRaw = stopRaw
    }

    func json() -> JSONValue {
        var fields: [String: JSONValue] = [
            "calls": .array(calls.map { $0.json() }),
            "text": .string(text),
            "thinking": .string(thinking),
            "type": .string("providerTurn"),
        ]
        if let inputTokens {
            fields["inputTokens"] = .int(Int64(inputTokens))
        }
        if let outputTokens {
            fields["outputTokens"] = .int(Int64(outputTokens))
        }
        if let stopRaw {
            fields["stop"] = .string(stopRaw)
        }
        return .object(fields)
    }

    static func parse(_ value: JSONValue) throws -> ProviderTurnStep {
        guard let fields = value.objectValue, let text = fields["text"]?.stringValue else {
            throw DurableError.invariant("provider turn is missing text")
        }
        let calls = try fields["calls"]?.arrayValue?.map(PlannedCall.parse) ?? []
        return ProviderTurnStep(
            text: text,
            thinking: fields["thinking"]?.stringValue ?? "",
            calls: calls,
            inputTokens: fields["inputTokens"]?.intValue.map(Int.init),
            outputTokens: fields["outputTokens"]?.intValue.map(Int.init),
            stopRaw: fields["stop"]?.stringValue
        )
    }
}

/// Deterministic stand-in for a model turn. Persisted with the run, so recovery does not call a provider.
public struct Script: Sendable, Equatable {
    public var steps: [ScriptedStep]

    public init(steps: [ScriptedStep]) {
        self.steps = steps
    }

    func json() -> JSONValue {
        .array(steps.map { $0.json() })
    }

    static func parse(_ value: JSONValue) throws -> Script {
        guard let array = value.arrayValue else {
            throw DurableError.invariant("script is not an array")
        }
        return Script(steps: try array.map(ScriptedStep.parse))
    }
}

public struct Submission: Sendable, Equatable {
    public var requestID: String
    public var text: String
    public var script: Script

    public init(requestID: String, text: String, script: Script) {
        self.requestID = requestID
        self.text = text
        self.script = script
    }

    /// SHA-256 of the text plus each script step. Same id with a different hash is a conflict.
    public func payloadHash() -> String {
        var lines = [text]
        for (index, step) in script.steps.enumerated() {
            lines.append("\(index):\(step.canonical)")
        }
        return SHA256Hash.hex(lines.joined(separator: "\n"))
    }

    /// Hash for a model-driven turn. It does not match a scripted submission of the same text.
    public static func modelTurnHash(text: String) -> String {
        SHA256Hash.hex("model\n" + text)
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    case approved
    case approvedWithOutput(JSONValue)
    case denied(String)
}

public struct SubmitResult: Sendable, Equatable {
    public var conversationID: ConversationID
    public var requestID: String
    public var payloadHash: String
    public var duplicate: Bool
    public var queued: Bool
    public var runStatus: RunStatus?
    public var resumeToken: ResumeToken?
    public var finalText: String?
    public var failure: String?
}

public struct ResumeResult: Sendable, Equatable {
    public var conversationID: ConversationID
    public var runStatus: RunStatus
    public var resumeToken: ResumeToken?
    public var finalText: String?
    public var failure: String?
}

public struct RecoveryAction: Sendable, Equatable {
    public var conversationID: ConversationID
    public var runStatus: RunStatus
    public var resumeToken: ResumeToken?
    public var finalText: String?
    public var failure: String?
}

public struct SubmissionInfo: Sendable, Equatable {
    public var requestID: String
    public var payloadHash: String
    public var text: String
    public var runID: RunID?
}

public struct RunSnapshot: Sendable, Equatable {
    public var id: RunID
    public var status: RunStatus
    public var completedSteps: Int
    public var scriptStepCount: Int
    public var inflightCallID: String?
    public var resumeToken: ResumeToken?
    public var finalText: String?
    public var failure: String?
}

public struct ConversationSnapshot: Sendable, Equatable {
    public var id: ConversationID
    public var submissions: [SubmissionInfo]
    public var messages: [TranscriptMessage]
    public var run: RunSnapshot?
    public var queuedRequestIDs: [String]
}

public struct EventDraft: Sendable {
    public var type: String
    public var schemaVersion: Int
    public var payload: JSONValue
    public var recordedAt: Date?

    public init(type: String, schemaVersion: Int = 1, payload: JSONValue, recordedAt: Date? = nil) {
        self.type = type
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.recordedAt = recordedAt
    }
}

public struct EventEnvelope: Sendable, Equatable, Identifiable {
    public var id: UInt64 { globalSeq }
    public var globalSeq: UInt64
    public var stream: StreamID
    public var streamSeq: UInt64
    public var type: String
    public var schemaVersion: Int
    public var recordedAt: Date
    public var payload: JSONValue

    public init(
        globalSeq: UInt64,
        stream: StreamID,
        streamSeq: UInt64,
        type: String,
        schemaVersion: Int,
        recordedAt: Date,
        payload: JSONValue
    ) {
        self.globalSeq = globalSeq
        self.stream = stream
        self.streamSeq = streamSeq
        self.type = type
        self.schemaVersion = schemaVersion
        self.recordedAt = recordedAt
        self.payload = payload
    }
}

/// Upcasters for append-only payloads. The stored bytes stay at the version that was written.
public enum EventCodec {
    public static func upcast(type: String, schemaVersion: Int, payload: JSONValue) throws -> (version: Int, payload: JSONValue) {
        if type != EventType.messageAppended {
            if schemaVersion != 1 {
                throw DurableError.unsupportedEventVersion(type: type, version: schemaVersion, supported: 1)
            }
            return (schemaVersion, payload)
        }
        if schemaVersion > EventType.messageAppendedCurrentVersion {
            throw DurableError.unsupportedEventVersion(
                type: type,
                version: schemaVersion,
                supported: EventType.messageAppendedCurrentVersion
            )
        }
        if schemaVersion == 2 {
            return (2, payload)
        }
        if schemaVersion != 1 {
            throw DurableError.unsupportedEventVersion(type: type, version: schemaVersion, supported: 2)
        }
        guard let text = payload.stringValue ?? payload["text"]?.stringValue else {
            throw DurableError.invariant("message.appended v1 is missing text")
        }
        let digest = SHA256Hash.hex(text)
        let messageID = "m_legacy_" + String(digest.prefix(12))
        return (2, .object([
            "messageID": .string(messageID),
            "role": .string("assistant"),
            "text": .string(text),
        ]))
    }

    public static func transcriptMessage(_ envelope: EventEnvelope) throws -> TranscriptMessage? {
        guard envelope.type == EventType.messageAppended else { return nil }
        let current = try upcast(type: envelope.type, schemaVersion: envelope.schemaVersion, payload: envelope.payload)
        guard let fields = current.payload.objectValue,
              let messageID = fields["messageID"]?.stringValue,
              let role = fields["role"]?.stringValue,
              let text = fields["text"]?.stringValue
        else {
            throw DurableError.invariant("message.appended v2 is missing fields at seq \(envelope.globalSeq)")
        }
        return TranscriptMessage(
            messageID: messageID,
            role: role,
            text: text,
            callID: fields["callID"]?.stringValue
        )
    }
}
