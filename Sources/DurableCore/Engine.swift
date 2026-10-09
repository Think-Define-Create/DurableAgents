import Foundation

/// Single-owner run actor for every conversation in one store.
///
/// The store lease is the fence. A second process that opens the same store is
/// rejected while the lease is live, and this actor's later commits fail if
/// that lease is stolen. Recovery reads the event log and continues from the
/// last committed intent. It does not ask a model what a tool did.
public actor Engine {
    private let store: any EventStore
    private let tools: [String: Tool]
    private let model: (any ModelStep)?
    private let retryPolicy: RetryPolicy
    private let timers: any TimerScheduling
    private let clock: any DurableClock
    private let jitter: any JitterSource
    private let backgroundWake: any BackgroundWakeScheduling
    private let owner: UUID
    private var fence: FenceToken
    private let storeIdentifier: String
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var poisoned = false
    private var closed = false

    public init(
        store: any EventStore,
        tools: [Tool] = [],
        model: (any ModelStep)? = nil,
        retryPolicy: RetryPolicy = .stub,
        timers: any TimerScheduling = NoOpTimerScheduling(),
        clock: any DurableClock = SystemDurableClock(),
        jitter: any JitterSource = ZeroJitter(),
        backgroundWake: any BackgroundWakeScheduling = NoOpBackgroundWake(),
        leaseTTL: Duration = .seconds(30),
        owner: UUID = UUID()
    ) async throws {
        var registered: [String: Tool] = [:]
        registered.reserveCapacity(tools.count)
        for tool in tools {
            if registered[tool.name] != nil {
                throw DurableError.invariant("duplicate tool \(tool.name)")
            }
            if tool.name.isEmpty {
                throw DurableError.invariant("tool name is empty")
            }
            if tool.effect == .external && tool.reconcile == nil {
                throw DurableError.missingReconcile(tool: tool.name)
            }
            registered[tool.name] = tool
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let lease = try await store.acquireLease(owner: owner, pid: pid, ttl: leaseTTL)
        self.store = store
        self.tools = registered
        self.model = model
        self.retryPolicy = retryPolicy
        self.timers = timers
        self.clock = clock
        self.jitter = jitter
        self.backgroundWake = backgroundWake
        self.owner = owner
        self.fence = lease.fence
        self.storeIdentifier = try await store.storeID()
    }

    public var ownerID: UUID { owner }

    public func currentFence() -> FenceToken { fence }

    public func storeID() -> String { storeIdentifier }

    /// Journals a timer request and notifies `TimerScheduling`. Does not suspend the run.
    public func requestTimer(name: String, fireAt: Date) async throws {
        try await exclusively {
            try ensureWritable()
            _ = try await commit(StreamID("timers"), [
                EventDraft(
                    type: EventType.timerRequested,
                    payload: .object([
                        "name": .string(name),
                        "fireAt": .double(fireAt.timeIntervalSince1970),
                    ])
                ),
            ])
            await timers.schedule(name: name, fireAt: fireAt)
            await backgroundWake.scheduleBackgroundWake(earliest: fireAt, identifier: name)
        }
    }

    /// Fires journaled timers whose deadline has passed and continues runs that were waiting on them.
    public func pumpTimers() async throws -> [RecoveryAction] {
        try await exclusively {
            try ensureWritable()
            try await fireDueTimers()
            await reschedulePendingTimers()
            return try await continueRunning()
        }
    }

    /// Delivers a named signal. A run blocked on `waitSignal` resumes. A signal with no waiter stays queued.
    public func signal(_ name: String, payload: JSONValue = .null) async throws -> RecoveryAction? {
        try await exclusively {
            try ensureWritable()
            if name.isEmpty {
                throw DurableError.invariant("signal name is empty")
            }
            _ = try await commit(StreamID("signals"), [
                EventDraft(
                    type: EventType.signalDelivered,
                    payload: .object([
                        "name": .string(name),
                        "payload": payload,
                    ])
                ),
            ])
            let projection = try await load()
            guard let match = Self.waitingRun(in: projection, kind: "signal", name: name) else {
                return nil
            }
            try await resolveWait(match.conversation, run: match.run, payload: payload)
            let settled = try await advance(match.conversation.id)
            return RecoveryAction(
                conversationID: match.conversation.id,
                runStatus: settled.runStatus ?? .running,
                resumeToken: settled.resumeToken,
                finalText: settled.finalText,
                failure: settled.failure
            )
        }
    }

    public func submit(_ submission: Submission, to existing: ConversationID? = nil) async throws -> SubmitResult {
        try await exclusively {
            try await accept(
                text: submission.text,
                requestID: submission.requestID,
                hash: submission.payloadHash(),
                script: submission.script,
                driver: .script,
                existing: existing
            )
        }
    }

    /// Starts a model-driven turn. The attached `ModelStep` chooses each step; an empty script does not finish the run.
    public func submitTurn(_ text: String, requestID: String, to existing: ConversationID? = nil) async throws -> SubmitResult {
        try await exclusively {
            try await accept(
                text: text,
                requestID: requestID,
                hash: Submission.modelTurnHash(text: text),
                script: Script(steps: []),
                driver: .model,
                existing: existing
            )
        }
    }

    public func listConversations() async throws -> [ConversationID] {
        try await exclusively {
            let projection = try await load()
            return projection.conversationOrder.compactMap { raw in
                projection.conversations[raw] == nil ? nil : ConversationID(raw: raw)
            }
        }
    }

    public func resume(token: ResumeToken, decision: ApprovalDecision) async throws -> ResumeResult {
        try await exclusively {
            try ensureWritable()
            let projection = try await load()
            guard let conversation = projection.conversations[token.conversationID.raw],
                  let run = conversation.activeRun,
                  let pending = run.pending,
                  pending.token == token
            else {
                throw DurableError.invalidResumeToken
            }
            guard run.status == .suspended else {
                throw DurableError.notSuspended
            }
            try await resolveApproval(conversation: conversation, run: run, pending: pending, decision: decision)
            let settled = try await advance(token.conversationID)
            guard let status = settled.runStatus else {
                throw DurableError.invariant("resume did not leave a run status")
            }
            return ResumeResult(
                conversationID: token.conversationID,
                runStatus: status,
                resumeToken: settled.resumeToken,
                finalText: settled.finalText,
                failure: settled.failure
            )
        }
    }

    /// Continues runs that were `running` when the process died, and reports runs that are still suspended.
    public func recover() async throws -> [RecoveryAction] {
        try await exclusively {
            try ensureWritable()
            try await fireDueTimers()
            await reschedulePendingTimers()
            return try await continueRunning()
        }
    }

    public func snapshot(_ id: ConversationID) async throws -> ConversationSnapshot {
        try await exclusively {
            let projection = try await load()
            guard let conversation = projection.conversations[id.raw] else {
                throw DurableError.invariant("no conversation \(id.raw)")
            }
            return conversation.snapshot()
        }
    }

    /// Copies the transcript into a new conversation. Event ids are new. The source log is unchanged.
    public func fork(_ source: ConversationID) async throws -> ConversationID {
        try await exclusively {
            try ensureWritable()
            let projection = try await load()
            guard let conversation = projection.conversations[source.raw] else {
                throw DurableError.invariant("no conversation \(source.raw)")
            }
            let child = ConversationID.generate()
            var drafts = [
                EventDraft(
                    type: EventType.conversationOpened,
                    payload: .object([
                        "conversationID": .string(child.raw),
                        "forkedFrom": .string(source.raw),
                    ])
                ),
            ]
            for message in conversation.messages {
                drafts.append(Self.messageDraft(
                    role: message.role,
                    text: message.text,
                    messageID: Self.freshMessageID(),
                    callID: message.callID
                ))
            }
            _ = try await commit(.conversation(child), drafts)
            return child
        }
    }

    public func transcript(_ id: ConversationID) async throws -> [TranscriptMessage] {
        try await exclusively {
            let envelopes = try await store.read(stream: .conversation(id))
            return try envelopes.compactMap { try EventCodec.transcriptMessage($0) }
        }
    }

    public func events(for id: ConversationID) async throws -> [EventEnvelope] {
        try await exclusively {
            try await store.read(stream: .conversation(id))
        }
    }

    public func storedValue(namespace: String, key: String) async throws -> JSONValue? {
        try await exclusively {
            let projection = try await load()
            return projection.values[Projection.valueKey(namespace: namespace, key: key)]
        }
    }

    /// Drops the lease without writing a domain event. In-process crash tests use this
    /// where a real process death would drop the lease by exiting.
    public func close() async {
        await lock()
        if !closed {
            closed = true
            do {
                try await store.releaseLease(fence: fence)
            } catch {
                // The lease was already stolen or released.
            }
        }
        unlock()
    }

    private func continueRunning() async throws -> [RecoveryAction] {
        let before = try await load()
        let ids = before.conversations.compactMap { key, conversation -> String? in
            guard let run = conversation.activeRun else { return nil }
            return (run.status == .running || run.status == .suspended) ? key : nil
        }.sorted()
        var actions: [RecoveryAction] = []
        for key in ids {
            let projection = try await load()
            guard let conversation = projection.conversations[key] else { continue }
            guard let run = conversation.activeRun else {
                if let latest = conversation.latestRun {
                    actions.append(Self.recovery(conversation, latest))
                }
                continue
            }
            if run.status == .suspended {
                actions.append(Self.recovery(conversation, run))
                continue
            }
            let settled = try await advance(conversation.id)
            let again = try await load()
            if let updated = again.conversations[key], let latest = updated.activeRun ?? updated.latestRun {
                actions.append(Self.recovery(updated, latest, override: settled))
            }
        }
        return actions
    }

    private func advance(_ id: ConversationID) async throws -> StatusView {
        for _ in 0..<10_000 {
            let projection = try await load()
            guard let conversation = projection.conversations[id.raw] else {
                throw DurableError.invariant("missing conversation \(id.raw)")
            }
            if let run = conversation.activeRun {
                if run.status == .suspended {
                    if let wait = run.wait, wait.kind == "signal",
                       let payload = projection.pendingSignals[wait.name]
                    {
                        try await resolveWait(conversation, run: run, payload: payload)
                        continue
                    }
                    return Self.view(of: conversation)
                }
                if let hold = run.retryHold {
                    if clock.now() < hold.notBefore {
                        return Self.view(of: conversation)
                    }
                    if projection.pendingTimers[hold.timerName] == nil {
                        _ = try await commit(StreamID("timers"), [
                            EventDraft(
                                type: EventType.timerFired,
                                payload: .object([
                                    "name": .string(hold.timerName),
                                    "firedAt": .double(clock.now().timeIntervalSince1970),
                                ])
                            ),
                        ])
                    }
                    try await fireDueTimers()
                    continue
                }
                if let inflight = run.inflight {
                    let openProviderTurn = run.plannedIndex == run.completedSteps && {
                        if case .providerTurn = run.plannedStep { return true }
                        return false
                    }()
                    if !openProviderTurn {
                        try await resolveInflight(conversation: conversation, run: run, inflight: inflight)
                        continue
                    }
                }
                if run.driver == .model {
                    if let planned = run.plannedStep, run.plannedIndex == run.completedSteps {
                        if case .providerTurn = planned {
                            try await perform(planned, index: run.completedSteps, conversation: conversation, run: run)
                        } else if let inflight = run.inflight {
                            try await resolveInflight(conversation: conversation, run: run, inflight: inflight)
                        } else {
                            try await perform(planned, index: run.completedSteps, conversation: conversation, run: run)
                        }
                    } else if let inflight = run.inflight {
                        try await resolveInflight(conversation: conversation, run: run, inflight: inflight)
                    } else {
                        try await planNext(conversation: conversation, run: run)
                    }
                    continue
                }
                if run.completedSteps >= run.script.steps.count {
                    let text = Self.finalText(in: conversation, fallback: "")
                    _ = try await commit(.conversation(id), [
                        EventDraft(
                            type: EventType.runCompleted,
                            payload: .object([
                                "runID": .string(run.id.raw),
                                "finalText": .string(text),
                            ])
                        ),
                    ])
                    continue
                }
                try await perform(
                    run.script.steps[run.completedSteps],
                    index: run.completedSteps,
                    conversation: conversation,
                    run: run
                )
                continue
            }
            if let queued = conversation.submissions.first(where: { $0.runID == nil }) {
                try await startRun(queued, conversation: conversation)
                continue
            }
            return Self.view(of: conversation)
        }
        throw DurableError.invariant("run did not settle")
    }

    private func startRun(_ submission: FoldedSubmission, conversation: FoldedConversation) async throws {
        let runID = RunID.generate()
        var payload: [String: JSONValue] = [
            "runID": .string(runID.raw),
            "requestID": .string(submission.requestID),
            "script": submission.script.json(),
            "retry": retryPolicy.json(),
        ]
        if submission.driver == .model {
            payload["driver"] = .string(RunDriver.model.rawValue)
        }
        _ = try await commit(.conversation(conversation.id), [
            EventDraft(type: EventType.runStarted, payload: .object(payload)),
        ])
    }

    private func accept(
        text: String,
        requestID: String,
        hash: String,
        script: Script,
        driver: RunDriver,
        existing: ConversationID?,
        continueFirst: Bool = true
    ) async throws -> SubmitResult {
        try ensureWritable()
        if requestID.isEmpty {
            throw DurableError.invariant("requestId is empty")
        }
        if continueFirst {
            _ = try await continueRunning()
        }
        let conversationID = existing ?? ConversationID.generate()
        let before = try await load()
        if let conversation = before.conversations[conversationID.raw],
           let prior = conversation.submissions.first(where: { $0.requestID == requestID })
        {
            if prior.payloadHash != hash {
                throw DurableError.requestIDConflict(
                    requestID: requestID,
                    existingHash: prior.payloadHash,
                    attemptedHash: hash
                )
            }
            let view = Self.view(of: conversation)
            return SubmitResult(
                conversationID: conversationID,
                requestID: requestID,
                payloadHash: hash,
                duplicate: true,
                queued: view.queued,
                runStatus: view.runStatus,
                resumeToken: view.resumeToken,
                finalText: view.finalText,
                failure: view.failure
            )
        }

        var drafts: [EventDraft] = []
        if before.conversations[conversationID.raw] == nil {
            drafts.append(EventDraft(
                type: EventType.conversationOpened,
                payload: .object(["conversationID": .string(conversationID.raw)])
            ))
        }
        var accepted: [String: JSONValue] = [
            "requestID": .string(requestID),
            "payloadHash": .string(hash),
            "text": .string(text),
            "script": script.json(),
        ]
        if driver == .model {
            accepted["driver"] = .string(RunDriver.model.rawValue)
        }
        drafts.append(EventDraft(type: EventType.submissionAccepted, payload: .object(accepted)))
        drafts.append(Self.messageDraft(
            role: "user",
            text: text,
            messageID: "m_" + UUID().uuidString.lowercased()
        ))
        _ = try await commit(.conversation(conversationID), drafts)
        let settled = try await advance(conversationID)
        return SubmitResult(
            conversationID: conversationID,
            requestID: requestID,
            payloadHash: hash,
            duplicate: false,
            queued: settled.queued,
            runStatus: settled.runStatus,
            resumeToken: settled.resumeToken,
            finalText: settled.finalText,
            failure: settled.failure
        )
    }

    private func planNext(conversation: FoldedConversation, run: FoldedRun) async throws {
        guard let model else {
            try await failRun(
                conversation: conversation,
                run: run,
                reason: "model-driven run has no ModelStep"
            )
            return
        }
        let step: ScriptedStep
        do {
            step = try await model.plan(context: modelContext(for: conversation, run: run))
        } catch is SimulatedProcessCrash {
            poisoned = true
            throw SimulatedProcessCrash()
        } catch {
            try await failRun(conversation: conversation, run: run, reason: String(describing: error))
            return
        }
        _ = try await commit(.conversation(conversation.id), [
            EventDraft(
                type: EventType.stepPlanned,
                payload: .object([
                    "runID": .string(run.id.raw),
                    "stepIndex": .int(Int64(run.completedSteps)),
                    "step": step.json(),
                ])
            ),
        ])
    }

    private func modelContext(for conversation: FoldedConversation, run: FoldedRun) -> ModelContext {
        let records = conversation.toolRecords.filter { $0.runID == run.id.raw }
        let specs = tools.values.map {
            ModelToolSpec(name: $0.name, effect: $0.effect, summary: $0.summary)
        }.sorted { $0.name < $1.name }
        var visible = Array(conversation.messages.dropFirst(conversation.promptStartIndex))
        if let summary = conversation.compactionSummary, !summary.isEmpty {
            visible.insert(
                TranscriptMessage(
                    messageID: "m_compact_\(conversation.id.raw)",
                    role: "system",
                    text: summary
                ),
                at: 0
            )
        }
        return ModelContext(
            conversationID: conversation.id,
            messages: visible,
            completedTools: records.map {
                CompletedToolCall(name: $0.name, callID: $0.callID, arguments: $0.arguments, output: $0.output)
            },
            grantedApprovalIDs: run.grantedApprovalIDs,
            tools: specs,
            completedSteps: run.completedSteps
        )
    }

    private func failRun(conversation: FoldedConversation, run: FoldedRun, reason: String) async throws {
        _ = try await commit(.conversation(conversation.id), [
            EventDraft(
                type: EventType.runFailed,
                payload: .object([
                    "runID": .string(run.id.raw),
                    "reason": .string(reason),
                ])
            ),
        ])
    }

    private func perform(
        _ step: ScriptedStep,
        index: Int,
        conversation: FoldedConversation,
        run: FoldedRun
    ) async throws {
        switch step {
        case .assistant(let text):
            _ = try await commit(.conversation(conversation.id), [
                Self.messageDraft(role: "assistant", text: text, messageID: Self.freshMessageID()),
                Self.stepDraft(run: run, index: index),
            ])
        case .finish(let text):
            _ = try await commit(.conversation(conversation.id), [
                Self.messageDraft(role: "assistant", text: text, messageID: Self.freshMessageID()),
                Self.stepDraft(run: run, index: index),
                EventDraft(
                    type: EventType.runCompleted,
                    payload: .object([
                        "runID": .string(run.id.raw),
                        "finalText": .string(text),
                    ])
                ),
            ])
        case .sleepUntil(let date):
            let name = "sleep-\(run.id.raw)-\(index)"
            try await armTimer(name: name, fireAt: date)
            _ = try await commit(.conversation(conversation.id), [
                EventDraft(
                    type: EventType.waitStarted,
                    payload: .object([
                        "runID": .string(run.id.raw),
                        "stepIndex": .int(Int64(index)),
                        "kind": .string("timer"),
                        "name": .string(name),
                    ])
                ),
            ])
        case .waitSignal(let name):
            if name.isEmpty {
                throw DurableError.invariant("signal name is empty")
            }
            let projection = try await load()
            if let payload = projection.pendingSignals[name] {
                _ = try await commit(.conversation(conversation.id), [
                    Self.waitResolvedDraft(run: run, name: name, payload: payload),
                    EventDraft(
                        type: EventType.signalConsumed,
                        payload: .object(["name": .string(name)])
                    ),
                    Self.messageDraft(
                        role: "system",
                        text: Self.display(payload),
                        messageID: Self.freshMessageID()
                    ),
                    Self.stepDraft(run: run, index: index),
                ])
            } else {
                _ = try await commit(.conversation(conversation.id), [
                    EventDraft(
                        type: EventType.waitStarted,
                        payload: .object([
                            "runID": .string(run.id.raw),
                            "stepIndex": .int(Int64(index)),
                            "kind": .string("signal"),
                            "name": .string(name),
                        ])
                    ),
                ])
            }
        case .approval(let approvalID, let prompt):
            if approvalID.isEmpty {
                throw DurableError.invariant("approval id is empty")
            }
            let token = ResumeToken(conversationID: conversation.id, approvalID: approvalID)
            _ = try await commit(.conversation(conversation.id), [
                Self.messageDraft(role: "system", text: prompt, messageID: Self.freshMessageID()),
                EventDraft(
                    type: EventType.approvalRequested,
                    payload: .object([
                        "runID": .string(run.id.raw),
                        "stepIndex": .int(Int64(index)),
                        "approvalID": .string(approvalID),
                        "prompt": .string(prompt),
                        "purpose": .string(ApprovalPurpose.human.rawValue),
                        "token": .string(token.raw),
                    ])
                ),
            ])
        case .tool(let name, let callRaw, let arguments):
            if callRaw.isEmpty {
                throw DurableError.invariant("tool call id is empty")
            }
            let call = CallID(callRaw)
            let key = EffectKey.derive(storeID: storeIdentifier, conversation: conversation.id, call: call)
            guard let tool = tools[name] else {
                try await failRun(
                    conversation: conversation,
                    run: run,
                    reason: DurableError.unknownTool(name).description
                )
                return
            }
            let inflight = InflightEffect(
                stepIndex: index,
                callID: call,
                tool: name,
                effect: tool.effect,
                key: key,
                arguments: arguments
            )
            _ = try await commit(.conversation(conversation.id), [
                Self.intentDraft(run: run, inflight: inflight),
            ])
            try await executeBody(
                tool: tool,
                inflight: inflight,
                conversation: conversation,
                run: run,
                isReplay: false,
                attempt: 1
            )
        case .compact(let summary, let throughMessageID):
            _ = try await commit(.conversation(conversation.id), [
                EventDraft(
                    type: EventType.contextCompacted,
                    payload: .object([
                        "runID": .string(run.id.raw),
                        "summary": .string(summary),
                        "throughMessageID": .string(throughMessageID),
                    ])
                ),
                Self.stepDraft(run: run, index: index),
            ])
        case .providerTurn(let turn):
            try await performProviderTurn(
                turn,
                index: index,
                conversation: conversation,
                run: run
            )
        }
    }

    private func resolveInflight(
        conversation: FoldedConversation,
        run: FoldedRun,
        inflight: InflightEffect
    ) async throws {
        guard let tool = tools[inflight.tool] else {
            throw DurableError.unknownTool(inflight.tool)
        }
        guard tool.effect == inflight.effect else {
            throw DurableError.effectKindMismatch(
                tool: inflight.tool,
                stored: inflight.effect,
                registered: tool.effect
            )
        }
        if inflight.effect == .external {
            guard let reconcile = tool.reconcile else {
                throw DurableError.missingReconcile(tool: tool.name)
            }
            let context = effectContext(
                inflight,
                conversation: conversation,
                isReplay: true,
                attempt: Self.replayAttempt(inflight)
            )
            let outcome: Reconciliation
            do {
                outcome = try await reconcile(inflight.key, context)
            } catch is SimulatedProcessCrash {
                poisoned = true
                throw SimulatedProcessCrash()
            } catch {
                try await failInflight(conversation: conversation, run: run, inflight: inflight, error: error)
                return
            }
            switch outcome {
            case .done(let output):
                try await commitSuccess(
                    conversation: conversation,
                    run: run,
                    inflight: inflight,
                    output: output,
                    writes: [],
                    replayed: false,
                    reconciled: true,
                    completesStep: !Self.providerTurnIsOpen(run)
                )
            case .notDone:
                try await executeBody(
                    tool: tool,
                    inflight: inflight,
                    conversation: conversation,
                    run: run,
                    isReplay: true,
                    attempt: Self.replayAttempt(inflight)
                )
            case .unknown(let reason):
                let token = ResumeToken(
                    conversationID: conversation.id,
                    approvalID: "reconcile-\(inflight.callID.raw)"
                )
                _ = try await commit(.conversation(conversation.id), [
                    Self.messageDraft(role: "system", text: reason, messageID: Self.freshMessageID()),
                    EventDraft(
                        type: EventType.approvalRequested,
                        payload: .object([
                            "runID": .string(run.id.raw),
                            "stepIndex": .int(Int64(inflight.stepIndex)),
                            "approvalID": .string(token.approvalID),
                            "prompt": .string(reason),
                            "purpose": .string(ApprovalPurpose.reconcile.rawValue),
                            "token": .string(token.raw),
                        ])
                    ),
                ])
            }
            return
        }
        try await executeBody(
            tool: tool,
            inflight: inflight,
            conversation: conversation,
            run: run,
            isReplay: true,
            attempt: Self.replayAttempt(inflight)
        )
    }

    private func executeBody(
        tool: Tool,
        inflight: InflightEffect,
        conversation: FoldedConversation,
        run: FoldedRun,
        isReplay: Bool,
        attempt: Int,
        completesStep: Bool = true
    ) async throws {
        let context = effectContext(inflight, conversation: conversation, isReplay: isReplay, attempt: attempt)
        let returned: ToolReturn
        do {
            returned = try await tool.run(inflight.arguments, context)
        } catch is SimulatedProcessCrash {
            poisoned = true
            throw SimulatedProcessCrash()
        } catch {
            try await failInflight(conversation: conversation, run: run, inflight: inflight, error: error)
            return
        }
        if inflight.effect != .transactional && !returned.writes.isEmpty {
            try await failInflight(
                conversation: conversation,
                run: run,
                inflight: inflight,
                error: DurableError.invariant("only transactional tools may return state writes")
            )
            return
        }
        try await commitSuccess(
            conversation: conversation,
            run: run,
            inflight: inflight,
            output: returned.output,
            writes: inflight.effect == .transactional ? returned.writes : [],
            replayed: isReplay,
            reconciled: false,
            completesStep: completesStep
        )
    }

    private func resolveApproval(
        conversation: FoldedConversation,
        run: FoldedRun,
        pending: PendingApproval,
        decision: ApprovalDecision
    ) async throws {
        switch pending.purpose {
        case .human:
            switch decision {
            case .approved, .approvedWithOutput:
                _ = try await commit(.conversation(conversation.id), [
                    Self.approvalResolvedDraft(run: run, approvalID: pending.approvalID, approved: true, reason: nil),
                    Self.stepDraft(run: run, index: pending.stepIndex),
                ])
            case .denied(let reason):
                _ = try await commit(.conversation(conversation.id), [
                    Self.approvalResolvedDraft(run: run, approvalID: pending.approvalID, approved: false, reason: reason),
                    EventDraft(
                        type: EventType.runFailed,
                        payload: .object([
                            "runID": .string(run.id.raw),
                            "reason": .string("approval denied: \(reason)"),
                        ])
                    ),
                ])
            }
        case .reconcile:
            guard let inflight = run.inflight else {
                throw DurableError.invariant("reconciliation approval has no in-flight effect")
            }
            switch decision {
            case .approvedWithOutput(let output):
                var drafts = [
                    Self.approvalResolvedDraft(run: run, approvalID: pending.approvalID, approved: true, reason: nil),
                ]
                let completesStep = !Self.providerTurnIsOpen(run)
            drafts.append(contentsOf: Self.successDrafts(
                    run: run,
                    inflight: inflight,
                    output: output,
                    writes: [],
                    replayed: false,
                    reconciled: true,
                    completesStep: completesStep
                ))
                _ = try await commit(.conversation(conversation.id), drafts)
            case .approved:
                throw DurableError.approvalNeedsOutput
            case .denied(let reason):
                _ = try await commit(.conversation(conversation.id), [
                    Self.approvalResolvedDraft(run: run, approvalID: pending.approvalID, approved: false, reason: reason),
                    Self.resultDraft(
                        run: run,
                        inflight: inflight,
                        ok: false,
                        output: .null,
                        replayed: false,
                        reconciled: true,
                        error: reason
                    ),
                    EventDraft(
                        type: EventType.runFailed,
                        payload: .object([
                            "runID": .string(run.id.raw),
                            "reason": .string("reconciliation denied: \(reason)"),
                        ])
                    ),
                ])
            }
        }
    }

    private func performProviderTurn(
        _ turn: ProviderTurnStep,
        index: Int,
        conversation: FoldedConversation,
        run: FoldedRun
    ) async throws {
        let done = Set(conversation.toolRecords.filter { $0.runID == run.id.raw }.map(\.callID))
        let finishedSubagents = Set(run.subagents.filter { $0.value.finished }.map(\.key))
        let toolCalls = turn.calls.filter { !$0.subagent && !done.contains($0.callID) }
        let pendingIntents = Set(run.inflightBatch.map(\.callID.raw))
        var newIntents: [InflightEffect] = []
        for call in toolCalls where !pendingIntents.contains(call.callID) {
            if call.callID.isEmpty {
                throw DurableError.invariant("tool call id is empty")
            }
            guard let tool = tools[call.name] else {
                try await failRun(conversation: conversation, run: run, reason: DurableError.unknownTool(call.name).description)
                return
            }
            let inflight = InflightEffect(
                stepIndex: index,
                callID: CallID(call.callID),
                tool: tool.name,
                effect: tool.effect,
                key: EffectKey.derive(storeID: storeIdentifier, conversation: conversation.id, call: CallID(call.callID)),
                arguments: call.arguments
            )
            newIntents.append(inflight)
        }
        if !newIntents.isEmpty {
            _ = try await commit(
                .conversation(conversation.id),
                newIntents.map { Self.intentDraft(run: run, inflight: $0) }
            )
        }

        let current = try await load()
        guard let refreshedConversation = current.conversations[conversation.id.raw],
              let refreshed = refreshedConversation.runs[run.id.raw]
        else {
            throw DurableError.invariant("provider turn lost run \(run.id.raw)")
        }
        let batch = refreshed.inflightBatch
        let safe = batch.filter { $0.effect == .pure || $0.effect == .idempotent }
        let unsafe = batch.filter { $0.effect == .transactional || $0.effect == .external }
        if !safe.isEmpty {
            let stopped = try await runSafeBatch(
                safe,
                conversation: refreshedConversation,
                run: refreshed,
                replayIDs: pendingIntents
            )
            if stopped { return }
        }
        for inflight in unsafe {
            let isReplay = pendingIntents.contains(inflight.callID.raw)
            guard let tool = tools[inflight.tool] else {
                throw DurableError.unknownTool(inflight.tool)
            }
            if isReplay && tool.effect == .external {
                try await resolveInflight(conversation: refreshedConversation, run: refreshed, inflight: inflight)
            } else {
                try await executeBody(
                    tool: tool,
                    inflight: inflight,
                    conversation: refreshedConversation,
                    run: refreshed,
                    isReplay: isReplay,
                    attempt: max(inflight.attempt, 1),
                    completesStep: false
                )
            }
            let after = try await load()
            if let latest = after.conversations[conversation.id.raw]?.runs[run.id.raw],
               latest.status == .failed || latest.status == .suspended || latest.retryHold != nil
            {
                return
            }
        }

        let afterTools = try await load()
        guard var parent = afterTools.conversations[conversation.id.raw],
              var parentRun = parent.runs[run.id.raw]
        else {
            throw DurableError.invariant("provider turn lost run \(run.id.raw)")
        }
        if parentRun.status != .running || parentRun.retryHold != nil || parentRun.inflight != nil {
            return
        }
        for call in turn.calls where call.subagent && !finishedSubagents.contains(call.callID) {
            try await runSubagent(call, index: index, conversation: parent, run: parentRun)
            let again = try await load()
            guard let next = again.conversations[conversation.id.raw],
                  let nextRun = next.runs[run.id.raw]
            else {
                return
            }
            parent = next
            parentRun = nextRun
            if parentRun.status != .running {
                return
            }
        }

        var closing: [EventDraft] = []
        let assistantID = "m_turn_\(run.id.raw)_\(index)"
        if !turn.text.isEmpty, !parent.messages.contains(where: { $0.messageID == assistantID }) {
            closing.append(Self.messageDraft(role: "assistant", text: turn.text, messageID: assistantID))
        }
        closing.append(Self.stepDraft(run: parentRun, index: index))
        _ = try await commit(.conversation(conversation.id), closing)
    }

    private struct ToolOutcome: Sendable {
        var inflight: InflightEffect
        var output: JSONValue
        var writes: [StateWrite]
        var error: String?
        var crashed: Bool
    }

    private func runSafeBatch(
        _ batch: [InflightEffect],
        conversation: FoldedConversation,
        run: FoldedRun,
        replayIDs: Set<String>
    ) async throws -> Bool {
        let jobs: [(InflightEffect, Tool, EffectContext)] = try batch.map { inflight in
            guard let tool = tools[inflight.tool] else {
                throw DurableError.unknownTool(inflight.tool)
            }
            let replay = replayIDs.contains(inflight.callID.raw) || inflight.attempt > 1
            let attempt = replay && inflight.attempt <= 1 ? 2 : max(inflight.attempt, 1)
            let context = effectContext(
                inflight,
                conversation: conversation,
                isReplay: replay,
                attempt: attempt
            )
            return (inflight, tool, context)
        }
        let tasks = jobs.map { inflight, tool, context in
            Task.detached {
                do {
                    let returned = try await tool.run(inflight.arguments, context)
                    return ToolOutcome(
                        inflight: inflight,
                        output: returned.output,
                        writes: returned.writes,
                        error: nil,
                        crashed: false
                    )
                } catch is SimulatedProcessCrash {
                    return ToolOutcome(inflight: inflight, output: .null, writes: [], error: nil, crashed: true)
                } catch {
                    return ToolOutcome(
                        inflight: inflight,
                        output: .null,
                        writes: [],
                        error: String(describing: error),
                        crashed: false
                    )
                }
            }
        }
        var outcomes: [ToolOutcome] = []
        for task in tasks {
            outcomes.append(await task.value)
        }
        if outcomes.contains(where: \.crashed) {
            poisoned = true
            throw SimulatedProcessCrash()
        }
        let successes = outcomes.filter { $0.error == nil }
        if !successes.isEmpty {
            var drafts: [EventDraft] = []
            for outcome in successes {
                if outcome.inflight.effect != .transactional && !outcome.writes.isEmpty {
                    try await failInflight(
                        conversation: conversation,
                        run: run,
                        inflight: outcome.inflight,
                        error: DurableError.invariant("only transactional tools may return state writes")
                    )
                    return true
                }
                drafts.append(contentsOf: Self.successDrafts(
                    run: run,
                    inflight: outcome.inflight,
                    output: outcome.output,
                    writes: outcome.inflight.effect == .transactional ? outcome.writes : [],
                    replayed: outcome.inflight.attempt > 1,
                    reconciled: false,
                    completesStep: false
                ))
            }
            _ = try await commit(.conversation(conversation.id), drafts)
        }
        if let failure = outcomes.first(where: { $0.error != nil }) {
            try await failInflight(
                conversation: conversation,
                run: run,
                inflight: failure.inflight,
                error: DurableError.invariant(failure.error ?? "tool failed")
            )
            return true
        }
        return false
    }

    private func runSubagent(
        _ call: PlannedCall,
        index: Int,
        conversation: FoldedConversation,
        run: FoldedRun
    ) async throws {
        let goal: String
        if let text = call.arguments.objectValue?["goal"]?.stringValue {
            goal = text
        } else {
            goal = Self.display(call.arguments)
        }
        let childID: ConversationID
        if let existing = run.subagents[call.callID] {
            childID = ConversationID(raw: existing.conversationID)
        } else {
            childID = ConversationID(raw: "child:\(conversation.id.raw):\(run.id.raw):\(index):\(call.callID)")
            _ = try await commit(.conversation(conversation.id), [
                EventDraft(
                    type: EventType.subagentStarted,
                    payload: .object([
                        "runID": .string(run.id.raw),
                        "stepIndex": .int(Int64(index)),
                        "callID": .string(call.callID),
                        "name": .string(call.name),
                        "goal": .string(goal),
                        "childConversationID": .string(childID.raw),
                    ])
                ),
            ])
        }
        let requestID = "childreq:\(run.id.raw):\(index):\(call.callID)"
        let projection = try await load()
        let child = projection.conversations[childID.raw]
        let settled: StatusView
        if let child, child.latestRun?.status == .completed || child.latestRun?.status == .failed {
            settled = Self.view(of: child)
        } else if child?.activeRun != nil {
            settled = try await advance(childID)
        } else {
            let submitted = try await accept(
                text: goal,
                requestID: requestID,
                hash: Submission.modelTurnHash(text: goal),
                script: Script(steps: []),
                driver: .model,
                existing: childID,
                continueFirst: false
            )
            settled = StatusView(
                queued: submitted.queued,
                runStatus: submitted.runStatus,
                resumeToken: submitted.resumeToken,
                finalText: submitted.finalText,
                failure: submitted.failure
            )
        }
        guard settled.runStatus == .completed else {
            try await failRun(
                conversation: conversation,
                run: run,
                reason: settled.failure ?? "subagent \(call.name) ended \(String(describing: settled.runStatus))"
            )
            return
        }
        _ = try await commit(.conversation(conversation.id), [
            EventDraft(
                type: EventType.subagentFinished,
                payload: .object([
                    "runID": .string(run.id.raw),
                    "callID": .string(call.callID),
                    "childConversationID": .string(childID.raw),
                    "finalText": .string(settled.finalText ?? ""),
                ])
            ),
            Self.messageDraft(
                role: "tool",
                text: settled.finalText ?? "",
                messageID: Self.freshMessageID(),
                callID: call.callID
            ),
        ])
    }

    private func commitSuccess(
        conversation: FoldedConversation,
        run: FoldedRun,
        inflight: InflightEffect,
        output: JSONValue,
        writes: [StateWrite],
        replayed: Bool,
        reconciled: Bool,
        completesStep: Bool = true
    ) async throws {
        _ = try await commit(
            .conversation(conversation.id),
            Self.successDrafts(
                run: run,
                inflight: inflight,
                output: output,
                writes: writes,
                replayed: replayed,
                reconciled: reconciled,
                completesStep: completesStep
            )
        )
    }

    private func failInflight(
        conversation: FoldedConversation,
        run: FoldedRun,
        inflight: InflightEffect,
        error: any Error
    ) async throws {
        let reason = String(describing: error)
        let nextAttempt = max(inflight.attempt, 1) + 1
        if run.retry.allowsAutomaticRetry(inflight.effect), nextAttempt <= run.retry.maxAttempts {
            let delay = run.retry.delaySeconds(forAttempt: nextAttempt, jitterUnit: jitter.unit())
            let fireAt = clock.now().addingTimeInterval(delay)
            let timerName = "retry-\(inflight.callID.raw)-\(nextAttempt)"
            _ = try await commit(.conversation(conversation.id), [
                EventDraft(
                    type: EventType.effectRetry,
                    payload: .object([
                        "runID": .string(run.id.raw),
                        "callID": .string(inflight.callID.raw),
                        "attempt": .int(Int64(nextAttempt)),
                        "fireAt": .double(fireAt.timeIntervalSince1970),
                        "timerName": .string(timerName),
                        "kind": .string(inflight.effect.rawValue),
                        "error": .string(reason),
                    ])
                ),
            ])
            try await armTimer(name: timerName, fireAt: fireAt)
            return
        }
        _ = try await commit(.conversation(conversation.id), [
            Self.resultDraft(
                run: run,
                inflight: inflight,
                ok: false,
                output: .null,
                replayed: false,
                reconciled: false,
                error: reason
            ),
            EventDraft(
                type: EventType.runFailed,
                payload: .object([
                    "runID": .string(run.id.raw),
                    "reason": .string(reason),
                ])
            ),
        ])
    }

    private func armTimer(name: String, fireAt: Date) async throws {
        _ = try await commit(StreamID("timers"), [
            EventDraft(
                type: EventType.timerRequested,
                payload: .object([
                    "name": .string(name),
                    "fireAt": .double(fireAt.timeIntervalSince1970),
                ])
            ),
        ])
        await timers.schedule(name: name, fireAt: fireAt)
        await backgroundWake.scheduleBackgroundWake(earliest: fireAt, identifier: name)
    }

    private func fireDueTimers() async throws {
        let now = clock.now()
        var guardCount = 0
        while guardCount < 1_000 {
            guardCount += 1
            let projection = try await load()
            let due = projection.pendingTimers.values.filter { $0.fireAt <= now }.map(\.name).sorted()
            guard let name = due.first else { return }
            _ = try await commit(StreamID("timers"), [
                EventDraft(
                    type: EventType.timerFired,
                    payload: .object([
                        "name": .string(name),
                        "firedAt": .double(now.timeIntervalSince1970),
                    ])
                ),
            ])
            let again = try await load()
            if let match = Self.waitingRun(in: again, kind: "timer", name: name) {
                try await resolveWait(match.conversation, run: match.run, payload: .null)
            }
        }
    }

    private func reschedulePendingTimers() async {
        let now = clock.now()
        let projection = try? await load()
        for timer in projection?.pendingTimers.values.filter({ $0.fireAt > now }) ?? [] {
            await timers.schedule(name: timer.name, fireAt: timer.fireAt)
            await backgroundWake.scheduleBackgroundWake(earliest: timer.fireAt, identifier: timer.name)
        }
    }

    private func resolveWait(
        _ conversation: FoldedConversation,
        run: FoldedRun,
        payload: JSONValue
    ) async throws {
        guard let wait = run.wait else { return }
        var drafts = [
            Self.waitResolvedDraft(run: run, name: wait.name, payload: payload),
            Self.stepDraft(run: run, index: wait.stepIndex),
        ]
        if wait.kind == "signal" {
            drafts.append(EventDraft(
                type: EventType.signalConsumed,
                payload: .object(["name": .string(wait.name)])
            ))
            drafts.append(Self.messageDraft(
                role: "system",
                text: Self.display(payload),
                messageID: Self.freshMessageID()
            ))
        }
        _ = try await commit(.conversation(conversation.id), drafts)
    }

    private static func waitingRun(
        in projection: Projection,
        kind: String,
        name: String
    ) -> (conversation: FoldedConversation, run: FoldedRun)? {
        for key in projection.conversationOrder {
            guard let conversation = projection.conversations[key], let run = conversation.activeRun,
                  let wait = run.wait, wait.kind == kind, wait.name == name
            else { continue }
            return (conversation, run)
        }
        return nil
    }

    private static func waitResolvedDraft(run: FoldedRun, name: String, payload: JSONValue) -> EventDraft {
        EventDraft(
            type: EventType.waitResolved,
            payload: .object([
                "runID": .string(run.id.raw),
                "name": .string(name),
                "payload": payload,
            ])
        )
    }

    private static func replayAttempt(_ inflight: InflightEffect) -> Int {
        inflight.attempt > 1 ? inflight.attempt : 2
    }

    private func effectContext(
        _ inflight: InflightEffect,
        conversation: FoldedConversation,
        isReplay: Bool,
        attempt: Int
    ) -> EffectContext {
        EffectContext(
            key: inflight.key,
            conversationID: conversation.id,
            callID: inflight.callID,
            attempt: attempt,
            isReplay: isReplay
        )
    }

    private func commit(_ stream: StreamID, _ drafts: [EventDraft]) async throws -> [EventEnvelope] {
        do {
            return try await store.commit(fence: fence, stream: stream, events: drafts)
        } catch let error as DurableError {
            if case .fenced = error {
                poisoned = true
            }
            throw error
        }
    }

    private func load() async throws -> Projection {
        try Projection.fold(try await store.readAll())
    }

    private func ensureWritable() throws {
        if poisoned { throw DurableError.poisoned }
        if closed { throw DurableError.closed }
    }

    private func exclusively<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        await lock()
        do {
            let value = try await body()
            unlock()
            return value
        } catch {
            unlock()
            throw error
        }
    }

    private func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private static func recovery(
        _ conversation: FoldedConversation,
        _ run: FoldedRun,
        override: StatusView? = nil
    ) -> RecoveryAction {
        let view = override ?? view(of: conversation)
        return RecoveryAction(
            conversationID: conversation.id,
            runStatus: view.runStatus ?? run.status,
            resumeToken: view.resumeToken,
            finalText: view.finalText,
            failure: view.failure
        )
    }

    private static func view(of conversation: FoldedConversation) -> StatusView {
        if let run = conversation.activeRun {
            let queued = run.status == .suspended && conversation.submissions.contains { $0.runID == nil }
            return StatusView(
                queued: queued && run.status != .running,
                runStatus: run.status,
                resumeToken: run.pending?.token,
                finalText: run.finalText,
                failure: run.failure
            )
        }
        if conversation.submissions.contains(where: { $0.runID == nil }) {
            return StatusView(queued: true, runStatus: nil, resumeToken: nil, finalText: nil, failure: nil)
        }
        if let latest = conversation.latestRun {
            return StatusView(
                queued: false,
                runStatus: latest.status,
                resumeToken: nil,
                finalText: latest.finalText,
                failure: latest.failure
            )
        }
        return StatusView(queued: false, runStatus: nil, resumeToken: nil, finalText: nil, failure: nil)
    }

    private static func finalText(in conversation: FoldedConversation, fallback: String) -> String {
        for message in conversation.messages.reversed() {
            if message.role == "assistant" { return message.text }
        }
        return fallback
    }

    private static func freshMessageID() -> String {
        "m_" + UUID().uuidString.lowercased()
    }

    private static func messageDraft(role: String, text: String, messageID: String, callID: String? = nil) -> EventDraft {
        var fields: [String: JSONValue] = [
            "messageID": .string(messageID),
            "role": .string(role),
            "text": .string(text),
        ]
        if let callID {
            fields["callID"] = .string(callID)
        }
        return EventDraft(
            type: EventType.messageAppended,
            schemaVersion: EventType.messageAppendedCurrentVersion,
            payload: .object(fields)
        )
    }

    private static func stepDraft(run: FoldedRun, index: Int) -> EventDraft {
        EventDraft(
            type: EventType.stepCompleted,
            payload: .object([
                "runID": .string(run.id.raw),
                "stepIndex": .int(Int64(index)),
            ])
        )
    }

    private static func intentDraft(run: FoldedRun, inflight: InflightEffect) -> EventDraft {
        EventDraft(
            type: EventType.effectIntent,
            payload: .object([
                "runID": .string(run.id.raw),
                "stepIndex": .int(Int64(inflight.stepIndex)),
                "callID": .string(inflight.callID.raw),
                "tool": .string(inflight.tool),
                "effect": .string(inflight.effect.rawValue),
                "key": .string(inflight.key.raw),
                "arguments": inflight.arguments,
            ])
        )
    }

    private static func resultDraft(
        run: FoldedRun,
        inflight: InflightEffect,
        ok: Bool,
        output: JSONValue,
        replayed: Bool,
        reconciled: Bool,
        error: String?
    ) -> EventDraft {
        EventDraft(
            type: EventType.effectResult,
            payload: .object([
                "runID": .string(run.id.raw),
                "stepIndex": .int(Int64(inflight.stepIndex)),
                "callID": .string(inflight.callID.raw),
                "key": .string(inflight.key.raw),
                "ok": .bool(ok),
                "output": output,
                "replayed": .bool(replayed),
                "reconciled": .bool(reconciled),
                "error": error.map(JSONValue.string) ?? .null,
            ])
        )
    }

    private static func successDrafts(
        run: FoldedRun,
        inflight: InflightEffect,
        output: JSONValue,
        writes: [StateWrite],
        replayed: Bool,
        reconciled: Bool,
        completesStep: Bool = true
    ) -> [EventDraft] {
        var drafts = [
            resultDraft(
                run: run,
                inflight: inflight,
                ok: true,
                output: output,
                replayed: replayed,
                reconciled: reconciled,
                error: nil
            ),
        ]
        for write in writes {
            drafts.append(EventDraft(
                type: EventType.stateWrote,
                payload: .object([
                    "namespace": .string(write.namespace),
                    "key": .string(write.key),
                    "value": write.value,
                ])
            ))
        }
        drafts.append(messageDraft(
            role: "tool",
            text: Self.display(output),
            messageID: freshMessageID(),
            callID: inflight.callID.raw
        ))
        if completesStep {
            drafts.append(stepDraft(run: run, index: inflight.stepIndex))
        }
        return drafts
    }

    private static func providerTurnIsOpen(_ run: FoldedRun) -> Bool {
        guard run.plannedIndex == run.completedSteps, let planned = run.plannedStep else {
            return false
        }
        if case .providerTurn = planned { return true }
        return false
    }

    private static func approvalResolvedDraft(
        run: FoldedRun,
        approvalID: String,
        approved: Bool,
        reason: String?
    ) -> EventDraft {
        EventDraft(
            type: EventType.approvalResolved,
            payload: .object([
                "runID": .string(run.id.raw),
                "approvalID": .string(approvalID),
                "approved": .bool(approved),
                "reason": reason.map(JSONValue.string) ?? .null,
            ])
        )
    }

    private static func display(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        return value.canonicalJSON()
    }
}

private struct StatusView: Sendable, Equatable {
    var queued: Bool
    var runStatus: RunStatus?
    var resumeToken: ResumeToken?
    var finalText: String?
    var failure: String?
}
