import Crypto
import DurableCore
import DurableDelivery
import DurableStore
import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

@Test func standardPolicyIsTheOptInSchedule() {
    let policy = RetryPolicy.standard
    #expect(policy.maxAttempts == 5)
    #expect(policy.initialBackoffSeconds == 0.5)
    #expect(policy.multiplier == 2)
    #expect(policy.jitterRatio == 0.2)
    #expect(!policy.allowsAutomaticRetry(.external))
    #expect(policy.allowsAutomaticRetry(.idempotent))
    #expect(abs(policy.delaySeconds(forAttempt: 2, jitterUnit: 0) - 0.4) < 0.000_001)
    #expect(abs(policy.delaySeconds(forAttempt: 2, jitterUnit: 1) - 0.6) < 0.000_001)
    #expect(abs(policy.delaySeconds(forAttempt: 2, jitterUnit: 0.5) - 0.5) < 0.000_001)
}

@Test func webhookSignatureRejectsTamperingAndReplay() {
    let body = Data(#"{"delivery-id":"fx:1","ok":true}"#.utf8)
    let secret = "hmac-secret-value"
    let signature = WebhookSignature.sign(secret: secret, timestamp: 1_700_000_000, body: body)
    #expect(signature.hasPrefix("v1="))
    #expect(WebhookSignature.verify(
        secret: secret,
        timestamp: 1_700_000_000,
        body: body,
        signature: signature,
        now: 1_700_000_100
    ))
    #expect(!WebhookSignature.verify(
        secret: secret,
        timestamp: 1_700_000_000,
        body: body,
        signature: signature,
        now: 1_700_000_000 + WebhookSignature.defaultTolerance + 1
    ))
    var tampered = Data(body)
    tampered.append(contentsOf: [0x20])
    #expect(!WebhookSignature.verify(
        secret: secret,
        timestamp: 1_700_000_000,
        body: tampered,
        signature: signature,
        now: 1_700_000_000
    ))
    #expect(!WebhookSignature.verify(
        secret: "other-secret",
        timestamp: 1_700_000_000,
        body: body,
        signature: signature,
        now: 1_700_000_000
    ))
}

@Test func deliveryRulesRetryServerErrorsAndRefuseOtherClientErrors() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(DeliveryRules.failure(status: 204, headers: [:], now: now) == nil)
    let unavailable = DeliveryRules.failure(status: 503, headers: ["Retry-After": "15"], now: now)
    #expect(unavailable?.retryable == true)
    #expect(unavailable?.retryAfter == 15)
    #expect(unavailable?.status == 503)
    let limited = DeliveryRules.failure(status: 429, headers: [:], now: now)
    #expect(limited?.retryable == true)
    #expect(limited?.retryAfter == nil)
    let rejected = DeliveryRules.failure(status: 400, headers: ["Retry-After": "15"], now: now)
    #expect(rejected?.retryable == false)
    #expect(rejected?.status == 400)
    let offline = DeliveryRules.failure(status: nil, headers: [:], now: now)
    #expect(offline?.retryable == true)
    #expect(offline?.status == nil)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    let when = formatter.string(from: now.addingTimeInterval(30))
    let dated = DeliveryRules.failure(status: 500, headers: ["retry-after": when], now: now)
    #expect(dated?.retryAfter == 30)
}

@Test func providerTokenIsAnES256JWT() throws {
    let key = P256.Signing.PrivateKey()
    let issued = Date(timeIntervalSince1970: 1_700_000_000)
    let token = try APNsProviderToken.make(teamID: "TEAMID1234", keyID: "KEYID12345", issuedAt: issued, pem: key.pemRepresentation)
    let parts = token.split(separator: ".")
    #expect(parts.count == 3)
    let headerJSON = try jsonPart(parts[0])
    let claimsJSON = try jsonPart(parts[1])
    #expect(headerJSON["alg"]?.stringValue == "ES256")
    #expect(headerJSON["kid"]?.stringValue == "KEYID12345")
    #expect(claimsJSON["iss"]?.stringValue == "TEAMID1234")
    #expect(claimsJSON["iat"]?.intValue == 1_700_000_000)
    let signingInput = parts[0] + "." + parts[1]
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(decodeBase64URL(String(parts[2]))))
    #expect(key.publicKey.isValidSignature(signature, for: Data(signingInput.utf8)))
    #expect(throws: DeliveryRetry.self) {
        try APNsProviderToken.make(teamID: "short", keyID: "KEYID12345", issuedAt: issued, pem: key.pemRepresentation)
    }
}

