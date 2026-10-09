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

/// Tool name the engine submits when a channel returns a `JournaledDelivery`.
public enum DeliveryToolID {
    public static let name = "durable.deliver"
}

/// One outbound delivery the engine will journal as its own run.
///
/// `arguments` must not contain secrets, webhook URLs that embed a token, or
/// an `Authorization` value. Name a secret account; the delivery tool resolves it at send time.
public struct JournaledDelivery: Sendable, Equatable {
    public var id: String
    public var toolName: String
    public var arguments: JSONValue

    public init(id: String, toolName: String = DeliveryToolID.name, arguments: JSONValue) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
    }
}

/// Where an APNs alert should go. The `.p8` key stays in the secret store under `authKeyAccount`.
public struct APNsDestination: Sendable, Equatable {
    public var deviceToken: String
    public var topic: String
    public var keyID: String
    public var teamID: String
    public var authKeyAccount: String
    public var sandbox: Bool
    public var pushType: String

    public init(
        deviceToken: String,
        topic: String,
        keyID: String,
        teamID: String,
        authKeyAccount: String,
        sandbox: Bool = false,
        pushType: String = "alert"
    ) {
        self.deviceToken = deviceToken
        self.topic = topic
        self.keyID = keyID
        self.teamID = teamID
        self.authKeyAccount = authKeyAccount
        self.sandbox = sandbox
        self.pushType = pushType
    }
}

/// Delivers a pending approval outside the event log. Must not call back into `Engine`.
public protocol ApprovalChannel: Sendable {
    func deliver(_ notice: ApprovalNotice) async
    /// Requests the engine journal a delivery run after `deliver` returns.
    /// The default is an empty list so a channel that only records a draft does not send.
    func journaledDeliveries(for notice: ApprovalNotice) -> [JournaledDelivery]
}

public struct NoOpApprovalChannel: ApprovalChannel {
    public init() {}

    public func deliver(_ notice: ApprovalNotice) async {}

    public func journaledDeliveries(for notice: ApprovalNotice) -> [JournaledDelivery] { [] }
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

    public func journaledDeliveries(for notice: ApprovalNotice) -> [JournaledDelivery] {
        channels.flatMap { $0.journaledDeliveries(for: notice) }
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

    public func journaledDeliveries(for notice: ApprovalNotice) -> [JournaledDelivery] { [] }
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
    /// When set, the engine journals an APNs delivery. The `.p8` is not in the arguments.
    public var destination: APNsDestination?

    public init(record: @escaping @Sendable (JSONValue) async -> Void, destination: APNsDestination? = nil) {
        self.record = record
        self.destination = destination
    }

    public func deliver(_ notice: ApprovalNotice) async {
        await record(PushApprovalPayload.json(notice))
    }

    public func journaledDeliveries(for notice: ApprovalNotice) -> [JournaledDelivery] {
        guard let destination else { return [] }
        let id = "\(notice.conversationID):\(notice.approvalID):apns"
        let payload = PushApprovalPayload.json(notice)
        return [
            JournaledDelivery(
                id: id,
                arguments: .object([
                    "channel": .string("apns"),
                    "deviceToken": .string(destination.deviceToken),
                    "topic": .string(destination.topic),
                    "keyID": .string(destination.keyID),
                    "teamID": .string(destination.teamID),
                    "authKeyAccount": .string(destination.authKeyAccount),
                    "sandbox": .bool(destination.sandbox),
                    "pushType": .string(destination.pushType),
                    "payload": payload,
                ])
            ),
        ]
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
    /// Sent as a header by the immediate transport. Never written to the event log.
    public var authorization: String?
    public var transport: any WebhookTransport
    /// When true, `deliver` does not post. The engine journals a delivery run instead.
    public var durable: Bool
    /// Account whose secret is the HMAC key. The secret itself is not journaled.
    public var signingSecretAccount: String?
    /// Account whose secret is the request URL (Slack) or a URL that embeds a token.
    public var urlSecretAccount: String?
    /// Account whose secret is the `Authorization` header value. Not journaled.
    public var authorizationSecretAccount: String?

    public init(
        url: String,
        style: Style,
        authorization: String? = nil,
        transport: any WebhookTransport,
        durable: Bool = false,
        signingSecretAccount: String? = nil,
        urlSecretAccount: String? = nil,
        authorizationSecretAccount: String? = nil
    ) {
        self.url = url
        self.style = style
        self.authorization = authorization
        self.transport = transport
        self.durable = durable
        self.signingSecretAccount = signingSecretAccount
        self.urlSecretAccount = urlSecretAccount
        self.authorizationSecretAccount = authorizationSecretAccount
    }

    public func deliver(_ notice: ApprovalNotice) async {
        if durable {
            return
        }
        let body: JSONValue
        switch style {
        case .slack:
            body = .object(["text": .string(notice.prompt)])
        case .generic:
            body = .object(Self.publicFields(notice))
        }
        var headers = ["Content-Type": "application/json"]
        if let authorization {
            headers["Authorization"] = authorization
        }
        await transport.post(url: url, body: body, headers: headers)
    }

    public func journaledDeliveries(for notice: ApprovalNotice) -> [JournaledDelivery] {
        guard durable else { return [] }
        let styleName = style == .slack ? "slack" : "webhook"
        var arguments: [String: JSONValue] = ["channel": .string(styleName)]
        if style == .slack {
            if let urlSecretAccount {
                arguments["webhookSecretAccount"] = .string(urlSecretAccount)
            } else {
                arguments["url"] = .string(url)
            }
            arguments["text"] = .string(notice.prompt)
        } else {
            if let urlSecretAccount {
                arguments["urlSecretAccount"] = .string(urlSecretAccount)
            } else {
                arguments["url"] = .string(url)
            }
            if let signingSecretAccount {
                arguments["signingSecretAccount"] = .string(signingSecretAccount)
            }
            if let authorizationSecretAccount {
                arguments["authorizationSecretAccount"] = .string(authorizationSecretAccount)
            }
            arguments["json"] = .object(Self.publicFields(notice))
        }
        return [
            JournaledDelivery(
                id: "\(notice.conversationID):\(notice.approvalID):\(styleName)",
                arguments: .object(arguments)
            ),
        ]
    }

    private static func publicFields(_ notice: ApprovalNotice) -> [String: JSONValue] {
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
        return fields
    }
}

public actor WebApprovalChannel: ApprovalChannel {
    public private(set) var pending: [ApprovalNotice] = []

    public init() {}

    public func deliver(_ notice: ApprovalNotice) {
        pending.append(notice)
    }

    public nonisolated func journaledDeliveries(for notice: ApprovalNotice) -> [JournaledDelivery] { [] }

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
