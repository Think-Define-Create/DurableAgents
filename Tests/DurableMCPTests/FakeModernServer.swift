import DurableCore
import DurableMCP
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the fake server sends back for one POST.
enum FakeReply {
    case json(JSONValue, status: Int = 200)
    case sse([JSONValue])
    case empty(status: Int)
}

/// A scripted MCP server behind `URLProtocol`. Each instance owns one host name, so tests run in parallel.
final class FakeModernServer: @unchecked Sendable {
    struct Received {
        var headers: [String: String]
        var body: JSONValue

        var method: String { body["method"]?.stringValue ?? "" }
        var id: JSONValue { body["id"] ?? .null }
        var params: JSONValue { body["params"] ?? .object([:]) }

        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
    }

    let host = "fake-\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()
    private var log: [Received] = []
    private let handler: @Sendable (Received, Int) -> FakeReply

    /// `handler` gets the request and how many earlier requests used the same method.
    init(_ handler: @escaping @Sendable (Received, Int) -> FakeReply) {
        self.handler = handler
        FakeURLProtocol.register(self)
    }

    var endpoint: URL { URL(string: "https://\(host)/mcp")! }

    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeURLProtocol.self]
        return configuration
    }

    var received: [Received] {
        lock.withLock { log }
    }

    func count(_ method: String) -> Int {
        received.filter { $0.method == method }.count
    }

    func requests(_ method: String) -> [Received] {
        received.filter { $0.method == method }
    }

    func reply(to request: Received) -> FakeReply {
        let earlier = lock.withLock { () -> Int in
            let earlier = log.filter { $0.method == request.method }.count
            log.append(request)
            return earlier
        }
        return handler(request, earlier)
    }

    func stop() {
        FakeURLProtocol.unregister(host)
    }

    // MARK: Canned replies

    static func result(_ request: Received, _ fields: [String: JSONValue]) -> FakeReply {
        var fields = fields
        if fields["resultType"] == nil {
            fields["resultType"] = .string("complete")
        }
        return .json(.object(["id": request.id, "jsonrpc": .string("2.0"), "result": .object(fields)]))
    }

    static func error(_ request: Received, code: Int, message: String, data: JSONValue? = nil, status: Int = 200) -> FakeReply {
        var error: [String: JSONValue] = ["code": .int(Int64(code)), "message": .string(message)]
        if let data { error["data"] = data }
        return .json(.object(["error": .object(error), "id": request.id, "jsonrpc": .string("2.0")]), status: status)
    }

    static func discover(_ request: Received, tasks: Bool = true) -> FakeReply {
        var capabilities: [String: JSONValue] = [
            "prompts": .object([:]),
            "resources": .object([:]),
            "tools": .object(["listChanged": .bool(true)]),
        ]
        if tasks {
            capabilities["extensions"] = .object([MCPProtocol.tasksExtension: .object([:])])
        }
        return result(request, [
            "_meta": .object([MCPProtocol.serverInfoKey: .object(["name": .string("fake"), "version": .string("9.9")])]),
            "cacheScope": .string("public"),
            "capabilities": .object(capabilities),
            "instructions": .string("fake server"),
            "supportedVersions": .array([.string(MCPProtocol.modern)]),
            "ttlMs": .int(60_000),
        ])
    }

    static func text(_ text: String) -> JSONValue {
        .array([.object(["text": .string(text), "type": .string("text")])])
    }
}

final class FakeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var servers: [String: FakeModernServer] = [:]
    private static let lock = NSLock()

    static func register(_ server: FakeModernServer) {
        lock.withLock { servers[server.host] = server }
    }

    static func unregister(_ host: String) {
        _ = lock.withLock { servers.removeValue(forKey: host) }
    }

    private static func server(for request: URLRequest) -> FakeModernServer? {
        guard let host = request.url?.host else { return nil }
        return lock.withLock { servers[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        server(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let server = Self.server(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let body = Self.body(of: request)
        guard request.httpMethod == "POST", let parsed = try? JSONValue.parse(String(decoding: body, as: UTF8.self)) else {
            respond(url: url, status: 405, type: nil, data: Data())
            return
        }
        let received = FakeModernServer.Received(headers: request.allHTTPHeaderFields ?? [:], body: parsed)
        switch server.reply(to: received) {
        case .json(let value, let status):
            respond(url: url, status: status, type: "application/json", data: Data(value.canonicalJSON().utf8))
        case .sse(let messages):
            let text = messages.map { "data: \($0.canonicalJSON())\n\n" }.joined()
            respond(url: url, status: 200, type: "text/event-stream", data: Data((": keep-alive\n\n" + text).utf8))
        case .empty(let status):
            respond(url: url, status: status, type: nil, data: Data())
        }
    }

    override func stopLoading() {}

    private func respond(url: URL, status: Int, type: String?, data: Data) {
        var headers: [String: String] = [:]
        if let type { headers["Content-Type"] = type }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