@Test func apnsRequestUsesDocumentedHeadersAndAStableID() throws {
    let request = try APNsRequestBuilder.make(
        deviceToken: "abc123",
        topic: "com.example.escrow",
        payload: .object(["aps": .object(["alert": .string("Approve")])]),
        effectKey: "fx:store:conv:deliver",
        providerToken: "jwt-token",
        sandbox: true,
        pushType: "alert"
    )
    #expect(request.url == "https://api.sandbox.push.apple.com/3/device/abc123")
    #expect(request.headers["authorization"] == "bearer jwt-token")
    #expect(request.headers["apns-topic"] == "com.example.escrow")
    #expect(request.headers["apns-push-type"] == "alert")
    #expect(request.headers["apns-priority"] == "10")
    #expect(request.headers["Idempotency-Key"] == nil)
    let again = try APNsRequestBuilder.make(
        deviceToken: "abc123",
        topic: "com.example.escrow",
        payload: .object(["aps": .object(["alert": .string("Approve")])]),
        effectKey: "fx:store:conv:deliver",
        providerToken: "jwt-token",
        sandbox: true,
        pushType: "alert"
    )
    #expect(request.headers["apns-id"] == again.headers["apns-id"])
    let body = try JSONValue.parse(String(decoding: request.body, as: UTF8.self))
    #expect(body["delivery-id"]?.stringValue == "fx:store:conv:deliver")
    #expect(body["aps"]?["alert"]?.stringValue == "Approve")
    #if canImport(Darwin)
    #expect(APNsSupport.liveSenderCompiled)
    #else
    #expect(!APNsSupport.liveSenderCompiled)
    #endif
}

/// On Darwin the sender is live and would reach Apple, so this runs only where it is stubbed.
#if !canImport(Darwin)
@Test func liveAPNsSenderIsUnavailableOnLinux() async {
    await #expect(throws: DeliveryRetry.self) {
        try await APNsLiveSender().send(url: "https://api.push.apple.com/3/device/abc", method: "POST", headers: [:], body: Data())
    }
}
#endif

@Test func webhookRetriesOnServerErrorWithTheSameIdempotencyKey() async throws {
    let http = ScriptedHTTP(responses: [ScriptedStatus(503), ScriptedStatus(200)])
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let tool = DeliveryTool.make(http: http, secrets: MapSecrets([:]), clock: clock)
    let engine = try await Engine(store: store, tools: [tool], retryPolicy: .standard, clock: clock)
    let started = try await engine.submit(Submission(
        requestID: "r1",
        text: "send",
        script: deliveryScript(arguments: webhookArguments(url: "https://example.test/hook"))
    ))
    #expect(started.runStatus == .running)
    #expect(await http.calls.count == 1)
    clock.advance(by: 0.2)
    let early = try await engine.pumpTimers()
    #expect(early.first?.runStatus == .running)
    #expect(await http.calls.count == 1)
    clock.advance(by: 0.3)
    let done = try await engine.pumpTimers()
    #expect(done.first?.runStatus == .completed)
    let calls = await http.calls
    #expect(calls.count == 2)
    #expect(calls[0].headers["Idempotency-Key"] == calls[1].headers["Idempotency-Key"])
    let first = try JSONValue.parse(calls[0].body)
    let second = try JSONValue.parse(calls[1].body)
    #expect(first["delivery-id"]?.stringValue == calls[0].headers["Idempotency-Key"])
    #expect(second["delivery-id"]?.stringValue == calls[0].headers["Idempotency-Key"])
    await engine.close()
}

@Test func retryAfterBeatsThePolicyDelay() async throws {
    let http = ScriptedHTTP(responses: [
        ScriptedStatus(429, ["Retry-After": "9"]),
        ScriptedStatus(200),
    ])
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let tool = DeliveryTool.make(http: http, secrets: MapSecrets([:]), clock: clock)
    let engine = try await Engine(store: store, tools: [tool], retryPolicy: .standard, clock: clock)
    let started = try await engine.submit(Submission(
        requestID: "r1",
        text: "send",
        script: deliveryScript(arguments: webhookArguments(url: "https://example.test/hook"))
    ))
    #expect(started.runStatus == .running)
    clock.advance(by: 8)
    #expect(try await engine.pumpTimers().first?.runStatus == .running)
    #expect(await http.calls.count == 1)
    clock.advance(by: 1)
    #expect(try await engine.pumpTimers().first?.runStatus == .completed)
    #expect(await http.calls.count == 2)
    await engine.close()
}

