import Crypto
import Foundation

/// HMAC-SHA256 request signing for a generic webhook.
///
/// `X-Timestamp` is unix seconds. `X-Signature` is `v1=` plus the hex of
/// HMAC-SHA256(secret, `"<timestamp>.<raw body>"`). Verifiers should reject a
/// timestamp outside their tolerance so a captured request cannot be replayed.
public enum WebhookSignature {
    public static let timestampHeader = "X-Timestamp"
    public static let signatureHeader = "X-Signature"
    public static let defaultTolerance: Int64 = 300

    public static func sign(secret: String, timestamp: Int64, body: Data) -> String {
        let code = Data(HMAC<SHA256>.authenticationCode(for: message(timestamp: timestamp, body: body), using: key(secret)))
        return "v1=" + hex(code)
    }

    public static func verify(
        secret: String,
        timestamp: Int64,
        body: Data,
        signature: String,
        now: Int64,
        tolerance: Int64 = defaultTolerance
    ) -> Bool {
        guard timestamp <= now + tolerance, now - timestamp <= tolerance else { return false }
        guard signature.hasPrefix("v1="), let provided = decodeHex(String(signature.dropFirst(3))) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            provided,
            authenticating: message(timestamp: timestamp, body: body),
            using: key(secret)
        )
    }

    private static func key(_ secret: String) -> SymmetricKey {
        SymmetricKey(data: Data(secret.utf8))
    }

    private static func message(timestamp: Int64, body: Data) -> Data {
        var data = Data("\(timestamp).".utf8)
        data.append(body)
        return data
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeHex(_ text: String) -> Data? {
        guard text.count.isMultiple(of: 2), !text.isEmpty else { return nil }
        var data = Data()
        data.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
