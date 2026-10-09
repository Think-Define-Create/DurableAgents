import Foundation

struct InflightEffect: Equatable {
    var stepIndex: Int
    var callID: CallID
    var tool: String
    var effect: EffectKind
    var key: EffectKey
    var arguments: JSONValue
    var attempt: Int = 1
}

struct RetryHold: Equatable {
    var attempt: Int
    var notBefore: Date
    var timerName: String
}

struct PendingWait: Equatable {
    var kind: String
    var name: String
    var stepIndex: Int
}

struct PendingTimer: Equatable {
    var name: String
    var fireAt: Date
}

enum ApprovalPurpose: String, Equatable {
    case human
    case reconcile
}

struct PendingApproval: Equatable {
    var approvalID: String
    var prompt: String
    var purpose: ApprovalPurpose
    var token: ResumeToken
    var stepIndex: Int
    var risk: ApprovalRisk = .standard
    var requiredAuth: AuthenticationLevel = .anonymous
    var expiresAt: Date?
    var escalateTo: String?
    var audience: String?
}

struct FoldedSubmission {
    var requestID: String
    var payloadHash: String
    var text: String
    var script: Script
    var driver: RunDriver = .script
    var runID: RunID?
}

struct ToolRecord: Equatable {
    var runID: String
    var name: String
    var callID: String
    var arguments: JSONValue
    var output: JSONValue
}

struct SubagentRecord: Equatable {
    var conversationID: String
    var finished: Bool
    var finalText: String?
}

struct FoldedRun {
    var id: RunID
    var requestID: String
    var script: Script
    var retry: RetryPolicy
    var driver: RunDriver = .script
    var status: RunStatus
    var completedSteps: Int
    /// More than one entry only while a provider turn is running safe calls together.
    var inflightBatch: [InflightEffect] = []
    var inflight: InflightEffect? {
        get { inflightBatch.first }
        set {
            if let newValue {
                if let index = inflightBatch.firstIndex(where: { $0.callID == newValue.callID }) {
                    inflightBatch[index] = newValue
                } else if inflightBatch.isEmpty {
                    inflightBatch = [newValue]
                } else {
                    inflightBatch[0] = newValue
                }
            } else {
                inflightBatch.removeAll()
            }
        }
    }
    var pending: PendingApproval?
    var plannedStep: ScriptedStep?
    var plannedIndex: Int?
    var grantedApprovalIDs: [String] = []
    var retryHold: RetryHold?
    var wait: PendingWait?
    var finalText: String?
    var failure: String?
    var subagents: [String: SubagentRecord] = [:]
}

struct FoldedConversation {
    var id: ConversationID
    var submissions: [FoldedSubmission] = []
    var runs: [String: FoldedRun] = [:]
    var runOrder: [String] = []
    var messages: [TranscriptMessage] = []
    var toolRecords: [ToolRecord] = []
    /// Messages before this index stay in the log and are left out of the model prompt.
    var promptStartIndex: Int = 0
    var compactionSummary: String?

    var activeRun: FoldedRun? {
        for runID in runOrder.reversed() {
            if let run = runs[runID], run.status == .running || run.status == .suspended {
                return run
            }
        }
        return nil
    }

    var latestRun: FoldedRun? {
        guard let last = runOrder.last else { return nil }
        return runs[last]
    }
}

struct Projection {
    var conversations: [String: FoldedConversation] = [:]
    var conversationOrder: [String] = []
    var values: [String: JSONValue] = [:]
    var pendingTimers: [String: PendingTimer] = [:]
    var pendingSignals: [String: JSONValue] = [:]

    static func fold(_ events: [EventEnvelope]) throws -> Projection {
        var projection = Projection()
        for event in events {
            try projection.apply(event)
        }
        return projection
    }

    static func valueKey(namespace: String, key: String) -> String {
        namespace + "\u{1}" + key
    }