@Test func clientErrorDeadLettersWithoutRetry() async throws {
    let http = ScriptedHTTP(responses: [ScriptedStatus(400)])
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let tool = DeliveryTool.make(http: http, secrets: MapSecrets([:]), clock: clock)
    let engine = try await Engine(store: store, tools: [tool], retryPolicy: .standard, clock: clock)
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "send",
        script: deliveryScript(arguments: webhookArguments(url: "https://example.test/hook"))
    ))
    #expect(result.runStatus == .failed)
    #expect(await http.calls.count == 1)
    let events = try await engine.events(for: result.conversationID)
    let dead = try #require(events.first { $0.type == EventType.deliveryDeadLettered })
    #expect(dead.payload["status"]?.intValue == 400)
    #expect(!events.contains { $0.type == EventType.effectRetry })
    await engine.close()
}

@Test func exhaustedDeliveriesDeadLetter() async throws {
    let http = ScriptedHTTP(responses: Array(repeating: ScriptedStatus(500), count: 5))
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let tool = DeliveryTool.make(http: http, secrets: MapSecrets([:]), clock: clock)
    let engine = try await Engine(store: store, tools: [tool], retryPolicy: .standard, clock: clock)
    let started = try await engine.submit(Submission(
        requestID: "r1",
        text: "send",
        script: deliveryScript(arguments: webhookArguments(url: "https://example.test/hook"))
    ))
    #expect(started.runStatus == .running)
    for delay in [0.5, 1.0, 2.0, 4.0] {
        clock.advance(by: delay)
        _ = try await engine.pumpTimers()
    }
    #expect(await http.calls.count == 5)
    let events = try await store.readAll()
    let dead = try #require(events.first { $0.type == EventType.deliveryDeadLettered })
    #expect(dead.payload["attempts"]?.intValue == 5)
    #expect(events.contains { $0.type == EventType.runFailed })
    await engine.close()
}

@Test func crashedDeliveryResumesWithTheSameKey() async throws {
    let http = ScriptedHTTP(responses: [ScriptedStatus(200)])
    await http.crashNext()
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let arguments = webhookArguments(url: "https://example.test/hook")
    let tool = DeliveryTool.make(http: http, secrets: MapSecrets([:]), clock: clock)
    let engine = try await Engine(store: store, tools: [tool], retryPolicy: .standard, clock: clock)
    await #expect(throws: SimulatedProcessCrash.self) {
        try await engine.submit(Submission(
            requestID: "r1",
            text: "send",
            script: deliveryScript(arguments: arguments)
        ))
    }
    await engine.close()
    let midpoint = try await store.readAll()
    #expect(midpoint.contains { $0.type == EventType.effectIntent })
    #expect(!midpoint.contains { $0.type == EventType.effectResult })

    let restarted = try await Engine(store: store, tools: [tool], retryPolicy: .standard, clock: clock)
    let actions = try await restarted.recover()
    #expect(actions.first?.runStatus == .completed)
    let calls = await http.calls
    #expect(calls.count == 2)
    #expect(calls[0].headers["Idempotency-Key"] == calls[1].headers["Idempotency-Key"])
    #expect(calls[0].headers["Idempotency-Key"]?.hasPrefix("fx:") == true)
    await restarted.close()
}

