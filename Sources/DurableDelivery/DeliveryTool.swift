import DurableCore
import Foundation

/// Journaled outbound delivery. The effect is `external` and reconciles as `.notDone`,
/// so a crash between intent and result retries with the same effect key.
/// That key is the `Idempotency-Key` header and the `delivery-id` JSON field.
/// APNs uses the documented `apns-id` header (a UUID derived from the key) instead.
public enum DeliveryTool {
    public static func make(
        http: any DeliveryHTTP,
        secrets: any DeliverySecretStore,
        clock: any DurableClock = SystemDurableClock(),
        apns: (any DeliveryHTTP)? = nil
    ) -> Tool {
        let tokens = ProviderTokenCache()
        let apnsTransport = apns
        return Tool(
            name: DeliveryToolID.name,
            effect: .external,
            summary: "Delivers a webhook, a Slack incoming webhook, or an APNs alert. A retryable failure uses the run's RetryPolicy.",
            reconcile: { _, _ in .notDone },
            run: { arguments, context in
                try await DeliverySender.perform(
                    arguments: arguments,
                    context: context,
                    http: http,
                    apns: apnsTransport ?? APNsLiveSender(),
                    secrets: secrets,
                    clock: clock,
                    tokens: tokens
                )
            }
        )
    }

    /// Webhooks and Slack use `URLSession`. APNs uses the live HTTP/2 sender, which is unavailable on Linux.
    public static func live(secrets: any DeliverySecretStore, clock: any DurableClock = SystemDurableClock()) -> Tool {
        make(http: URLSessionDeliveryHTTP(), secrets: secrets, clock: clock, apns: APNsLiveSender())
    }
}

enum DeliverySender {
    static func perform(
        arguments: JSONValue,
        context: EffectContext,
        http: any DeliveryHTTP,
        apns: any DeliveryHTTP,
        secrets: any DeliverySecretStore,
        clock: any DurableClock,
        tokens: ProviderTokenCache
    ) async throws -> ToolReturn {
        guard let fields = arguments.objectValue, let channel = fields["channel"]?.stringValue else {
            throw DeliveryRetry(retryable: false, reason: "delivery arguments are missing a channel")
        }
        do {
            switch channel {
            case "webhook":
                try await postWebhook(fields, context: context, http: http, secrets: secrets, clock: clock)
            case "slack":
                try await postSlack(fields, context: context, http: http, secrets: secrets, clock: clock)
            case "apns":
                try await postAPNs(fields, context: context, http: apns, secrets: secrets, clock: clock, tokens: tokens)
            default:
                throw DeliveryRetry(retryable: false, reason: "unknown delivery channel")
            }
        } catch is SimulatedProcessCrash {
            throw SimulatedProcessCrash()
        } catch let retry as DeliveryRetry {
            throw retry
        } catch {
            throw DeliveryRetry(retryable: true, reason: "network error")
        }
        return ToolReturn(output: .object([
            "delivery-id": .string(context.key.raw),
            "channel": .string(channel),
        ]))
    }

    private static func postWebhook(
        _ fields: [String: JSONValue],
        context: EffectContext,
        http: any DeliveryHTTP,
        secrets: any DeliverySecretStore,
        clock: any DurableClock
    ) async throws {
        let url = try await resolveURL(fields, accountKey: "urlSecretAccount", secrets: secrets)
        var object = fields["json"]?.objectValue ?? [:]
        object["delivery-id"] = .string(context.key.raw)
        let body = Data(JSONValue.object(object).canonicalJSON().utf8)
        var headers = baseHeaders(context)
        if let account = fields["signingSecretAccount"]?.stringValue {
            let secret = try await lookup(account, secrets: secrets)
            let timestamp = Int64(clock.now().timeIntervalSince1970)
            headers[WebhookSignature.timestampHeader] = String(timestamp)
            headers[WebhookSignature.signatureHeader] = WebhookSignature.sign(secret: secret, timestamp: timestamp, body: body)
        }
        if let account = fields["authorizationSecretAccount"]?.stringValue {
            headers["Authorization"] = try await lookup(account, secrets: secrets)
        }
        try await post(url: url, headers: headers, body: body, http: http, clock: clock)
    }

