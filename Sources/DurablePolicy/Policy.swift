import DurableCore
import DurableSchedule
import Foundation

/// Whether a local notification should be shown. Quiet hours use the same window as routines:
/// `activeStart`/`activeEnd` are when a notification is allowed.
public struct NotificationPolicy: Sendable, Equatable {
    public var quiet: QuietHours?
    public var dailyCap: Int

    public init(quiet: QuietHours? = nil, dailyCap: Int = 3) {
        self.quiet = quiet
        self.dailyCap = max(0, dailyCap)
    }

    public func decide(
        dedupeKey: String,
        collapseID: String,
        now: Date,
        alreadyDelivered: [(key: String, at: Date)]
    ) -> NotificationDecision {
        if let quiet, !quiet.isActive(at: now) {
            return NotificationDecision(
                deliver: false,
                ruleID: "quiet-hours",
                disposition: "quiet-hours",
                dedupeKey: dedupeKey,
                collapseID: collapseID
            )
        }
        if !dedupeKey.isEmpty, alreadyDelivered.contains(where: { $0.key == dedupeKey }) {
            return NotificationDecision(
                deliver: false,
                ruleID: "dedupe",
                disposition: "duplicate",
                dedupeKey: dedupeKey,
                collapseID: collapseID
            )
        }
        let zone = TimeZone(identifier: quiet?.timeZone ?? "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let today = alreadyDelivered.filter { Self.sameDay($0.at, now, zone) }.count
        if today >= dailyCap {
            return NotificationDecision(
                deliver: false,
                ruleID: "daily-cap",
                disposition: "daily-cap",
                dedupeKey: dedupeKey,
                collapseID: collapseID
            )
        }
        return NotificationDecision(
            deliver: true,
            ruleID: "allow",
            disposition: "deliver",
            dedupeKey: dedupeKey,
            collapseID: collapseID
        )
    }

    private static func sameDay(_ lhs: Date, _ rhs: Date, _ zone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.isDate(lhs, inSameDayAs: rhs)
    }
}

public struct NotificationDecision: Sendable, Equatable {
    public var deliver: Bool
    public var ruleID: String
    public var disposition: String
    public var dedupeKey: String
    public var collapseID: String

    public init(deliver: Bool, ruleID: String, disposition: String, dedupeKey: String, collapseID: String) {
        self.deliver = deliver
        self.ruleID = ruleID
        self.disposition = disposition
        self.dedupeKey = dedupeKey
        self.collapseID = collapseID
    }
}

/// One approval rule. The first match wins. A match can force approval.
/// It cannot clear approval for an external effect while the run is unattended.
public struct ApprovalRule: Sendable, Equatable {
    public var id: String
    public var tool: String?
    public var effect: EffectKind?
    public var risk: ApprovalRisk?
    /// Every listed argument must equal this string. A missing argument does not match.
    public var arguments: [String: String]
    /// The rule applies only while this window is active.
    public var window: QuietHours?
    /// When set, the rule matches only that attendance mode.
    public var unattended: Bool?
    /// `true` asks to skip the person. Unattended external effects ignore that.
    public var autoApprove: Bool

    public init(
        id: String,
        tool: String? = nil,
        effect: EffectKind? = nil,
        risk: ApprovalRisk? = nil,
        arguments: [String: String] = [:],
        window: QuietHours? = nil,
        unattended: Bool? = nil,
        autoApprove: Bool
    ) {
        self.id = id
        self.tool = tool
        self.effect = effect
        self.risk = risk
        self.arguments = arguments
        self.window = window
        self.unattended = unattended
        self.autoApprove = autoApprove
    }

    func matches(_ subject: ApprovalSubject) -> Bool {
        if let tool, tool != subject.tool { return false }
        if let effect, effect != subject.effect { return false }
        if let risk, risk != subject.risk { return false }
        if let unattended, unattended != subject.unattended { return false }
        if let window, !window.isActive(at: subject.now) { return false }
        for (key, expected) in arguments {
            if subject.arguments[key] != expected { return false }
        }
        return true
    }
}

public struct ApprovalSubject: Sendable, Equatable {
    public var tool: String
    public var effect: EffectKind
    public var risk: ApprovalRisk
    public var arguments: [String: String]
    public var toolRequiresApproval: Bool
    public var unattended: Bool
    public var now: Date