@Test func durableWebhookSignsTheBodyAndLeavesSecretsOutOfTheLog() async throws {
    let secret = "hmac-secret-value"
    let authorization = "Bearer super-secret-token"
    let http = ScriptedHTTP(responses: [ScriptedStatus(200)])
    let immediate = CountingWebhook()
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let channel = WebhookApprovalChannel(
        url: "https://example.test/hook",
        style: .generic,
        authorization: authorization,
        transport: immediate,
        durable: true,
        signingSecretAccount: "hook-hmac",
        authorizationSecretAccount: "hook-auth"
    )
    let tool = DeliveryTool.make(
        http: http,
        secrets: MapSecrets(["hook-hmac": secret, "hook-auth": authorization]),
        clock: clock
    )
    let engine = try await Engine(store: store, tools: [tool], retryPolicy: .stub, clock: clock, approvals: channel)
    let suspended = try await engine.submit(Submission(
        requestID: "approve-1",
        text: "please",
        script: Script(steps: [.approval(id: "a1", prompt: "Send the wire?"), .finish("sent")])
    ))
    #expect(suspended.runStatus == .suspended)
    #expect(await immediate.count == 0)
    let calls = await http.calls
    #expect(calls.count == 1)
    #expect(calls[0].headers["X-Timestamp"] == "1700000000")
    #expect(calls[0].headers["Authorization"] == authorization)
    let signed = Data(calls[0].body.utf8)
    #expect(WebhookSignature.verify(
        secret: secret,
        timestamp: 1_700_000_000,
        body: signed,
        signature: try #require(calls[0].headers["X-Signature"]),
        now: 1_700_000_000
    ))
    let body = try JSONValue.parse(calls[0].body)
    #expect(body["delivery-id"]?.stringValue == calls[0].headers["Idempotency-Key"])
    #expect(body["prompt"]?.stringValue == "Send the wire?")
    let dumped = try await store.readAll().map { $0.payload.canonicalJSON() }.joined(separator: "\n")
    #expect(!dumped.contains(secret))
    #expect(!dumped.contains(authorization))
    let deliveryStart = try #require(try await store.readAll().first {
        $0.type == EventType.runStarted && $0.payload["requestID"]?.stringValue?.hasPrefix("delivery:") == true
    })
    #expect(deliveryStart.payload["retry"]?["maxAttempts"]?.intValue == 5)
    await engine.close()
}

@Test func slackWebhookResolvesTheURLFromASecret() async throws {
    let slackURL = "https://hooks.slack.com/services/T9/B9/supersecret"
    let http = ScriptedHTTP(responses: [ScriptedStatus(200)])
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let channel = WebhookApprovalChannel(
        url: slackURL,
        style: .slack,
        transport: CountingWebhook(),
        durable: true,
        urlSecretAccount: "slack-incoming"
    )
    let tool = DeliveryTool.make(http: http, secrets: MapSecrets(["slack-incoming": slackURL]), clock: clock)
    let engine = try await Engine(store: store, tools: [tool], clock: clock, approvals: channel)
    _ = try await engine.submit(Submission(
        requestID: "approve-1",
        text: "please",
        script: Script(steps: [.approval(id: "a1", prompt: "Approval needed")])
    ))
    let calls = await http.calls
    #expect(calls.count == 1)
    #expect(calls[0].url == slackURL)
    #expect(calls[0].headers["X-Signature"] == nil)
    let body = try JSONValue.parse(calls[0].body)
    #expect(body["text"]?.stringValue == "Approval needed")
    #expect(body["delivery-id"] != nil)
    let dumped = try await store.readAll().map { $0.payload.canonicalJSON() }.joined(separator: "\n")
    #expect(!dumped.contains(slackURL))
    #expect(!dumped.contains("supersecret"))
    await engine.close()
}

@Test func missingDeliveryToolIsRetriedWhenALaterEngineRecovers() async throws {
    let http = ScriptedHTTP(responses: [ScriptedStatus(200)])
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let channel = WebhookApprovalChannel(
        url: "https://example.test/hook",
        style: .generic,
        transport: CountingWebhook(),
        durable: true
    )
    let first = try await Engine(store: store, clock: clock, approvals: channel)
    let suspended = try await first.submit(Submission(
        requestID: "approve-1",
        text: "please",
        script: Script(steps: [.approval(id: "a1", prompt: "Hold")])
    ))
    #expect(suspended.runStatus == .suspended)
    #expect(await http.calls.count == 0)
    await first.close()

    let tool = DeliveryTool.make(http: http, secrets: MapSecrets([:]), clock: clock)
    let restarted = try await Engine(store: store, tools: [tool], clock: clock, approvals: channel)
    _ = try await restarted.recover()
    #expect(await http.calls.count == 1)
    await restarted.close()
}