    mutating func apply(_ event: EventEnvelope) throws {
        if event.payload["purged"]?.boolValue == true {
            return
        }
        switch event.type {
        case EventType.timerRequested:
            let name = event.payload["name"]?.stringValue ?? "timer-\(event.globalSeq)"
            let seconds = event.payload["fireAt"].flatMap { try? JSONNumbers.double($0) } ?? 0
            pendingTimers[name] = PendingTimer(name: name, fireAt: Date(timeIntervalSince1970: seconds))
        case EventType.timerFired:
            let name = event.payload["name"]?.stringValue
            if let name {
                pendingTimers.removeValue(forKey: name)
                for key in Array(conversations.keys) {
                    var conversation = conversations[key] ?? FoldedConversation(id: ConversationID(raw: key))
                    for runID in conversation.runOrder {
                        guard var run = conversation.runs[runID], run.retryHold?.timerName == name else { continue }
                        run.retryHold = nil
                        conversation.runs[runID] = run
                    }
                    conversations[key] = conversation
                }
            }
        case EventType.signalDelivered:
            if let name = event.payload["name"]?.stringValue {
                pendingSignals[name] = event.payload["payload"] ?? .null
            }
        case EventType.signalConsumed:
            if let name = event.payload["name"]?.stringValue {
                pendingSignals.removeValue(forKey: name)
            }
        case EventType.effectRetry:
            guard let attempt = event.payload["attempt"]?.intValue,
                  let timerName = event.payload["timerName"]?.stringValue,
                  let fireAt = event.payload["fireAt"]
            else {
                throw DurableError.invariant("effect.retry is missing fields at seq \(event.globalSeq)")
            }
            let when = Date(timeIntervalSince1970: try JSONNumbers.double(fireAt))
            try updateRun(event, runID: event.payload["runID"]?.stringValue) { run in
                run.retryHold = RetryHold(attempt: Int(attempt), notBefore: when, timerName: timerName)
                let callRaw = event.payload["callID"]?.stringValue
                if let index = run.inflightBatch.firstIndex(where: { callRaw == nil || $0.callID.raw == callRaw }) {
                    run.inflightBatch[index].attempt = Int(attempt)
                }
            }
        case EventType.waitStarted:
            guard let kind = event.payload["kind"]?.stringValue,
                  let name = event.payload["name"]?.stringValue,
                  let stepIndex = event.payload["stepIndex"]?.intValue
            else {
                throw DurableError.invariant("wait.started is missing fields at seq \(event.globalSeq)")
            }
            try updateRun(event, runID: event.payload["runID"]?.stringValue) { run in
                run.wait = PendingWait(kind: kind, name: name, stepIndex: Int(stepIndex))
                run.status = .suspended
            }
        case EventType.waitResolved:
            try updateRun(event, runID: event.payload["runID"]?.stringValue) { run in
                run.wait = nil
                if run.pending == nil, run.status == .suspended {
                    run.status = .running
                }
            }
        case EventType.stateWrote:
            guard let namespace = event.payload["namespace"]?.stringValue,
                  let key = event.payload["key"]?.stringValue,
                  let value = event.payload["value"]
            else {
                throw DurableError.invariant("state.wrote is missing fields at seq \(event.globalSeq)")
            }
            values[Self.valueKey(namespace: namespace, key: key)] = value
        case EventType.messageAppended:
            guard let message = try EventCodec.transcriptMessage(event) else { return }
            var conversation = conversation(event.stream)
            conversation.messages.append(message)
            conversations[event.stream.raw] = conversation
        case EventType.conversationOpened:
            conversations[event.stream.raw] = conversation(event.stream)
        case EventType.submissionAccepted:
            guard let requestID = event.payload["requestID"]?.stringValue,
                  let payloadHash = event.payload["payloadHash"]?.stringValue,
                  let text = event.payload["text"]?.stringValue,
                  let scriptValue = event.payload["script"]
            else {
                throw DurableError.invariant("submission.accepted is missing fields at seq \(event.globalSeq)")
            }
            var conversation = conversation(event.stream)
            var driver = RunDriver.script
            if let raw = event.payload["driver"]?.stringValue, let parsed = RunDriver(rawValue: raw) {
                driver = parsed
            }
            conversation.submissions.append(FoldedSubmission(
                requestID: requestID,
                payloadHash: payloadHash,
                text: text,
                script: try Script.parse(scriptValue),
                driver: driver,
                runID: nil
            ))
            conversations[event.stream.raw] = conversation
        case EventType.runStarted:
            guard let runRaw = event.payload["runID"]?.stringValue,
                  let requestID = event.payload["requestID"]?.stringValue,
                  let scriptValue = event.payload["script"],
                  let retryValue = event.payload["retry"]
            else {
                throw DurableError.invariant("run.started is missing fields at seq \(event.globalSeq)")
            }
            var conversation = conversation(event.stream)
            let runID = RunID(raw: runRaw)
            var driver = RunDriver.script
            if let raw = event.payload["driver"]?.stringValue, let parsed = RunDriver(rawValue: raw) {
                driver = parsed
            }
            conversation.runs[runRaw] = FoldedRun(
                id: runID,
                requestID: requestID,
                script: try Script.parse(scriptValue),
                retry: try RetryPolicy.parse(retryValue),
                driver: driver,
                status: .running,
                completedSteps: 0
            )
            conversation.runOrder.append(runRaw)
            if let index = conversation.submissions.firstIndex(where: { $0.requestID == requestID && $0.runID == nil }) {
                conversation.submissions[index].runID = runID
            }
            conversations[event.stream.raw] = conversation
        case EventType.effectIntent:
            let inflight = try inflight(from: event)
            try updateRun(event, runID: event.payload["runID"]?.stringValue) { run in
                if let existing = run.inflightBatch.first, existing.stepIndex != inflight.stepIndex {
                    throw DurableError.invariant("run \(run.id.raw) already has an in-flight effect")
                }
                if run.inflightBatch.contains(where: { $0.callID == inflight.callID }) {
                    throw DurableError.invariant("run \(run.id.raw) already journaled call \(inflight.callID.raw)")
                }
                run.inflightBatch.append(inflight)
            }
        case EventType.effectResult:
            guard let callID = event.payload["callID"]?.stringValue else {
                throw DurableError.invariant("effect.result is missing callID at seq \(event.globalSeq)")
            }
            var conversation = conversation(event.stream)
            guard let runID = event.payload["runID"]?.stringValue, var run = conversation.runs[runID] else {
                throw DurableError.invariant("effect.result references unknown run at seq \(event.globalSeq)")
            }
            if let index = run.inflightBatch.firstIndex(where: { $0.callID.raw == callID }) {
                let inflight = run.inflightBatch[index]
                if event.payload["ok"]?.boolValue == true {
                    conversation.toolRecords.append(ToolRecord(
                        runID: runID,
                        name: inflight.tool,
                        callID: callID,
                        arguments: inflight.arguments,
                        output: event.payload["output"] ?? .null
                    ))
                }
                run.inflightBatch.remove(at: index)
            }
            conversation.runs[runID] = run
            conversations[event.stream.raw] = conversation
        case EventType.stepPlanned:
            guard let stepIndex = event.payload["stepIndex"]?.intValue, let stepValue = event.payload["step"] else {
                throw DurableError.invariant("model.step.planned is missing fields at seq \(event.globalSeq)")
            }
            let planned = try ScriptedStep.parse(stepValue)
            try updateRun(event, runID: event.payload["runID"]?.stringValue) { run in
                run.plannedIndex = Int(stepIndex)
                run.plannedStep = planned
            }
        case EventType.stepCompleted:
            guard let stepIndex = event.payload["stepIndex"]?.intValue else {
                throw DurableError.invariant("model.step.completed is missing stepIndex at seq \(event.globalSeq)")
            }
            try updateRun(event, runID: event.payload["runID"]?.stringValue) { run in
                guard Int(stepIndex) == run.completedSteps else {
                    throw DurableError.invariant(
                        "step \(stepIndex) completed while run \(run.id.raw) was on step \(run.completedSteps)"
                    )
                }
                run.completedSteps += 1
            }
        case EventType.approvalRequested:
            guard let approvalID = event.payload["approvalID"]?.stringValue,
                  let prompt = event.payload["prompt"]?.stringValue,
                  let purposeRaw = event.payload["purpose"]?.stringValue,
                  let purpose = ApprovalPurpose(rawValue: purposeRaw),
                  let stepIndex = event.payload["stepIndex"]?.intValue,
                  let tokenRaw = event.payload["token"]?.stringValue,
                  let token = ResumeToken(raw: tokenRaw)
            else {
                throw DurableError.invariant("approval.requested is missing fields at seq \(event.globalSeq)")
            }
            let risk = event.payload["risk"]?.stringValue.flatMap(ApprovalRisk.init(rawValue:)) ?? .standard
            let required = event.payload["requiredAuth"]?.stringValue.flatMap(AuthenticationLevel.init(rawValue:))
                ?? .anonymous
            var expiresAt: Date?
            if let raw = event.payload["expiresAt"], let seconds = try? JSONNumbers.double(raw) {
                expiresAt = Date(timeIntervalSince1970: seconds)
            }
            try updateRun(event, runID: event.payload["runID"]?.stringValue) { run in
                run.pending = PendingApproval(
                    approvalID: approvalID,
                    prompt: prompt,
                    purpose: purpose,
                    token: token,
                    stepIndex: Int(stepIndex),
                    risk: risk,
                    requiredAuth: required,
                    expiresAt: expiresAt,
                    escalateTo: event.payload["escalateTo"]?.stringValue,
                    audience: event.payload["audience"]?.stringValue
                )
                run.status = .suspended
            }
        case EventType.approvalResolved:
            try updateRun(event, runID: event.payload["runID"]?.stringValue) { run in
                if event.payload["approved"]?.boolValue == true,
                   let pending = run.pending,
                   pending.purpose == .human
                {
                    run.grantedApprovalIDs.append(pending.approvalID)
                }
                run.pending = nil
                if run.status == .suspended {
                    run.status = .running
                }
            }
        case EventType.runCompleted:
            let text = event.payload["finalText"]?.stringValue ?? ""
            try updateRun(event, runID: event.payload["runID"]?.stringValue) { run in
                run.status = .completed
                run.finalText = text
            }
        case EventType.contextCompacted:
            var conversation = conversation(event.stream)
            if let summary = event.payload["summary"]?.stringValue {
                conversation.compactionSummary = summary
            }
            if let through = event.payload["throughMessageID"]?.stringValue,
               let index = conversation.messages.firstIndex(where: { $0.messageID == through })
            {
                conversation.promptStartIndex = index + 1
            }
            conversations[event.stream.raw] = conversation
        case EventType.subagentStarted:
            guard let callID = event.payload["callID"]?.stringValue,
                  let child = event.payload["childConversationID"]?.stringValue
            else {
                throw DurableError.invariant("subagent.started is missing fields at seq \(event.globalSeq)")
            }
            try updateRun(event, runID: event.payload["runID"]?.stringValue) { run in
                run.subagents[callID] = SubagentRecord(conversationID: child, finished: false, finalText: nil)
            }
        case EventType.subagentFinished:
            guard let callID = event.payload["callID"]?.stringValue else {
                throw DurableError.invariant("subagent.finished is missing callID at seq \(event.globalSeq)")
            }
            try updateRun(event, runID: event.payload["runID"]?.stringValue) { run in
                var record = run.subagents[callID] ?? SubagentRecord(
                    conversationID: event.payload["childConversationID"]?.stringValue ?? "",
                    finished: true,
                    finalText: nil
                )
                record.finished = true
                record.finalText = event.payload["finalText"]?.stringValue
                run.subagents[callID] = record
            }
        case EventType.retentionHold, EventType.retentionPurged, EventType.approvalEscalated, EventType.importNote, EventType.deliveryDeadLettered:
            return
        case EventType.runFailed:
            let reason = event.payload["reason"]?.stringValue ?? "failed"
            try updateRun(event, runID: event.payload["runID"]?.stringValue) { run in
                run.status = .failed
                run.failure = reason
                run.inflight = nil
                run.pending = nil
                run.retryHold = nil
                run.wait = nil
            }
        default:
            throw DurableError.invariant("unknown event type \(event.type) at seq \(event.globalSeq)")
        }
    }