    private static func postSlack(
        _ fields: [String: JSONValue],
        context: EffectContext,
        http: any DeliveryHTTP,
        secrets: any DeliverySecretStore,
        clock: any DurableClock
    ) async throws {
        let url: String
        if let account = fields["webhookSecretAccount"]?.stringValue {
            url = try await lookup(account, secrets: secrets)
        } else if let literal = fields["url"]?.stringValue, !literal.isEmpty {
            url = literal
        } else {
            throw DeliveryRetry(retryable: false, reason: "slack webhook url is missing")
        }
        guard let text = fields["text"]?.stringValue else {
            throw DeliveryRetry(retryable: false, reason: "slack text is missing")
        }
        let body = Data(JSONValue.object([
            "delivery-id": .string(context.key.raw),
            "text": .string(text),
        ]).canonicalJSON().utf8)
        try await post(url: url, headers: baseHeaders(context), body: body, http: http, clock: clock)
    }

    private static func postAPNs(
        _ fields: [String: JSONValue],
        context: EffectContext,
        http: any DeliveryHTTP,
        secrets: any DeliverySecretStore,
        clock: any DurableClock,
        tokens: ProviderTokenCache
    ) async throws {
        guard let deviceToken = fields["deviceToken"]?.stringValue,
              let topic = fields["topic"]?.stringValue,
              let keyID = fields["keyID"]?.stringValue,
              let teamID = fields["teamID"]?.stringValue,
              let account = fields["authKeyAccount"]?.stringValue,
              let payload = fields["payload"]
        else {
            throw DeliveryRetry(retryable: false, reason: "APNs arguments are incomplete")
        }
        let pem = try await lookup(account, secrets: secrets)
        let token = try tokens.token(teamID: teamID, keyID: keyID, pem: pem, now: clock.now())
        let request = try APNsRequestBuilder.make(
            deviceToken: deviceToken,
            topic: topic,
            payload: payload,
            effectKey: context.key.raw,
            providerToken: token,
            sandbox: fields["sandbox"]?.boolValue ?? false,
            pushType: fields["pushType"]?.stringValue ?? "alert"
        )
        try await post(url: request.url, headers: request.headers, body: request.body, http: http, clock: clock)
    }

    private static func post(
        url: String,
        headers: [String: String],
        body: Data,
        http: any DeliveryHTTP,
        clock: any DurableClock
    ) async throws {
        let response: DeliveryHTTPResponse
        do {
            response = try await http.send(url: url, method: "POST", headers: headers, body: body)
        } catch is SimulatedProcessCrash {
            throw SimulatedProcessCrash()
        } catch let retry as DeliveryRetry {
            throw retry
        } catch {
            throw DeliveryRetry(retryable: true, reason: "network error")
        }
        if let failure = DeliveryRules.failure(status: response.status, headers: response.headers, now: clock.now()) {
            throw failure
        }
    }

    private static func baseHeaders(_ context: EffectContext) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Idempotency-Key": context.key.raw,
        ]
    }

    private static func resolveURL(_ fields: [String: JSONValue], accountKey: String, secrets: any DeliverySecretStore) async throws -> String {
        if let account = fields[accountKey]?.stringValue {
            return try await lookup(account, secrets: secrets)
        }
        guard let url = fields["url"]?.stringValue, !url.isEmpty else {
            throw DeliveryRetry(retryable: false, reason: "delivery url is missing")
        }
        return url
    }

    private static func lookup(_ account: String, secrets: any DeliverySecretStore) async throws -> String {
        let value: String?
        do {
            value = try await secrets.secret(account: account)
        } catch is SimulatedProcessCrash {
            throw SimulatedProcessCrash()
        } catch let retry as DeliveryRetry {
            throw retry
        } catch {
            throw DeliveryRetry(retryable: true, reason: "secret store unavailable")
        }
        guard let value, !value.isEmpty else {
            throw DeliveryRetry(retryable: false, reason: "missing secret account \(account)")
        }
        return value
    }
}

final class ProviderTokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var issuedAt: Date?
    private var fingerprint: String?

    func token(teamID: String, keyID: String, pem: String, now: Date) throws -> String {
        let fingerprint = APNsKeyFingerprint.make(teamID: teamID, keyID: keyID, pem: pem)
        lock.lock()
        if let token, let issuedAt, self.fingerprint == fingerprint, now.timeIntervalSince(issuedAt) < 50 * 60 {
            lock.unlock()
            return token
        }
        lock.unlock()
        let minted = try APNsProviderToken.make(teamID: teamID, keyID: keyID, issuedAt: now, pem: pem)
        lock.lock()
        token = minted
        issuedAt = now
        self.fingerprint = fingerprint
        lock.unlock()
        return minted
    }
}