@Test func apnsDeliveryBuildsASignedRequestWithoutJournalingTheKey() async throws {
    let key = P256.Signing.PrivateKey()
    let pem = key.pemRepresentation
    let http = ScriptedHTTP(responses: [ScriptedStatus(200)])
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let destination = APNsDestination(
        deviceToken: "abc123",
        topic: "com.example.escrow",
        keyID: "KEYID12345",
        teamID: "TEAMID1234",
        authKeyAccount: "apns-p8",
        sandbox: true
    )
    let channel = PushApprovalChannel(record: { _ in }, destination: destination)
    let tool = DeliveryTool.make(http: http, secrets: MapSecrets(["apns-p8": pem]), clock: clock, apns: http)
    let engine = try await Engine(store: store, tools: [tool], clock: clock, approvals: channel)
    _ = try await engine.submit(Submission(
        requestID: "approve-1",
        text: "please",
        script: Script(steps: [.approval(id: "a1", prompt: "Approve the wire")])
    ))
    let call = try #require(await http.calls.first)
    #expect(call.url == "https://api.sandbox.push.apple.com/3/device/abc123")
    #expect(call.headers["apns-topic"] == "com.example.escrow")
    #expect(call.headers["apns-push-type"] == "alert")
    #expect(call.headers["apns-priority"] == "10")
    #expect(call.headers["Idempotency-Key"] == nil)
    let authorization = try #require(call.headers["authorization"])
    #expect(authorization.hasPrefix("bearer "))
    let token = String(authorization.dropFirst("bearer ".count))
    let parts = token.split(separator: ".")
    let signingInput = parts[0] + "." + parts[1]
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(decodeBase64URL(String(parts[2]))))
    #expect(key.publicKey.isValidSignature(signature, for: Data(signingInput.utf8)))
    let body = try JSONValue.parse(call.body)
    #expect(body["delivery-id"]?.stringValue?.hasPrefix("fx:") == true)
    #expect(body["approvalID"]?.stringValue == "a1")
    let dumped = try await store.readAll().map { $0.payload.canonicalJSON() }.joined(separator: "\n")
    #expect(!dumped.contains(pem))
    #expect(!dumped.contains("BEGIN PRIVATE KEY"))
    await engine.close()
}

@Test func loopbackServerSeesTheIdempotencyKeyAndSignature() async throws {
    let server = LoopbackHTTPServer()
    let port = try server.start()
    defer { server.stop() }
    let secret = "loopback-hmac"
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let tool = DeliveryTool.make(
        http: URLSessionDeliveryHTTP(timeout: 5),
        secrets: MapSecrets(["hook-hmac": secret]),
        clock: clock
    )
    let engine = try await Engine(store: store, tools: [tool], retryPolicy: .standard, clock: clock)
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "send",
        script: deliveryScript(arguments: .object([
            "channel": .string("webhook"),
            "url": .string("http://127.0.0.1:\(port)/hook"),
            "signingSecretAccount": .string("hook-hmac"),
            "json": .object(["hello": .string("wire")]),
        ]))
    ))
    #expect(result.runStatus == .completed)
    let raw = try #require(server.recorded().first)
    let folded = raw.lowercased()
    #expect(folded.contains("idempotency-key:"))
    #expect(folded.contains("x-signature: v1="))
    #expect(raw.contains("\"delivery-id\""))
    let body = try #require(httpBody(raw))
    let timestamp = try #require(headerValue(raw, name: "X-Timestamp"))
    let signature = try #require(headerValue(raw, name: "X-Signature"))
    #expect(WebhookSignature.verify(
        secret: secret,
        timestamp: try #require(Int64(timestamp)),
        body: Data(body.utf8),
        signature: signature,
        now: 1_700_000_000
    ))
    let dumped = try await store.readAll().map { $0.payload.canonicalJSON() }.joined(separator: "\n")
    #expect(!dumped.contains(secret))
    await engine.close()
}

private func webhookArguments(url: String) -> JSONValue {
    .object([
        "channel": .string("webhook"),
        "url": .string(url),
        "json": .object(["hello": .string("wire")]),
    ])
}

private func deliveryScript(arguments: JSONValue) -> Script {
    Script(steps: [
        .tool(name: DeliveryToolID.name, callID: "deliver", arguments: arguments),
        .finish("sent"),
    ])
}

private func jsonPart(_ part: Substring) throws -> JSONValue {
    let data = try #require(decodeBase64URL(String(part)))
    return try JSONValue.parse(String(decoding: data, as: UTF8.self))
}

private func decodeBase64URL(_ text: String) -> Data? {
    var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = padded.count % 4
    if remainder > 0 {
        padded += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: padded)
}