    public init(
        tool: String,
        effect: EffectKind,
        risk: ApprovalRisk = .standard,
        arguments: [String: String] = [:],
        toolRequiresApproval: Bool,
        unattended: Bool,
        now: Date
    ) {
        self.tool = tool
        self.effect = effect
        self.risk = risk
        self.arguments = arguments
        self.toolRequiresApproval = toolRequiresApproval
        self.unattended = unattended
        self.now = now
    }
}

public struct ApprovalRuling: Sendable, Equatable {
    public var requiresApproval: Bool
    public var ruleID: String
    public var matchedRuleID: String
    public var reason: String

    public init(requiresApproval: Bool, ruleID: String, matchedRuleID: String, reason: String) {
        self.requiresApproval = requiresApproval
        self.ruleID = ruleID
        self.matchedRuleID = matchedRuleID
        self.reason = reason
    }
}

public struct ApprovalPolicy: Sendable, Equatable {
    public static let unattendedExternalRuleID = "unattended-external"

    public var rules: [ApprovalRule]

    public init(rules: [ApprovalRule]) {
        self.rules = rules
    }

    public func decide(_ subject: ApprovalSubject) -> ApprovalRuling {
        let matched = rules.first { $0.matches(subject) }
        if subject.unattended, subject.effect == .external {
            return ApprovalRuling(
                requiresApproval: true,
                ruleID: Self.unattendedExternalRuleID,
                matchedRuleID: matched?.id ?? "",
                reason: "unattended mode never auto-approves an external effect"
            )
        }
        if let matched {
            if matched.autoApprove {
                return ApprovalRuling(
                    requiresApproval: false,
                    ruleID: matched.id,
                    matchedRuleID: matched.id,
                    reason: "rule \(matched.id) auto-approves"
                )
            }
            return ApprovalRuling(
                requiresApproval: true,
                ruleID: matched.id,
                matchedRuleID: matched.id,
                reason: "rule \(matched.id) requires approval"
            )
        }
        if subject.toolRequiresApproval {
            return ApprovalRuling(
                requiresApproval: true,
                ruleID: "tool-flag",
                matchedRuleID: "",
                reason: "the tool requires approval"
            )
        }
        return ApprovalRuling(
            requiresApproval: false,
            ruleID: "none",
            matchedRuleID: "",
            reason: "no rule matched"
        )
    }
}

/// Journals notification and approval rulings. The engine still gates tools with `requiresApproval`.
/// Call this before a host treats an external effect as approved. Do not call it from inside a tool body.
public actor PolicyJournal {
    public static let stream = StreamID("policy")

    private let notifications: NotificationPolicy
    private let approvals: ApprovalPolicy
    private let engine: Engine
    private let store: any EventStore

    public init(notifications: NotificationPolicy, approvals: ApprovalPolicy, engine: Engine, store: any EventStore) {
        self.notifications = notifications
        self.approvals = approvals
        self.engine = engine
        self.store = store
    }

    public func considerNotification(dedupeKey: String, collapseID: String, now: Date) async throws -> NotificationDecision {
        let prior = try await delivered()
        let decision = notifications.decide(
            dedupeKey: dedupeKey,
            collapseID: collapseID,
            now: now,
            alreadyDelivered: prior
        )
        try await engine.record([
            EventDraft(
                type: EventType.notificationDecided,
                payload: .object([
                    "deliver": .bool(decision.deliver),
                    "ruleID": .string(decision.ruleID),
                    "disposition": .string(decision.disposition),
                    "dedupeKey": .string(decision.dedupeKey),
                    "collapseID": .string(decision.collapseID),
                ])
            ),
        ], stream: Self.stream)
        return decision
    }

    public func considerApproval(_ subject: ApprovalSubject) async throws -> ApprovalRuling {
        let ruling = approvals.decide(subject)
        try await engine.record([
            EventDraft(
                type: EventType.approvalPolicy,
                payload: .object([
                    "tool": .string(subject.tool),
                    "effect": .string(subject.effect.rawValue),
                    "requiresApproval": .bool(ruling.requiresApproval),
                    "ruleID": .string(ruling.ruleID),
                    "matchedRuleID": .string(ruling.matchedRuleID),
                    "unattended": .bool(subject.unattended),
                    "reason": .string(ruling.reason),
                ])
            ),
        ], stream: Self.stream)
        return ruling
    }

    private func delivered() async throws -> [(key: String, at: Date)] {
        try await store.readAll().compactMap { event in
            guard event.type == EventType.notificationDecided, event.payload["deliver"]?.boolValue == true else {
                return nil
            }
            return (event.payload["dedupeKey"]?.stringValue ?? "", event.recordedAt)
        }
    }
}
