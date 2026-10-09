import Foundation

/// Anthropic Messages API (`POST /v1/messages`), streaming.
///
/// Request fields used: `model`, `max_tokens`, `stream`, `system`, `messages`, `tools`
/// (`name`, `description`, `input_schema`). Headers: `x-api-key`, `anthropic-version`.
/// The key is never written into the JSON body.
///
/// SSE fields read: `message_start.message.usage` (`input_tokens`, `output_tokens`,
/// `cache_read_input_tokens`, `cache_creation_input_tokens`); `content_block_start.content_block`
/// (`type` text | thinking | tool_use, `id`, `name`); `content_block_delta.delta`
/// (`text_delta.text`, `thinking_delta.thinking`, `input_json_delta.partial_json`).
/// `signature_delta` is ignored. `message_delta.delta.stop_reason` and `message_delta.usage`.
public struct AnthropicMessages: ModelProvider {
    public var transport: any HTTPTransport
    public var secrets: any SecretStore
    public var apiKey: any SecretReference
    public var baseURL: URL
    public var anthropicVersion: String

    public init(
        apiKey: any SecretReference,
        secrets: any SecretStore,
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        anthropicVersion: String = "2023-06-01"
    ) {
        self.apiKey = apiKey
        self.secrets = secrets
        self.transport = transport
        self.baseURL = baseURL
        self.anthropicVersion = anthropicVersion
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let transport = self.transport
        let secrets = self.secrets
        let apiKey = self.apiKey
        let baseURL = self.baseURL
        let anthropicVersion = self.anthropicVersion
        return StreamLoop.open(transport: transport, request: {
            let key = try await secrets.secret(for: apiKey)
            guard !key.isEmpty else {
                throw PiAIError.missingSecret(apiKey.account)
            }
            let body = try AnthropicEncoding.body(for: request)
            return HTTPRequest(
                url: try ProviderHTTP.url(base: baseURL, path: "/v1/messages"),
                method: "POST",
                headers: [
                    "Content-Type": "application/json",
                    "x-api-key": key,
                    "anthropic-version": anthropicVersion,
                ],
                body: try JSONWalk.encode(body)
            )
        }, accumulator: { AnthropicAccumulator() })
    }
}

enum AnthropicEncoding {
    static func body(for request: ModelRequest) throws -> [String: Any] {
        var body: [String: Any] = [
            "max_tokens": request.maxOutputTokens,
            "model": request.model,
            "stream": true,
        ]
        var systemParts: [String] = []
        if !request.instructions.isEmpty {
            systemParts.append(request.instructions)
        }
        var messages: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []

        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            messages.append(["content": pendingToolResults, "role": "user"])
            pendingToolResults = []
        }

        for message in request.messages {
            switch message.role {
            case .system:
                if !message.text.isEmpty {
                    systemParts.append(message.text)
                }
            case .user:
                flushToolResults()
                messages.append(["content": message.text, "role": "user"])
            case .assistant:
                flushToolResults()
                messages.append(try assistantMessage(message))
            case .tool:
                pendingToolResults.append([
                    "content": message.text,
                    "tool_use_id": message.toolCallID ?? "",
                    "type": "tool_result",
                ])
            }
        }
        flushToolResults()
        if !systemParts.isEmpty {
            body["system"] = systemParts.joined(separator: "\n")
        }
        body["messages"] = messages
        if !request.tools.isEmpty {
            var tools: [[String: Any]] = []
            for tool in request.tools {
                tools.append([
                    "description": tool.description,
                    "input_schema": try JSONWalk.object(text: tool.parametersJSON),
                    "name": tool.name,
                ])
            }
            body["tools"] = tools
        }
        return body
    }

    private static func assistantMessage(_ message: ModelMessage) throws -> [String: Any] {
        guard !message.toolCalls.isEmpty else {
            return ["content": message.text, "role": "assistant"]
        }
        var content: [[String: Any]] = []
        if !message.text.isEmpty {
            content.append(["text": message.text, "type": "text"])
        }
        for call in message.toolCalls {
            let raw = call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON
            content.append([
                "id": call.id,
                "input": try JSONWalk.object(text: raw),
                "name": call.name,
                "type": "tool_use",
            ])
        }
        return ["content": content, "role": "assistant"]
    }
}

private struct AnthropicAccumulator: SSEReducing {
    private struct Block {
        enum Kind {
            case text
            case thinking
            case tool
            case other
        }