private func headerValue(_ raw: String, name: String) -> String? {
    let prefix = (name + ":").lowercased()
    for line in httpLines(raw) {
        if line.lowercased().hasPrefix(prefix) {
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

/// `\r\n` is one Swift character, so splitting on `"\n"` misses HTTP lines.
private func httpLines(_ text: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for scalar in text.unicodeScalars {
        if scalar == "\n" || scalar == "\r" {
            if !current.isEmpty {
                lines.append(current)
            }
            current = ""
        } else {
            current.unicodeScalars.append(scalar)
        }
    }
    if !current.isEmpty {
        lines.append(current)
    }
    return lines
}

private func httpBody(_ raw: String) -> String? {
    guard let range = raw.range(of: "\r\n\r\n") else { return nil }
    return String(raw[range.upperBound...])
}

private struct ScriptedStatus: Sendable {
    var status: Int
    var headers: [String: String]

    init(_ status: Int, _ headers: [String: String] = [:]) {
        self.status = status
        self.headers = headers
    }
}

private actor ScriptedHTTP: DeliveryHTTP {
    struct Call: Sendable {
        var url: String
        var headers: [String: String]
        var body: String
    }

    private(set) var calls: [Call] = []
    private var responses: [ScriptedStatus]
    private var crashArmed = false

    init(responses: [ScriptedStatus]) {
        self.responses = responses
    }

    func crashNext() {
        crashArmed = true
    }

    func send(url: String, method: String, headers: [String: String], body: Data) async throws -> DeliveryHTTPResponse {
        calls.append(Call(url: url, headers: headers, body: String(decoding: body, as: UTF8.self)))
        if crashArmed {
            crashArmed = false
            throw SimulatedProcessCrash()
        }
        let next = responses.isEmpty ? ScriptedStatus(200) : responses.removeFirst()
        return DeliveryHTTPResponse(status: next.status, headers: next.headers, body: Data())
    }
}

private actor MapSecrets: DeliverySecretStore {
    private let values: [String: String]

    init(_ values: [String: String]) {
        self.values = values
    }

    func secret(account: String) async throws -> String? {
        values[account]
    }
}

private actor CountingWebhook: WebhookTransport {
    private(set) var count = 0

    func post(url: String, body: JSONValue, headers: [String: String]) async {
        count += 1
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var requests: [String] = []
    private var thread: Thread?

    func start() throws -> Int {
        #if canImport(Glibc) || canImport(Musl)
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
        #if canImport(Glibc) || canImport(Musl)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else {
            throw LoopbackError("socket")
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                bind(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            closeSocket(fd)
            throw LoopbackError("bind")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                getsockname(fd, sock, &length)
            }
        }
        guard named == 0 else {
            closeSocket(fd)
            throw LoopbackError("getsockname")
        }
        let port = Int(UInt16(bigEndian: actual.sin_port))
        lock.lock()
        listenFD = fd
        running = true
        lock.unlock()
        let thread = Thread { [weak self] in
            self?.serve()
        }
        thread.start()
        self.thread = thread
        return port
    }

    func stop() {
        lock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            closeSocket(fd)
        }
    }

    func recorded() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private func serve() {
        while true {
            lock.lock()
            let keep = running
            let fd = listenFD
            lock.unlock()
            if !keep || fd < 0 { return }
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            if let text = readRequest(client) {
                lock.lock()
                requests.append(text)
                lock.unlock()
                let response = Array("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
                _ = response.withUnsafeBytes { raw in
                    send(client, raw.baseAddress, raw.count, sendFlags)
                }
            }
            closeSocket(client)
        }
    }

    private func readRequest(_ client: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let marker = Array("\r\n\r\n".utf8)
        while data.count < 1_000_000 {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(client, base, raw.count, 0)
            }
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if let end = indexAfterMarker(data, marker: marker) {
                let header = String(decoding: data[..<(data.startIndex + (end - marker.count))], as: UTF8.self)
                let length = contentLength(header)
                if length > 0, data.count >= end + length {
                    return String(decoding: data.prefix(end + length), as: UTF8.self)
                }
            }
        }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }

    private func indexAfterMarker(_ data: Data, marker: [UInt8]) -> Int? {
        guard data.count >= marker.count else { return nil }
        let bytes = Array(data)
        var index = 0
        while index + marker.count <= bytes.count {
            if Array(bytes[index..<(index + marker.count)]) == marker {
                return index + marker.count
            }
            index += 1
        }
        return nil
    }

    private func contentLength(_ header: String) -> Int {
        for line in httpLines(header) {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    private var sendFlags: Int32 {
        #if canImport(Glibc) || canImport(Musl)
        Int32(MSG_NOSIGNAL)
        #else
        0
        #endif
    }

    private func closeSocket(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #elseif canImport(Musl)
        _ = Musl.close(fd)
        #else
        _ = Darwin.close(fd)
        #endif
    }
}

private struct LoopbackError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
