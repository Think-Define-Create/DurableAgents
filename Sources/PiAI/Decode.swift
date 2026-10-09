import Foundation

enum JSONWalk {
    static func object(data: Data) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let fields = parsed as? [String: Any] else {
            throw PiAIError.malformed("expected a JSON object")
        }
        return fields
    }

    static func object(text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8) else {
            throw PiAIError.malformed("arguments are not UTF-8")
        }
        return try object(data: data)
    }

    static func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func int(_ value: Any?) -> Int? {
        if value is NSNull || value == nil {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }
}

enum ProviderHTTP {
    static func url(base: URL, path: String) throws -> URL {
        var root = base.absoluteString
        if root.hasSuffix("/") {
            root.removeLast()
        }
        guard let url = URL(string: root + path) else {
            throw PiAIError.malformed("bad base URL \(base.absoluteString)")
        }
        return url
    }
}

protocol SSEReducing: Sendable {
    mutating func consume(event: String?, data: String) throws -> [ModelStreamEvent]
    mutating func finish() throws -> [ModelStreamEvent]
}

enum StreamLoop {
    static func open<Accumulator: SSEReducing>(
        transport: any HTTPTransport,
        request: @escaping @Sendable () async throws -> HTTPRequest,
        accumulator: @escaping @Sendable () -> Accumulator
    ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let box = ContinuationBox(continuation)
            let task = Task {
                var parser = SSEParser()
                var reducing = accumulator()
                do {
                    let http = try await request()
                    for try await chunk in transport.bytes(http) {
                        try Task.checkCancellation()
                        for sse in parser.append(chunk) {
                            for event in try reducing.consume(event: sse.event, data: sse.data) {
                                box.yield(event)
                            }
                        }
                    }
                    for sse in parser.flush() {
                        for event in try reducing.consume(event: sse.event, data: sse.data) {
                            box.yield(event)
                        }
                    }
                    for event in try reducing.finish() {
                        box.yield(event)
                    }
                    box.finish()
                } catch {
                    box.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private final class ContinuationBox: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation

    init(_ continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ event: ModelStreamEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }

    func finish(throwing error: Error) {
        continuation.finish(throwing: error)
    }
}
