import Foundation

/// OpenAI Responses API (`POST /v1/responses`), streaming.
///
/// Request fields used: `model`, `input`, `instructions`, `stream`, `max_output_tokens`,
/// `tools` (`type` function, `name`, `description`, `parameters`).
/// Input items: role messages, `function_call` (`call_id`, `name`, `arguments`),
/// `function_call_output` (`call_id`, `output`). The bearer token is a header only.
///
/// SSE `type` values read: `response.output_text.delta` (`delta`);
/// `response.output_item.added` / `response.output_item.done` when `item.type` is
/// `function_call` (`id`, `call_id`, `name`, `arguments`);
/// `response.function_call_arguments.delta` (`item_id`, `output_index`, `delta`);
/// `response.function_call_arguments.done` (`item_id`, `output_index`, `name`, `arguments`);
/// `response.reasoning_summary_text.delta` and `response.reasoning_text.delta` (`delta`);
/// `response.completed` / `response.incomplete` / `response.failed`
/// (`response.status`, `response.usage.input_tokens`, `response.usage.output_tokens`,
/// `response.usage.input_tokens_details.cached_tokens`, `response.incomplete_details.reason`);
/// `error` (`message`).
public struct OpenAIResponses: ModelProvider {
    public var transport: any HTTPTransport
    public var secrets: any SecretStore
    public var apiKey: any SecretReference
    public var baseURL: URL

    public init(
        apiKey: any SecretReference,
        secrets: any SecretStore,
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = URL(string: "https://api.openai.com")!
    ) {
        self.apiKey = apiKey
        self.secrets = secrets
        self.transport = transport
        self.baseURL = baseURL
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let transport = self.transport
        let secrets = self.secrets
        let apiKey = self.apiKey
        let baseURL = self.baseURL
        return StreamLoop.open(transport: transport, request: {
            let key = try await secrets.secret(for: apiKey)
            guard !key.isEmpty else {
                throw ModelKitError.missingSecret(apiKey.account)
            }
            let body = try ResponsesEncoding.body(for: request)
            return HTTPRequest(
                url: try ProviderHTTP.url(base: baseURL, path: "/v1/responses"),
                method: "POST",
                headers: [
                    "Authorization": "Bearer \(key)",
                    "Content-Type": "application/json",
                ],
                body: try JSONWalk.encode(body)
            )
        }, accumulator: { ResponsesAccumulator() })
    }
}

enum ResponsesEncoding {
    static func body(for request: ModelRequest) throws -> [String: Any] {
        var body: [String: Any] = [
            "input": try inputItems(request.messages),
            "max_output_tokens": request.maxOutputTokens,
            "model": request.model,
            "stream": true,
        ]
        if !request.instructions.isEmpty {
            body["instructions"] = request.instructions
        }
        if !request.tools.isEmpty {
            var tools: [[String: Any]] = []
            for tool in request.tools {
                tools.append([
                    "description": tool.description,
                    "name": tool.name,
                    "parameters": try JSONWalk.object(text: tool.parametersJSON),
                    "type": "function",
                ])
            }
            body["tools"] = tools
        }
        return body
    }

    private static func inputItems(_ messages: [ModelMessage]) throws -> [[String: Any]] {
        var input: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .system, .user, .assistant:
                if !message.text.isEmpty || message.toolCalls.isEmpty {
                    input.append([
                        "content": message.text,
                        "role": message.role.rawValue,
                    ])
                }
                for call in message.toolCalls {
                    input.append([
                        "arguments": call.argumentsJSON,
                        "call_id": call.id,
                        "name": call.name,
                        "type": "function_call",
                    ])
                }
            case .tool:
                input.append([
                    "call_id": message.toolCallID ?? "",
                    "output": message.text,
                    "type": "function_call_output",
                ])
            }
        }
        return input
    }
}

private struct ResponsesAccumulator: SSEReducing {
    private struct PendingCall {
        var itemID: String
        var callID: String
        var name: String
        var arguments: String
        var emitted: Bool

        var publicID: String {
            callID.isEmpty ? itemID : callID
        }
    }

    private var calls: [Int: PendingCall] = [:]
    private var sawTool = false

