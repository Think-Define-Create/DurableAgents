import Foundation

public enum ApprovalRisk: String, Sendable, Equatable, Codable {
    case standard
    case high
}

/// How the approver authenticated. Higher ranks satisfy a lower requirement.
public enum AuthenticationLevel: String, Sendable, Equatable, Codable, Comparable {
    case anonymous
    case session
    case devicePasscode
    case biometric

    public static func < (lhs: AuthenticationLevel, rhs: AuthenticationLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    var rank: Int {
        switch self {
        case .anonymous: 0
        case .session: 1
        case .devicePasscode: 2
        case .biometric: 3
        }
    }
}

public struct Approver: Sendable, Equatable {
    public var id: String
    public var authLevel: AuthenticationLevel

    public init(id: String, authLevel: AuthenticationLevel) {
        self.id = id
        self.authLevel = authLevel
    }
}

public struct ApprovalNotice: Sendable, Equatable {
    public var conversationID: String
    public var runID: String
    public var approvalID: String
    public var prompt: String
    public var risk: ApprovalRisk
    public var purpose: String
    public var token: String
    public var expiresAt: Date?
    public var audience: String?

    public init(
        conversationID: String,
        runID: String,
        approvalID: String,
        prompt: String,
        risk: ApprovalRisk,
        purpose: String,
        token: String,
        expiresAt: Date?,
        audience: String?
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.approvalID = approvalID
        self.prompt = prompt
        self.risk = risk
        self.purpose = purpose
        self.token = token
        self.expiresAt = expiresAt
        self.audience = audience
    }
}

/// Delivers a pending approval outside the event log. Must not call back into `Engine`.
public protocol ApprovalChannel: Sendable {
    func deliver(_ notice: ApprovalNotice) async
}

public struct NoOpApprovalChannel: ApprovalChannel {
    public init() {}

    public func deliver(_ notice: ApprovalNotice) async {}
}

public struct MultiplexApprovalChannel: ApprovalChannel {
    public var channels: [any ApprovalChannel]

    public init(channels: [any ApprovalChannel]) {
        self.channels = channels
    }

    public func deliver(_ notice: ApprovalNotice) async {
        for channel in channels {
            await channel.deliver(notice)
        }
    }
}

public struct LocalNotificationDraft: Sendable, Equatable {
    public var identifier: String
    public var title: String
    public var body: String
    public var category: String
    public var approveAction: String
    public var rejectAction: String

    public static let categoryIdentifier = "durable.approval"

    public init(
        identifier: String,
        title: String,
        body: String,
        category: String,
        approveAction: String,
        rejectAction: String
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.category = category
        self.approveAction = approveAction
        self.rejectAction = rejectAction
    }

    public static func make(_ notice: ApprovalNotice) -> LocalNotificationDraft {
        LocalNotificationDraft(
            identifier: notice.token,
            title: notice.risk == .high ? "High-risk approval" : "Approval needed",
            body: notice.prompt,
            category: categoryIdentifier,
            approveAction: "approve",
            rejectAction: "reject"
        )
    }
}

public struct LocalNotificationChannel: ApprovalChannel {
    public var record: @Sendable (LocalNotificationDraft) async -> Void

    public init(record: @escaping @Sendable (LocalNotificationDraft) async -> Void) {
        self.record = record
    }

    public func deliver(_ notice: ApprovalNotice) async {
        await record(LocalNotificationDraft.make(notice))
    }
}

/// APNs alert payload. Keys are the documented `aps` alert, category, and sound fields, plus our ids outside `aps`.
public enum PushApprovalPayload {
    public static func json(_ notice: ApprovalNotice) -> JSONValue {
        var aps: [String: JSONValue] = [
            "alert": .object([
                "title": .string(notice.risk == .high ? "High-risk approval" : "Approval needed"),
                "body": .string(notice.prompt),
            ]),
            "category": .string(LocalNotificationDraft.categoryIdentifier),
            "sound": .string("default"),
        ]
        if notice.expiresAt != nil {
            aps["interruption-level"] = .string(notice.risk == .high ? "time-sensitive" : "active")
        }
        var body: [String: JSONValue] = [
            "aps": .object(aps),
            "approvalID": .string(notice.approvalID),
            "conversationID": .string(notice.conversationID),
            "token": .string(notice.token),
        ]
        if let audience = notice.audience {
            body["audience"] = .string(audience)
        }
        return .object(body)
    }
}

public struct PushApprovalChannel: ApprovalChannel {
    public var record: @Sendable (JSONValue) async -> Void

    public init(record: @escaping @Sendable (JSONValue) async -> Void) {
        self.record = record
    }

    public func deliver(_ notice: ApprovalNotice) async {
        await record(PushApprovalPayload.json(notice))
    }
}

public protocol WebhookTransport: Sendable {
    func post(url: String, body: JSONValue, headers: [String: String]) async
}

public struct WebhookApprovalChannel: ApprovalChannel {
    public enum Style: Sendable {
        /// Slack incoming webhook: a JSON object with `text`.
        case slack
        case generic
    }

    public var url: String
    public var style: Style
    /// Sent as a header by the transport. Never written to the event log.
    public var authorization: String?
    public var transport: any WebhookTransport

    public init(url: String, style: Style, authorization: String? = nil, transport: any WebhookTransport) {
        self.url = url
        self.style = style
        self.authorization = authorization
        self.transport = transport
    }

    public func deliver(_ notice: ApprovalNotice) async {
        let body: JSONValue
        switch style {
        case .slack:
            body = .object(["text": .string(notice.prompt)])
        case .generic:
            var fields: [String: JSONValue] = [
                "approvalID": .string(notice.approvalID),
                "conversationID": .string(notice.conversationID),
                "prompt": .string(notice.prompt),
                "risk": .string(notice.risk.rawValue),
                "token": .string(notice.token),
            ]
            if let expiresAt = notice.expiresAt {
                fields["expiresAt"] = .double(expiresAt.timeIntervalSince1970)
            }
            body = .object(fields)
        }
        var headers = ["Content-Type": "application/json"]
        if let authorization {
            headers["Authorization"] = authorization
        }
        await transport.post(url: url, body: body, headers: headers)
    }
}

public actor WebApprovalChannel: ApprovalChannel {
    public private(set) var pending: [ApprovalNotice] = []

    public init() {}

    public func deliver(_ notice: ApprovalNotice) {
        pending.append(notice)
    }

    public func remove(_ approvalID: String) {
        pending.removeAll { $0.approvalID == approvalID }
    }
}

public enum ApprovalAppleSupport {
    public static var localAuthenticationCompiled: Bool {
        #if canImport(LocalAuthentication)
        true
        #else
        false
        #endif
    }

    public static var activityKitCompiled: Bool {
        #if canImport(ActivityKit)
        true
        #else
        false
        #endif
    }

    public static var userNotificationsCompiled: Bool {
        #if canImport(UserNotifications)
        true
        #else
        false
        #endif
    }
}
