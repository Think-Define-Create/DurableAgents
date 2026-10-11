import DurableCore
import Foundation

/// A 2026-07-28 client: no handshake, `_meta` on every request, `server/discover`, MRTR,
/// `ttlMs` caching, `subscriptions/listen`, and the tasks extension.
actor MCPModernConnection {
    private struct CacheEntry {
        var value: JSONValue
        var expires: Date
    }

    struct HeaderParam {
        var path: [String]
        var header: String
    }

    private let channel: any MCPChannel
    private let server: String
    private let inputHandler: (any MCPInputHandler)?
    private let timeout: Double
    private var version: String
    private var nextID = 1
    private var cache: [String: CacheEntry] = [:]
    private var headerParams: [String: [HeaderParam]] = [:]
    private(set) var description: MCPServerDescription?

    init(channel: any MCPChannel, server: String, inputHandler: (any MCPInputHandler)?, timeout: Double) {
        self.channel = channel
        self.server = server
        self.inputHandler = inputHandler
        self.timeout = timeout
        self.version = MCPProtocol.modern
    }

    var protocolVersion: String { version }

    func close() async {
        await channel.close()
    }

    // MARK: Discovery

    /// Probes the server. Throws `MCPLegacyServer` when it is not a modern server.
    @discardableResult
    func discover(probeTimeout: Double? = nil) async throws -> MCPServerDescription {
        let result: JSONValue
        do {
            result = try await call("server/discover", [:], timeout: probeTimeout)
        } catch let error as MCPRPCError where !error.isModern {
            throw MCPLegacyServer()
        } catch let error as MCPRPCError {
            throw MCPCallError("mcp server rejected discovery (\(error.code))")
        }
        let supported = (result["supportedVersions"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard let chosen = MCPProtocol.modernVersions.first(where: supported.contains) else {
            throw MCPLegacyServer()
        }
        version = chosen
        let info = result["_meta"]?[MCPProtocol.serverInfoKey]
        let described = MCPServerDescription(
            era: .modern,
            protocolVersion: chosen,
            supportedVersions: supported,
            capabilities: result["capabilities"] ?? .object([:]),
            instructions: result["instructions"]?.stringValue,
            serverName: info?["name"]?.stringValue,
            serverVersion: info?["version"]?.stringValue
        )
        description = described
        return described
    }

    // MARK: Tools

    func listTools() async throws -> [MCPListedTool] {
        var listed: [MCPListedTool] = []
        var cursor: String?
        var params: [String: [HeaderParam]] = [:]
        repeat {
            try Task.checkCancellation()
            var request: [String: JSONValue] = [:]
            if let cursor { request["cursor"] = .string(cursor) }
            let page = try await cached("tools/list", request)
            for tool in page["tools"]?.arrayValue ?? [] {
                guard let name = tool["name"]?.stringValue else { continue }
                let schema = tool["inputSchema"] ?? .object([:])
                // A tool with an invalid x-mcp-header annotation is excluded, as the spec requires.
                guard let headers = Self.headerParams(schema) else { continue }
                params[name] = headers
                let annotations = tool["annotations"]
                listed.append(MCPListedTool(
                    name: name,
                    summary: tool["description"]?.stringValue ?? "",
                    inputSchemaJSON: schema.canonicalJSON(),
                    hints: MCPToolHints(
                        readOnlyHint: annotations?["readOnlyHint"]?.boolValue,
                        destructiveHint: annotations?["destructiveHint"]?.boolValue,
                        idempotentHint: annotations?["idempotentHint"]?.boolValue,
                        openWorldHint: annotations?["openWorldHint"]?.boolValue
                    )
                ))
            }
            cursor = page["nextCursor"]?.stringValue
        } while cursor != nil
        headerParams = params
        return listed
    }

    /// Calls a tool. Answers input requests, follows a task to its end, and journals the task id first.
    func callTool(name: String, arguments: JSONValue, context: MCPCallContext) async throws -> (output: MCPToolOutput, taskID: String?) {
        if let journal = context.taskJournal, let key = context.effectKey,
           let record = try await journal.entry(effectKey: key) {
            let output = try await finishTask(record.taskID, context: context)
            return (output, record.taskID)
        }
        var params: [String: JSONValue] = ["name": .string(name)]
        if arguments != .null {
            guard arguments.objectValue != nil else {
                throw MCPCallError("mcp arguments must be an object")
            }
            params["arguments"] = arguments
        }
        var meta: [String: JSONValue] = [:]
        if let key = context.idempotencyKey {
            meta[MCPProtocol.idempotencyKeyMeta] = .string(key)
        }
        let headers = paramHeaders(tool: name, arguments: arguments)
        let result = try await withInput("tools/call", params, name: name, meta: meta, headers: headers)
        if MCPWire.resultType(result) == "task" {
            guard let taskID = result["taskId"]?.stringValue else {
                throw MCPCallError("mcp task result has no task id")
            }
            if let journal = context.taskJournal, let key = context.effectKey {
                try await journal.record(MCPTaskRecord(effectKey: key, server: context.server, tool: name, taskID: taskID))
            }
            let output = try await finishTask(taskID, context: context)
            return (output, taskID)
        }
        return (MCPContent.output(result), nil)
    }

    // MARK: Resources and prompts

    func listResources() async throws -> [MCPResource] {
        try await paged("resources/list", key: "resources").compactMap(MCPResource.init)
    }

    func listResourceTemplates() async throws -> [MCPResourceTemplate] {
        try await paged("resources/templates/list", key: "resourceTemplates").compactMap(MCPResourceTemplate.init)
    }

    func readResource(uri: String) async throws -> [MCPResourceContent] {
        let cacheKey = Self.cacheKey("resources/read", ["uri": .string(uri)])
        if let entry = cache[cacheKey], entry.expires > Date() {
            return (entry.value["contents"]?.arrayValue ?? []).compactMap(MCPResourceContent.init)
        }
        let result = try await withInput("resources/read", ["uri": .string(uri)], name: uri, meta: [:], headers: [:], cacheKey: cacheKey)
        return (result["contents"]?.arrayValue ?? []).compactMap(MCPResourceContent.init)
    }

    func listPrompts() async throws -> [MCPPrompt] {
        try await paged("prompts/list", key: "prompts").compactMap(MCPPrompt.init)
    }

    func getPrompt(name: String, arguments: [String: String]) async throws -> MCPPromptMessages {
        var params: [String: JSONValue] = ["name": .string(name)]
        if !arguments.isEmpty {
            params["arguments"] = .object(arguments.mapValues { .string($0) })
        }
        let result = try await withInput("prompts/get", params, name: name, meta: [:], headers: [:])
        return MCPPromptMessages(result)
    }

    // MARK: Subscriptions

    /// Opens `subscriptions/listen`. Change notifications also invalidate cached lists.
    func listen(_ filter: MCPSubscriptionFilter) async throws -> AsyncThrowingStream<MCPServerEvent, Error> {
        let id = freshID()
        let message = MCPWire.request(
            id: id,
            method: "subscriptions/listen",
            params: ["_meta": meta([:]), "notifications": filter.json]
        )
        let reply = try await channel.send(message, headers: headers(method: "subscriptions/listen", name: nil), timeout: 86_400)
        if reply.status >= 400 {
            for try await item in reply.messages {
                if let error = MCPRPCError(item["error"], httpStatus: reply.status) {
                    throw MCPCallError("mcp subscription refused (\(error.code))")
                }
            }
            throw MCPCallError("mcp subscription refused")
        }
        let (events, continuation) = AsyncThrowingStream<MCPServerEvent, Error>.makeStream()
        let pump = Task { [weak self] in
            do {
                for try await item in reply.messages {
                    if item["id"] == id, item["method"] == nil {
                        continuation.yield(.closed)
                        break
                    }
                    guard let method = item["method"]?.stringValue else { continue }
                    let params = item["params"] ?? .object([:])
                    guard let event = Self.event(method: method, params: params) else { continue }
                    await self?.invalidate(for: event)
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            pump.cancel()
        }
        return events
    }

    // MARK: Tasks

    func getTask(_ taskID: String) async throws -> MCPTaskStatus {
        let result = try await call("tasks/get", ["taskId": .string(taskID)])
        guard let status = MCPTaskStatus(result) else {
            throw MCPCallError("mcp task status is malformed")
        }
        return status
    }

    func updateTask(_ taskID: String, responses: [String: JSONValue]) async throws {
        _ = try await call("tasks/update", ["inputResponses": .object(responses), "taskId": .string(taskID)])
    }

    func cancelTask(_ taskID: String) async throws {
        _ = try await call("tasks/cancel", ["taskId": .string(taskID)])
    }

    /// Polls until the task ends. Input requests go to the handler and back through `tasks/update`.
    func finishTask(_ taskID: String, context: MCPCallContext) async throws -> MCPToolOutput {
        let deadline = Date().addingTimeInterval(max(context.taskTimeoutSeconds, 0.01))
        while true {
            try Task.checkCancellation()
            let status = try await getTask(taskID)
            switch status.state {
            case .completed:
                if let journal = context.taskJournal, let key = context.effectKey {
                    try? await journal.remove(effectKey: key)
                }
                return MCPContent.output(status.result ?? .object([:]))
            case .failed:
                if let journal = context.taskJournal, let key = context.effectKey {
                    try? await journal.remove(effectKey: key)
                }
                return MCPToolOutput(texts: ["mcp task failed"], isError: true)
            case .cancelled:
                if let journal = context.taskJournal, let key = context.effectKey {
                    try? await journal.remove(effectKey: key)
                }
                return MCPToolOutput(texts: ["mcp task was cancelled"], isError: true)
            case .inputRequired:
                let message = status.inputRequests.values.compactMap { $0["params"]?["message"]?.stringValue }.first
                guard inputHandler != nil, !status.inputRequests.isEmpty else {
                    throw MCPTaskNeedsInput(taskID: taskID, message: message ?? status.statusMessage ?? "input required")
                }
                let responses = try await answers(status.inputRequests)
                try await updateTask(taskID, responses: responses)
            case .working:
                break
            }
            if Date() >= deadline {
                throw MCPCallError("mcp task is still running")
            }
            let interval = Double(min(max(status.pollIntervalMs ?? 1000, 10), 30_000)) / 1000
            try await Task.sleep(for: .seconds(interval))
        }
    }

    // MARK: Requests

    /// Runs a request that may return `input_required`, retrying with `inputResponses` and `requestState`.
    private func withInput(
        _ method: String,
        _ params: [String: JSONValue],
        name: String?,
        meta: [String: JSONValue],
        headers: [String: String],
        cacheKey: String? = nil
    ) async throws -> JSONValue {
        var params = params
        var retried = false
        for _ in 0..<8 {
            var request = params
            request["_meta"] = .object(meta)
            let result = try await call(method, request, name: name, extraHeaders: headers)
            if MCPWire.resultType(result) != "input_required" {
                // A retry carried inputs that are not part of the cache key, so its result is not cached.
                if let cacheKey, !retried {
                    store(result, key: cacheKey)
                }
                return result
            }
            retried = true
            let requests = result["inputRequests"]?.objectValue ?? [:]
            params["inputResponses"] = requests.isEmpty ? nil : .object(try await answers(requests))
            params["requestState"] = result["requestState"]
        }
        throw MCPCallError("mcp server kept asking for input")
    }

    private func answers(_ requests: [String: JSONValue]) async throws -> [String: JSONValue] {
        var responses: [String: JSONValue] = [:]
        for key in requests.keys.sorted() {
            guard let request = requests[key] else { continue }
            let method = request["method"]?.stringValue ?? ""
            guard method == "elicitation/create" else {
                throw MCPCallError("mcp server asked for \(method), which this client does not offer")
            }
            let input = MCPInputRequest(key: key, method: method, params: request["params"] ?? .object([:]), server: server)
            let answer = try await inputHandler?.answer(input) ?? .cancel
            responses[key] = answer.json
        }
        return responses
    }

    private func paged(_ method: String, key: String) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            var request: [String: JSONValue] = [:]
            if let cursor { request["cursor"] = .string(cursor) }
            let page = try await cached(method, request)
            items.append(contentsOf: page[key]?.arrayValue ?? [])
            cursor = page["nextCursor"]?.stringValue
        } while cursor != nil
        return items
    }

    /// Serves a fresh cached result, or calls and caches by `ttlMs`.
    private func cached(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let key = Self.cacheKey(method, params)
        if let entry = cache[key], entry.expires > Date() {
            return entry.value
        }
        let result = try await call(method, params)
        store(result, key: key)
        return result
    }

    private func store(_ result: JSONValue, key: String) {
        guard MCPWire.resultType(result) == "complete",
              let ttl = MCPWire.number(result["ttlMs"]), ttl > 0
        else {
            cache.removeValue(forKey: key)
            return
        }
        cache[key] = CacheEntry(value: result, expires: Date().addingTimeInterval(ttl / 1000))
    }

    func invalidate(for event: MCPServerEvent) {
        switch event {
        case .toolsListChanged:
            cache = cache.filter { !$0.key.hasPrefix("tools/list ") }
        case .promptsListChanged:
            cache = cache.filter { !$0.key.hasPrefix("prompts/list ") }
        case .resourcesListChanged:
            cache = cache.filter { !$0.key.hasPrefix("resources/list ") && !$0.key.hasPrefix("resources/templates/list ") }
        case .resourceUpdated(let uri):
            cache.removeValue(forKey: Self.cacheKey("resources/read", ["uri": .string(uri)]))
        default:
            break
        }
    }

    /// Sends one request and returns its `result`. Retries once with a version from `UnsupportedProtocolVersionError`.
    private func call(
        _ method: String,
        _ params: [String: JSONValue],
        name: String? = nil,
        extraHeaders: [String: String] = [:],
        timeout: Double? = nil
    ) async throws -> JSONValue {
        var tried: Set<String> = [version]
        while true {
            try Task.checkCancellation()
            let id = freshID()
            var request = params
            request["_meta"] = meta(params["_meta"]?.objectValue ?? [:])
            let message = MCPWire.request(id: id, method: method, params: request)
            var headers = headers(method: method, name: name)
            headers.merge(extraHeaders) { current, _ in current }
            let reply: MCPReply
            do {
                reply = try await channel.send(message, headers: headers, timeout: timeout ?? self.timeout)
            } catch let error as MCPCallError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MCPCallError("mcp connection failed")
            }
            var response: JSONValue?
            if let timeout {
                response = try await MCPTimeout.run(seconds: timeout) {
                    try await Self.response(id: id, in: reply.messages)
                }
            } else {
                response = try await Self.response(id: id, in: reply.messages)
            }
            guard let response else {
                if reply.status >= 400 {
                    throw MCPRPCError(code: 0, message: "http \(reply.status)", httpStatus: reply.status)
                }
                throw MCPCallError("mcp response was empty")
            }
            if let error = MCPRPCError(response["error"], httpStatus: reply.status) {
                if error.code == MCPProtocol.unsupportedProtocolVersion {
                    let offered = (error.data?["supported"]?.arrayValue ?? []).compactMap(\.stringValue)
                    if let next = MCPProtocol.modernVersions.first(where: { offered.contains($0) && !tried.contains($0) }) {
                        tried.insert(next)
                        version = next
                        continue
                    }
                }
                throw error
            }
            guard let result = response["result"] else {
                throw MCPCallError("mcp response has no result")
            }
            return result
        }
    }

    private static func response(id: JSONValue, in messages: AsyncThrowingStream<JSONValue, Error>) async throws -> JSONValue? {
        for try await message in messages {
            // Request-scoped notifications (progress, log) arrive first on the same stream and are skipped.
            if message["method"] == nil, message["id"] == id || message["id"] == .null || message["id"] == nil {
                return message
            }
        }
        return nil
    }

    private func meta(_ extra: [String: JSONValue]) -> JSONValue {
        var fields = extra
        fields[MCPProtocol.protocolVersionKey] = .string(version)
        fields[MCPProtocol.clientInfoKey] = .object(["name": .string("DurableAgents"), "version": .string("1.0.0")])
        fields[MCPProtocol.clientCapabilitiesKey] = capabilities
        return .object(fields)
    }

    private var capabilities: JSONValue {
        var fields: [String: JSONValue] = [
            "extensions": .object([MCPProtocol.tasksExtension: .object([:])]),
        ]
        if inputHandler != nil {
            fields["elicitation"] = .object(["form": .object([:]), "url": .object([:])])
        }
        return .object(fields)
    }

    private func headers(method: String, name: String?) -> [String: String] {
        var headers = [
            "MCP-Protocol-Version": version,
            "Mcp-Method": method,
        ]
        if let name {
            headers["Mcp-Name"] = MCPWire.headerValue(name)
        }
        return headers
    }

    private func freshID() -> JSONValue {
        defer { nextID += 1 }
        return .int(Int64(nextID))
    }

    private func paramHeaders(tool: String, arguments: JSONValue) -> [String: String] {
        var headers: [String: String] = [:]
        for param in headerParams[tool] ?? [] {
            var value: JSONValue? = arguments
            for step in param.path {
                value = value?[step]
            }
            let text: String
            switch value {
            case .string(let item):
                text = item
            case .int(let item):
                text = String(item)
            case .bool(let item):
                text = item ? "true" : "false"
            default:
                continue
            }
            headers["Mcp-Param-\(param.header)"] = MCPWire.headerValue(text)
        }
        return headers
    }

    private static func cacheKey(_ method: String, _ params: [String: JSONValue]) -> String {
        method + " " + JSONValue.object(params).canonicalJSON()
    }

    private static func event(method: String, params: JSONValue) -> MCPServerEvent? {
        switch method {
        case "notifications/subscriptions/acknowledged":
            return .acknowledged(MCPSubscriptionFilter(params["notifications"] ?? .object([:])))
        case "notifications/tools/list_changed":
            return .toolsListChanged
        case "notifications/prompts/list_changed":
            return .promptsListChanged
        case "notifications/resources/list_changed":
            return .resourcesListChanged
        case "notifications/resources/updated":
            return params["uri"]?.stringValue.map { .resourceUpdated(uri: $0) }
        case "notifications/tasks":
            return MCPTaskStatus(params).map { .task($0) }
        default:
            return nil
        }
    }

    /// The `x-mcp-header` parameters of a schema, or `nil` when an annotation breaks a spec rule.
    static func headerParams(_ schema: JSONValue) -> [HeaderParam]? {
        var found: [HeaderParam] = []
        var seen: Set<String> = []
        func walk(_ node: JSONValue, path: [String]?) -> Bool {
            if let array = node.arrayValue {
                return array.allSatisfy { walk($0, path: nil) }
            }
            guard let fields = node.objectValue else { return true }
            if let header = fields["x-mcp-header"] {
                guard let path, !path.isEmpty, let name = header.stringValue, Self.isToken(name) else { return false }
                let type = fields["type"]?.stringValue
                guard type == "string" || type == "integer" || type == "boolean" else { return false }
                guard seen.insert(name.lowercased()).inserted else { return false }
                found.append(HeaderParam(path: path, header: name))
            }
            for (key, value) in fields where key != "x-mcp-header" {
                if key == "properties", let properties = value.objectValue {
                    for (property, child) in properties {
                        if !walk(child, path: path.map { $0 + [property] }) {
                            return false
                        }
                    }
                } else if !walk(value, path: nil) {
                    return false
                }
            }
            return true
        }
        guard walk(schema, path: []) else { return nil }
        return found
    }

    private static func isToken(_ name: String) -> Bool {
        let extra: Set<Character> = ["!", "#", "$", "%", "&", "'", "*", "+", "-", ".", "^", "_", "`", "|", "~"]
        return !name.isEmpty && name.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || extra.contains(character))
        }
    }
}
