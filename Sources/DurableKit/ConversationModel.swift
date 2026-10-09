import DurableCore
import Foundation

#if canImport(Observation)
import Observation
#endif

public enum ConversationRunStatus: String, Sendable, Equatable {
    case idle
    case running
    case suspendedForApproval
    case failed
    case done
}

public struct PendingApprovalInfo: Sendable, Equatable {
    public var approvalID: String
    public var prompt: String
    public var token: ResumeToken

    public init(approvalID: String, prompt: String, token: ResumeToken) {
        self.approvalID = approvalID
        self.prompt = prompt
        self.token = token
    }
}

/// Main-actor view of one conversation. SwiftUI can observe it when Observation is linked.
#if canImport(Observation)
@Observable
#endif
@MainActor
public final class ConversationModel {
    public let backendLabel: String
    public private(set) var messages: [TranscriptMessage] = []
    public private(set) var status: ConversationRunStatus = .idle
    public private(set) var pendingApproval: PendingApprovalInfo?
    public private(set) var events: [EventEnvelope] = []
    public private(set) var failure: String?
    public let eventLog: AsyncStream<EventEnvelope>

    private let engine: Engine
    private var conversationID: ConversationID?
    private let continuation: AsyncStream<EventEnvelope>.Continuation
    private var lastYieldedSeq: UInt64 = 0

    public static func open(
        store: any EventStore,
        tools: [Tool],
        model: any ModelStep,
        backendLabel: String,
        conversationID: ConversationID? = nil
    ) async throws -> ConversationModel {
        let engine = try await Engine(store: store, tools: tools, model: model)
        let model = ConversationModel(
            engine: engine,
            backendLabel: backendLabel,
            conversationID: conversationID
        )
        try await model.recoverOnLaunch()
        return model
    }

    private init(engine: Engine, backendLabel: String, conversationID: ConversationID?) {
        self.engine = engine
        self.backendLabel = backendLabel
        self.conversationID = conversationID
        let (stream, continuation) = AsyncStream.makeStream(
            of: EventEnvelope.self,
            bufferingPolicy: .unbounded
        )
        self.eventLog = stream
        self.continuation = continuation
    }

    public func recoverOnLaunch() async throws {
        let actions = try await engine.recover()
        if conversationID == nil {
            conversationID = actions.first?.conversationID
        }
        if conversationID == nil {
            conversationID = try await engine.listConversations().last
        }
        try await refresh()
    }

    public func send(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw DurableError.invariant("message is empty")
        }
        try await perform {
            let requestID = "req_" + UUID().uuidString.lowercased()
            let result = try await engine.submitTurn(trimmed, requestID: requestID, to: conversationID)
            conversationID = result.conversationID
        }
    }

    public func submitScripted(_ submission: Submission) async throws {
        try await perform {
            let result = try await engine.submit(submission, to: conversationID)
            conversationID = result.conversationID
        }
    }

    public func approve() async throws {
        guard let pending = pendingApproval else {
            throw DurableError.notSuspended
        }
        try await perform {
            _ = try await engine.resume(token: pending.token, decision: .approved)
        }
    }

    public func reject(_ reason: String = "denied") async throws {
        guard let pending = pendingApproval else {
            throw DurableError.notSuspended
        }
        try await perform {
            _ = try await engine.resume(token: pending.token, decision: .denied(reason))
        }
    }

    public func close() async {
        await engine.close()
    }

    private func perform(_ body: () async throws -> Void) async throws {
        if status != .suspendedForApproval {
            status = .running
        }
        do {
            try await body()
            try await refresh()
        } catch {
            try? await refresh()
            throw error
        }
    }

    private func refresh() async throws {
        guard let conversationID else {
            messages = []
            events = []
            status = .idle
            pendingApproval = nil
            failure = nil
            return
        }
        let snapshot = try await engine.snapshot(conversationID)
        let envelopes = try await engine.events(for: conversationID)
        messages = snapshot.messages
        events = envelopes
        failure = snapshot.run?.failure
        status = Self.status(of: snapshot)
        pendingApproval = Self.pending(in: envelopes, snapshot: snapshot)
        for event in envelopes where event.globalSeq > lastYieldedSeq {
            continuation.yield(event)
            lastYieldedSeq = event.globalSeq
        }
    }

    private static func status(of snapshot: ConversationSnapshot) -> ConversationRunStatus {
        switch snapshot.run?.status {
        case .running:
            return .running
        case .suspended:
            return .suspendedForApproval
        case .failed:
            return .failed
        case .completed:
            return .done
        case nil:
            return snapshot.messages.isEmpty ? .idle : .done
        }
    }

    private static func pending(in events: [EventEnvelope], snapshot: ConversationSnapshot) -> PendingApprovalInfo? {
        guard snapshot.run?.status == .suspended, let token = snapshot.run?.resumeToken else {
            return nil
        }
        let prompt = events.last { event in
            event.type == EventType.approvalRequested && event.payload["token"]?.stringValue == token.raw
        }?.payload["prompt"]?.stringValue ?? ""
        return PendingApprovalInfo(approvalID: token.approvalID, prompt: prompt, token: token)
    }
}