    mutating func consume(event: String?, data: String) throws -> [ModelStreamEvent] {
        let json = try JSONWalk.object(text: data)
        let type = JSONWalk.string(json["type"]) ?? event ?? ""
        switch type {
        case "response.output_text.delta":
            let delta = JSONWalk.string(json["delta"]) ?? ""
            return delta.isEmpty ? [] : [.textDelta(delta)]
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            let delta = JSONWalk.string(json["delta"]) ?? ""
            return delta.isEmpty ? [] : [.thinkingDelta(delta)]
        case "response.output_item.added":
            return rememberItem(json, finalize: false)
        case "response.output_item.done":
            return rememberItem(json, finalize: true)
        case "response.function_call_arguments.delta":
            return argumentsDelta(json)
        case "response.function_call_arguments.done":
            return argumentsDone(json)
        case "response.completed", "response.incomplete", "response.failed":
            return completion(json)
        case "error":
            throw ModelKitError.malformed(JSONWalk.string(json["message"]) ?? data)
        default:
            return []
        }
    }

    mutating func finish() throws -> [ModelStreamEvent] {
        []
    }

    private mutating func rememberItem(_ json: [String: Any], finalize: Bool) -> [ModelStreamEvent] {
        guard let item = JSONWalk.dictionary(json["item"]),
              JSONWalk.string(item["type"]) == "function_call"
        else {
            return []
        }
        let index = JSONWalk.int(json["output_index"]) ?? 0
        var pending = calls[index] ?? PendingCall(itemID: "", callID: "", name: "", arguments: "", emitted: false)
        if let itemID = JSONWalk.string(item["id"]) {
            pending.itemID = itemID
        }
        if let callID = JSONWalk.string(item["call_id"]) {
            pending.callID = callID
        }
        if let name = JSONWalk.string(item["name"]) {
            pending.name = name
        }
        if let arguments = JSONWalk.string(item["arguments"]), !arguments.isEmpty {
            pending.arguments = arguments
        }
        if finalize, !pending.emitted, !pending.name.isEmpty {
            pending.emitted = true
            calls[index] = pending
            sawTool = true
            return [.toolCall(ProviderToolCall(id: pending.publicID, name: pending.name, argumentsJSON: pending.arguments))]
        }
        calls[index] = pending
        return []
    }

    private mutating func argumentsDelta(_ json: [String: Any]) -> [ModelStreamEvent] {
        let index = JSONWalk.int(json["output_index"]) ?? 0
        var pending = calls[index] ?? PendingCall(itemID: "", callID: "", name: "", arguments: "", emitted: false)
        if let itemID = JSONWalk.string(json["item_id"]) {
            pending.itemID = itemID
        }
        let delta = JSONWalk.string(json["delta"]) ?? ""
        pending.arguments += delta
        calls[index] = pending
        guard !delta.isEmpty else { return [] }
        return [.toolCallDelta(id: pending.publicID, name: pending.name, argumentsDelta: delta)]
    }

    private mutating func argumentsDone(_ json: [String: Any]) -> [ModelStreamEvent] {
        let index = JSONWalk.int(json["output_index"]) ?? 0
        var pending = calls[index] ?? PendingCall(itemID: "", callID: "", name: "", arguments: "", emitted: false)
        if let itemID = JSONWalk.string(json["item_id"]) {
            pending.itemID = itemID
        }
        if let name = JSONWalk.string(json["name"]) {
            pending.name = name
        }
        if let arguments = JSONWalk.string(json["arguments"]) {
            pending.arguments = arguments
        }
        guard !pending.emitted else {
            calls[index] = pending
            return []
        }
        pending.emitted = true
        calls[index] = pending
        sawTool = true
        return [.toolCall(ProviderToolCall(id: pending.publicID, name: pending.name, argumentsJSON: pending.arguments))]
    }

    private func completion(_ json: [String: Any]) -> [ModelStreamEvent] {
        guard let response = JSONWalk.dictionary(json["response"]) else {
            return []
        }
        var events: [ModelStreamEvent] = []
        if let usage = JSONWalk.dictionary(response["usage"]) {
            let cached = JSONWalk.dictionary(usage["input_tokens_details"]).flatMap { JSONWalk.int($0["cached_tokens"]) }
            events.append(.usage(ModelUsage(
                inputTokens: JSONWalk.int(usage["input_tokens"]),
                outputTokens: JSONWalk.int(usage["output_tokens"]),
                cacheReadTokens: cached
            )))
        }
        let status = JSONWalk.string(response["status"]) ?? ""
        let reason: String
        if sawTool {
            reason = "tool_use"
        } else if status == "incomplete" {
            let detail = JSONWalk.dictionary(response["incomplete_details"]).flatMap { JSONWalk.string($0["reason"]) } ?? "incomplete"
            reason = detail == "max_output_tokens" ? "max_tokens" : detail
        } else if status == "completed" {
            reason = "completed"
        } else if status.isEmpty {
            reason = "unknown"
        } else {
            reason = status
        }
        events.append(.stop(StopReason(raw: reason)))
        return events
    }
}
