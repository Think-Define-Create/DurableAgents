import DurableCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One request's reply: the HTTP status (200 on stdio) and the JSON-RPC messages that arrived for it.
/// The stream ends after the final response. Dropping the stream cancels the request.
struct MCPReply: Sendable {
    var status: Int
    var messages: AsyncThrowingStream<JSONValue, Error>
}

/// Carries modern JSON-RPC requests. `headers` are the request metadata headers for HTTP; stdio ignores them.
protocol MCPChannel: Sendable {
    func send(_ message: JSONValue, headers: [String: String], timeout: Double) async throws -> MCPReply
    func close() async
}

/// Streamable HTTP, 2026-07-28 shape: one POST per request, JSON or an SSE stream back, no session id.
final class MCPHTTPChannel: NSObject, MCPChannel, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        var head: CheckedContinuation<Int, Error>?
        var continuation: AsyncThrowingStream<JSONValue, Error>.Continuation
        var sse: Bool = false
        var parser = MCPSSEParser()
        var body = Data()
    }

    private let endpoint: URL
    private let fixedHeaders: [String: String]
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var session: URLSession?
    private var pending: [Int: Pending] = [:]

    init(endpoint: URL, headers: [String: String], configuration: URLSessionConfiguration?) {
        self.endpoint = endpoint
        self.fixedHeaders = headers
        self.configuration = configuration ?? .ephemeral
        super.init()
    }

    private func urlSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let session {
            return session
        }
        let made = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        session = made
        return made
    }

    func send(_ message: JSONValue, headers: [String: String], timeout: Double) async throws -> MCPReply {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = max(timeout, 1)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in fixedHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = MCPWire.data(message)
        let task = urlSession().dataTask(with: request)
        let identifier = task.taskIdentifier
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                task.cancel()
            }
            self?.drop(identifier)
        }
        let status: Int = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { head in
                register(identifier, Pending(head: head, continuation: continuation))
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return MCPReply(status: status, messages: stream)
    }

    private func register(_ identifier: Int, _ item: Pending) {
        lock.withLock { pending[identifier] = item }
    }

    private func takeAll() -> (URLSession?, [Int: Pending]) {
        lock.withLock {
            let taken = (session, pending)
            session = nil
            pending = [:]
            return taken
        }
    }

    func close() async {
        let (session, open) = takeAll()
        for (_, item) in open {
            item.head?.resume(throwing: MCPCallError("mcp connection closed"))
            item.continuation.finish(throwing: MCPCallError("mcp connection closed"))
        }
        session?.invalidateAndCancel()
    }

    private func drop(_ identifier: Int) {
        lock.lock()
        let item = pending.removeValue(forKey: identifier)
        lock.unlock()
        item?.head?.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        lock.lock()
        var head: CheckedContinuation<Int, Error>?
        if var item = pending[dataTask.taskIdentifier] {
            item.sse = type.contains("text/event-stream")
            head = item.head
            item.head = nil
            pending[dataTask.taskIdentifier] = item
        }
        lock.unlock()
        head?.resume(returning: status)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var item = pending[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        var events: [String] = []
        if item.sse {
            events = item.parser.feed(data)
        } else {
            item.body.append(data)
        }
        pending[dataTask.taskIdentifier] = item
        lock.unlock()
        for event in events {
            if let value = try? JSONValue.parse(event) {
                item.continuation.yield(value)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard var item = pending.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        lock.unlock()
        if let head = item.head {
            head.resume(throwing: error.map(Self.safe) ?? MCPCallError("mcp request failed"))
            item.continuation.finish(throwing: MCPCallError("mcp request failed"))
            return
        }
        if item.sse {
            if let event = item.parser.finish(), let value = try? JSONValue.parse(event) {
                item.continuation.yield(value)
            }
        } else if !item.body.isEmpty, let value = try? MCPWire.parse(item.body) {
            item.continuation.yield(value)
        }
        if let error {
            item.continuation.finish(throwing: Self.safe(error))
        } else {
            item.continuation.finish()
        }
    }

    /// Never passes a URL or a body through to the caller.
    private static func safe(_ error: Error) -> Error {
        if let error = error as? URLError {
            switch error.code {
            case .cancelled:
                return CancellationError()
            case .timedOut:
                return MCPCallError("mcp call timed out")
            default:
                return MCPCallError("mcp connection failed")
            }
        }
        return MCPCallError("mcp connection failed")
    }
}

#if os(macOS) || os(Linux)
/// stdio, 2026-07-28 shape: newline-delimited JSON-RPC on one process. Responses are matched by id and
/// subscription notifications by `io.modelcontextprotocol/subscriptionId`.
final class MCPStdioChannel: MCPChannel, @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var routes: [String: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]
    private var buffer = Data()
    private var closed = false

    init(command: String, arguments: [String], environment extra: [String: String]) throws {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for (name, value) in extra {
            environment[name] = value
        }
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.output = stdout.fileHandleForReading
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        output.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.finishAll(MCPCallError("mcp process exited"))
                return
            }
            self.receive(chunk)
        }
        do {
            try process.run()
        } catch {
            throw MCPCallError("mcp process failed to start")
        }
    }

    func send(_ message: JSONValue, headers: [String: String], timeout: Double) async throws -> MCPReply {
        guard let id = message["id"] else {
            try write(message)
            let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
            continuation.finish()
            return MCPReply(status: 202, messages: stream)
        }
        let key = id.canonicalJSON()
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        continuation.onTermination = { [weak self] termination in
            guard let self else { return }
            self.lock.lock()
            let wasOpen = self.routes.removeValue(forKey: key) != nil
            self.lock.unlock()
            if case .cancelled = termination, wasOpen {
                try? self.write(MCPWire.notification(method: "notifications/cancelled", params: ["requestId": id]))
            }
        }
        guard addRoute(key, continuation) else {
            throw MCPCallError("mcp connection closed")
        }
        try write(message)
        return MCPReply(status: 200, messages: stream)
    }

    private func addRoute(_ key: String, _ continuation: AsyncThrowingStream<JSONValue, Error>.Continuation) -> Bool {
        lock.withLock {
            if closed {
                return false
            }
            routes[key] = continuation
            return true
        }
    }

    private func markClosed() {
        lock.withLock { closed = true }
    }

    func close() async {
        markClosed()
        output.readabilityHandler = nil
        finishAll(MCPCallError("mcp connection closed"))
        try? input.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func write(_ message: JSONValue) throws {
        var data = MCPWire.data(message)
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
        } catch {
            throw MCPCallError("mcp connection closed")
        }
    }

    private func receive(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            guard let message = try? MCPWire.parse(line) else { continue }
            route(message)
        }
    }

    private func route(_ message: JSONValue) {
        let key: String
        let final: Bool
        if let id = message["id"], message["method"] == nil {
            key = id.canonicalJSON()
            final = true
        } else if let subscription = message["params"]?["_meta"]?[MCPProtocol.subscriptionIDKey] {
            key = subscription.canonicalJSON()
            final = false
        } else {
            return
        }
        lock.lock()
        let continuation = final ? routes.removeValue(forKey: key) : routes[key]
        lock.unlock()
        continuation?.yield(message)
        if final {
            continuation?.finish()
        }
    }

    private func finishAll(_ error: Error) {
        lock.lock()
        let open = routes
        routes = [:]
        lock.unlock()
        for (_, continuation) in open {
            continuation.finish(throwing: error)
        }
    }
}
#endif
