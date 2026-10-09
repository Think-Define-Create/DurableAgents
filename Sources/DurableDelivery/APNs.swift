import Crypto
import DurableCore
import Foundation

/// Token-based APNs authentication (ES256 JWT) and the documented HTTP/2 request shape.
///
/// Apple's provider token header is `alg` `ES256` and `kid` (the 10-character key id).
/// The claims are `iss` (the 10-character team id) and `iat` (unix seconds). A token
/// older than one hour is rejected, so callers should refresh before that.
/// The `.p8` file is the ES256 private key in PKCS#8 PEM.
public enum APNsProviderToken {
    public static func make(teamID: String, keyID: String, issuedAt: Date, pem: String) throws -> String {
        try requireID(teamID, name: "team id")
        try requireID(keyID, name: "key id")
        let issued = Int64(issuedAt.timeIntervalSince1970)
        let header = Base64URL.encode(Data(#"{"alg":"ES256","kid":"\#(keyID)"}"#.utf8))
        let claims = Base64URL.encode(Data(#"{"iat":\#(issued),"iss":"\#(teamID)"}"#.utf8))
        let signingInput = header + "." + claims
        let signature: Data
        do {
            let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
            signature = try Data(key.signature(for: Data(signingInput.utf8)).rawRepresentation)
        } catch let retry as DeliveryRetry {
            throw retry
        } catch {
            throw DeliveryRetry(retryable: false, reason: "APNs auth key could not be parsed")
        }
        return signingInput + "." + Base64URL.encode(signature)
    }

    private static func requireID(_ value: String, name: String) throws {
        let allowed = value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard value.count == 10, allowed else {
            throw DeliveryRetry(retryable: false, reason: "APNs \(name) must be 10 letters or digits")
        }
    }
}

public enum APNsSupport {
    /// Live HTTP/2 to `api.push.apple.com` is compiled only where `URLSession` speaks HTTP/2.
    /// Linux Foundation uses HTTP/1.1, so the sender is gated off there.
    public static var liveSenderCompiled: Bool {
        #if canImport(Darwin)
        true
        #else
        false
        #endif
    }
}

/// Headers and URL Apple documents for a token-authenticated alert.
/// `apns-id` is a UUID derived from the effect key so a retry reuses the same id.
/// This builder does not send `Idempotency-Key`; that header is for webhooks.
public struct APNsRequest: Sendable, Equatable {
    public var url: String
    public var headers: [String: String]
    public var body: Data

    public init(url: String, headers: [String: String], body: Data) {
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public enum APNsRequestBuilder {
    public static func make(
        deviceToken: String,
        topic: String,
        payload: JSONValue,
        effectKey: String,
        providerToken: String,
        sandbox: Bool,
        pushType: String
    ) throws -> APNsRequest {
        let token = deviceToken.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        guard !token.isEmpty, !topic.isEmpty else {
            throw DeliveryRetry(retryable: false, reason: "APNs device token or topic is missing")
        }
        guard var object = payload.objectValue else {
            throw DeliveryRetry(retryable: false, reason: "APNs payload must be a JSON object")
        }
        object["delivery-id"] = .string(effectKey)
        let host = sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com"
        var headers = [
            "authorization": "bearer \(providerToken)",
            "apns-topic": topic,
            "apns-push-type": pushType,
            "apns-id": APNsIdentity.uuid(for: effectKey),
        ]
        if pushType == "alert" {
            headers["apns-priority"] = "10"
        } else if pushType == "background" {
            headers["apns-priority"] = "5"
        }
        return APNsRequest(
            url: "\(host)/3/device/\(token)",
            headers: headers,
            body: Data(JSONValue.object(object).canonicalJSON().utf8)
        )
    }
}

enum APNsKeyFingerprint {
    static func make(teamID: String, keyID: String, pem: String) -> String {
        let digest = SHA256.hash(data: Data((teamID + "\n" + keyID + "\n" + pem).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum APNsIdentity {
    static func uuid(for effectKey: String) -> String {
        let digest = Array(SHA256.hash(data: Data(effectKey.utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let index = { (offset: Int) in hex.index(hex.startIndex, offsetBy: offset) }
        return "\(hex[..<index(8)])-\(hex[index(8)..<index(12)])-\(hex[index(12)..<index(16)])-\(hex[index(16)..<index(20)])-\(hex[index(20)...])"
    }
}

/// HTTP/2 sender for APNs. On Linux this throws; the request and JWT builders still run.
public struct APNsLiveSender: DeliveryHTTP {
    public init() {}

    public func send(url: String, method: String, headers: [String: String], body: Data) async throws -> DeliveryHTTPResponse {
        #if canImport(Darwin)
        guard let endpoint = URL(string: url) else {
            throw DeliveryRetry(retryable: false, reason: "APNs url is invalid")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        var headerMap: [String: String] = [:]
        if let http {
            for (key, value) in http.allHeaderFields {
                if let name = key as? String, let text = value as? String {
                    headerMap[name] = text
                }
            }
        }
        return DeliveryHTTPResponse(status: http?.statusCode ?? 0, headers: headerMap, body: data)
        #else
        _ = (url, method, headers, body)
        throw DeliveryRetry(retryable: false, reason: "APNs HTTP/2 sender is unavailable on this platform")
        #endif
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: padded)
    }
}
