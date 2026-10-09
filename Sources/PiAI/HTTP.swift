import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, method: String, headers: [String: String], body: Data) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func bytes(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error>
}

public struct FixtureTransport: HTTPTransport {
    public var payload: Data
    public var status: Int

    public init(payload: Data, status: Int = 200) {
        self.payload = payload
        self.status = status
    }

    public init(text: String, status: Int = 200) {
        self.payload = Data(text.utf8)
        self.status = status
    }

    public func bytes(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        let payload = payload
        let status = status
        return AsyncThrowingStream { continuation in
            if status >= 400 {
                continuation.finish(throwing: PiAIError.http(status: status, body: String(decoding: payload, as: UTF8.self)))
                return
            }
            continuation.yield(payload)
            continuation.finish()
        }
    }
}

/// Records the request a provider built, then forwards the body stream.
public final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [HTTPRequest] = []
    private let inner: any HTTPTransport

    public init(inner: any HTTPTransport) {
        self.inner = inner
    }

    public var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func bytes(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        stored.append(request)
        lock.unlock()
        return inner.bytes(request)
    }
}

public struct URLSessionTransport: HTTPTransport {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func bytes(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        // Linux FoundationNetworking has no `URLSession.bytes(for:)`. A data-task
        // delegate yields each body chunk as it arrives on Apple and on Linux.
        let configuration = session.configuration
        return AsyncThrowingStream { continuation in
            let box = DataContinuationBox(continuation)
            let delegate = URLSessionByteDelegate(box: box)
            let streaming = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = request.method
            for (field, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: field)
            }
            urlRequest.httpBody = request.body
            let task = streaming.dataTask(with: urlRequest)
            continuation.onTermination = { _ in
                task.cancel()
                streaming.invalidateAndCancel()
            }
            task.resume()
        }
    }
}

private final class DataContinuationBox: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ data: Data) {
        continuation.yield(data)
    }

    func finish() {
        continuation.finish()
    }

    func finish(throwing error: Error) {
        continuation.finish(throwing: error)
    }
}

private final class URLSessionByteDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let box: DataContinuationBox
    private let lock = NSLock()
    private var status = 0
    private var errorBody = Data()

    init(box: DataContinuationBox) {
        self.box = box
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if status >= 400 {
            lock.lock()
            if errorBody.count < 4_096 {
                errorBody.append(data.prefix(4_096 - errorBody.count))
            }
            lock.unlock()
            return
        }
        box.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                box.finish()
            } else {
                box.finish(throwing: error)
            }
        } else if status >= 400 {
            let body = String(decoding: errorBody, as: UTF8.self)
            box.finish(throwing: PiAIError.http(status: status, body: body))
        } else {
            box.finish()
        }
        session.finishTasksAndInvalidate()
    }
}

enum JSONBodies {
    static func object(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func parseObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let fields = object as? [String: Any] else {
            throw PiAIError.malformed("expected a JSON object")
        }
        return fields
    }

    static func embed(_ json: String) throws -> Any {
        let data = Data(json.utf8)
        return try JSONSerialization.jsonObject(with: data)
    }
}

struct SSEParser {
    private var buffer = ""

    mutating func append(_ data: Data) -> [(event: String?, data: String)] {
        buffer += String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var events: [(event: String?, data: String)] = []
        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let event = Self.parse(block) {
                events.append(event)
            }
        }
        return events
    }

    mutating func flush() -> [(event: String?, data: String)] {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard !rest.isEmpty, let event = Self.parse(rest) else {
            return []
        }
        return [event]
    }

    private static func parse(_ block: String) -> (event: String?, data: String)? {
        var eventName: String?
        var dataLines: [String] = []
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("event:") {
                eventName = text.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            } else if text.hasPrefix("data:") {
                dataLines.append(text.dropFirst("data:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        let data = dataLines.joined(separator: "\n")
        if data.isEmpty || data == "[DONE]" {
            return nil
        }
        return (eventName, data)
    }
}