        var kind: Kind
        var id: String
        var name: String
        var partial: String
        var emitted: Bool
    }

    private var blocks: [Int: Block] = [:]

    mutating func consume(event: String?, data: String) throws -> [ModelStreamEvent] {
        let json = try JSONWalk.object(text: data)
        let type = JSONWalk.string(json["type"]) ?? event ?? ""
        switch type {
        case "message_start":
            guard let message = JSONWalk.dictionary(json["message"]),
                  let usage = JSONWalk.dictionary(message["usage"])
            else {
                return []
            }
            return [Self.usage(usage)]
        case "content_block_start":
            let index = JSONWalk.int(json["index"]) ?? blocks.count
            let block = JSONWalk.dictionary(json["content_block"]) ?? [:]
            let blockType = JSONWalk.string(block["type"]) ?? ""
            switch blockType {
            case "text":
                blocks[index] = Block(kind: .text, id: "", name: "", partial: "", emitted: false)
            case "thinking":
                blocks[index] = Block(kind: .thinking, id: "", name: "", partial: "", emitted: false)
            case "tool_use":
                blocks[index] = Block(
                    kind: .tool,
                    id: JSONWalk.string(block["id"]) ?? "",
                    name: JSONWalk.string(block["name"]) ?? "",
                    partial: "",
                    emitted: false
                )
            default:
                blocks[index] = Block(kind: .other, id: "", name: "", partial: "", emitted: false)
            }
            return []
        case "content_block_delta":
            return try delta(json)
        case "content_block_stop":
            return stopBlock(JSONWalk.int(json["index"]) ?? 0)
        case "message_delta":
            var events: [ModelStreamEvent] = []
            if let usage = JSONWalk.dictionary(json["usage"]) {
                events.append(Self.usage(usage))
            }
            if let delta = JSONWalk.dictionary(json["delta"]),
               let reason = JSONWalk.string(delta["stop_reason"]) {
                events.append(.stop(StopReason(raw: reason)))
            }
            return events
        case "error":
            throw PiAIError.malformed(Self.errorMessage(json) ?? data)
        default:
            return []
        }
    }

    mutating func finish() throws -> [ModelStreamEvent] {
        var events: [ModelStreamEvent] = []
        for index in blocks.keys.sorted() {
            events.append(contentsOf: stopBlock(index))
        }
        return events
    }

    private mutating func delta(_ json: [String: Any]) throws -> [ModelStreamEvent] {
        let index = JSONWalk.int(json["index"]) ?? 0
        guard let delta = JSONWalk.dictionary(json["delta"]) else {
            return []
        }
        switch JSONWalk.string(delta["type"]) ?? "" {
        case "text_delta":
            let text = JSONWalk.string(delta["text"]) ?? ""
            return text.isEmpty ? [] : [.textDelta(text)]
        case "thinking_delta":
            let text = JSONWalk.string(delta["thinking"]) ?? ""
            return text.isEmpty ? [] : [.thinkingDelta(text)]
        case "input_json_delta":
            let partial = JSONWalk.string(delta["partial_json"]) ?? ""
            if var block = blocks[index] {
                block.partial += partial
                blocks[index] = block
            }
            let block = blocks[index]
            return [.toolCallDelta(id: block?.id ?? "", name: block?.name ?? "", argumentsDelta: partial)]
        case "signature_delta":
            return []
        default:
            return []
        }
    }

    private mutating func stopBlock(_ index: Int) -> [ModelStreamEvent] {
        guard var block = blocks[index], block.kind == .tool, !block.emitted else {
            return []
        }
        block.emitted = true
        blocks[index] = block
        let arguments = block.partial.isEmpty ? "{}" : block.partial
        return [.toolCall(ProviderToolCall(id: block.id, name: block.name, argumentsJSON: arguments))]
    }

    private static func usage(_ usage: [String: Any]) -> ModelStreamEvent {
        .usage(ModelUsage(
            inputTokens: JSONWalk.int(usage["input_tokens"]),
            outputTokens: JSONWalk.int(usage["output_tokens"]),
            cacheReadTokens: JSONWalk.int(usage["cache_read_input_tokens"]),
            cacheWriteTokens: JSONWalk.int(usage["cache_creation_input_tokens"])
        ))
    }

    private static func errorMessage(_ json: [String: Any]) -> String? {
        if let error = JSONWalk.dictionary(json["error"]) {
            return JSONWalk.string(error["message"])
        }
        return JSONWalk.string(json["message"])
    }
}
