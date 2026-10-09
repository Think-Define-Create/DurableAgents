import DurableCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DeliveryHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let needle = name.lowercased()
        return headers.first { $0.key.lowercased() == needle }?.value
    }
}

public protocol DeliveryHTTP: Sendable {
    func send(url: String, method: String, headers: [String: String], body: Data) async throws -> DeliveryHTTPResponse
}

/// POST via `URLSession`. HTTP/1.1 is enough for webhooks. APNs needs the separate live sender.
public struct URLSessionDeliveryHTTP: DeliveryHTTP {
    public var session: URLSession
    public var timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.session = session
        self.timeout = timeout
    }

    public func send(url: String, method: String, headers: [String: String], body: Data) async throws -> DeliveryHTTPResponse {
        guard let endpoint = URL(string: url) else {
            throw DeliveryRetry(retryable: false, reason: "delivery url is invalid")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let session = self.session
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate(continuation)
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    gate.resume(throwing: error)
                    return
                }
                let http = response as? HTTPURLResponse
                var headerMap: [String: String] = [:]
                if let http {
                    for (key, value) in http.allHeaderFields {
                        if let name = key as? String, let text = value as? String {
                            headerMap[name] = text
                        }
                    }
                }
                gate.resume(returning: DeliveryHTTPResponse(
                    status: http?.statusCode ?? 0,
                    headers: headerMap,
                    body: data ?? Data()
                ))
            }
            task.resume()
        }
    }
}

public protocol DeliverySecretStore: Sendable {
    /// Resolves `account` to the secret value. Return nil when the account is unknown.
    /// Never log the returned string.
    func secret(account: String) async throws -> String?
}

/// Classifies an HTTP result. 2xx succeeds. 429 and 5xx retry. Any other status dead-letters.
/// A nil status is a network failure and retries. `Retry-After` is honored when it parses.
public enum DeliveryRules {
    public static func failure(status: Int?, headers: [String: String], now: Date) -> DeliveryRetry? {
        guard let status else {
            return DeliveryRetry(retryable: true, reason: "network error")
        }
        if (200..<300).contains(status) {
            return nil
        }
        let retryAfter = retryAfterSeconds(headers: headers, now: now)
        if status == 429 || status >= 500 {
            return DeliveryRetry(
                retryable: true,
                retryAfter: retryAfter,
                reason: "http \(status)",
                status: status
            )
        }
        return DeliveryRetry(retryable: false, reason: "http \(status)", status: status)
    }

    private static func retryAfterSeconds(headers: [String: String], now: Date) -> TimeInterval? {
        guard let raw = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<DeliveryHTTPResponse, Error>

    init(_ continuation: CheckedContinuation<DeliveryHTTPResponse, Error>) {
        self.continuation = continuation
    }

    func resume(returning response: DeliveryHTTPResponse) {
        lock.lock()
        let first = !resumed
        resumed = true
        lock.unlock()
        if first {
            continuation.resume(returning: response)
        }
    }

    func resume(throwing error: Error) {
        lock.lock()
        let first = !resumed
        resumed = true
        lock.unlock()
        if first {
            continuation.resume(throwing: error)
        }
    }
}