    private func inflight(from event: EventEnvelope) throws -> InflightEffect {
        guard let stepIndex = event.payload["stepIndex"]?.intValue,
              let callRaw = event.payload["callID"]?.stringValue,
              let tool = event.payload["tool"]?.stringValue,
              let effectRaw = event.payload["effect"]?.stringValue,
              let effect = EffectKind(rawValue: effectRaw),
              let key = event.payload["key"]?.stringValue,
              let arguments = event.payload["arguments"]
        else {
            throw DurableError.invariant("effect.intent is missing fields at seq \(event.globalSeq)")
        }
        return InflightEffect(
            stepIndex: Int(stepIndex),
            callID: CallID(callRaw),
            tool: tool,
            effect: effect,
            key: EffectKey(raw: key),
            arguments: arguments
        )
    }

    private mutating func updateRun(
        _ event: EventEnvelope,
        runID: String?,
        _ body: (inout FoldedRun) throws -> Void
    ) throws {
        guard let runID else {
            throw DurableError.invariant("\(event.type) is missing runID at seq \(event.globalSeq)")
        }
        var conversation = conversation(event.stream)
        guard var run = conversation.runs[runID] else {
            throw DurableError.invariant("\(event.type) references unknown run \(runID)")
        }
        try body(&run)
        conversation.runs[runID] = run
        conversations[event.stream.raw] = conversation
    }

    private mutating func conversation(_ stream: StreamID) -> FoldedConversation {
        if let existing = conversations[stream.raw] {
            return existing
        }
        if !conversationOrder.contains(stream.raw) {
            conversationOrder.append(stream.raw)
        }
        return FoldedConversation(id: ConversationID(raw: stream.raw))
    }
}

extension FoldedRun {
    func snapshot() -> RunSnapshot {
        RunSnapshot(
            id: id,
            status: status,
            completedSteps: completedSteps,
            scriptStepCount: script.steps.count,
            inflightCallID: inflight?.callID.raw,
            resumeToken: pending?.token,
            finalText: finalText,
            failure: failure
        )
    }
}

extension FoldedConversation {
    func snapshot() -> ConversationSnapshot {
        ConversationSnapshot(
            id: id,
            submissions: submissions.map {
                SubmissionInfo(requestID: $0.requestID, payloadHash: $0.payloadHash, text: $0.text, runID: $0.runID)
            },
            messages: messages,
            run: (activeRun ?? latestRun)?.snapshot(),
            queuedRequestIDs: submissions.filter { $0.runID == nil }.map(\.requestID)
        )
    }
}
