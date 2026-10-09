import Foundation

/// Which documented token-limit field a chat-completions server expects.
public enum ChatTokenLimitField: String, Sendable {
    /// Groq, xAI, OpenRouter, Ollama, and older OpenAI chat models.
    case maxTokens = "max_tokens"
    /// Newer OpenAI chat models.
    case maxCompletionTokens = "max_completion_tokens"
}

/// Known OpenAI-compatible chat roots. The request path is `/chat/completions`.
public enum CompatibleChatEndpoint {
    public static let openAI = URL(string: "https://api.openai.com/v1")!
    public static let xAI = URL(string: "https://api.x.ai/v1")!
    public static let groq = URL(string: "https://api.groq.com/openai/v1")!
    public static let openRouter = URL(string: "https://openrouter.ai/api/v1")!
    public static let ollama = URL(string: "http://127.0.0.1:11434/v1")!
}

/// OpenAI-compatible `POST {base}/chat/completions` streaming.
///
/// Request fields used: `model`, `messages`, `stream`, `stream_options.include_usage`,
/// one of `max_tokens` or `max_completion_tokens`, and `tools` (`type` function,
/// `function.name`, `function.description`, `function.parameters`).
/// Assistant `tool_calls` use `id`, `type` function, `function.name`, `function.arguments`.
/// Tool results use `role` tool, `tool_call_id`, `content`.
/// An empty secret omits `Authorization` so a local server such as Ollama can answer.
///
/// Chunk fields read: `choices[].delta.content`; `choices[].delta.tool_calls[]`
/// (`index`, `id`, `function.name`, `function.arguments`); `choices[].finish_reason`
/// (`stop`, `length`, `tool_calls`, `content_filter`, `function_call`);
/// `usage.prompt_tokens` and `usage.completion_tokens` (the usage chunk may have `choices: []`).
public struct OpenAICompatibleChat: ModelProvider {
    public var transport: any HTTPTransport
    public var secrets: any SecretStore
    public var apiKey: any SecretReference
    public var baseURL: URL
    public var tokenLimitField: ChatTokenLimitField

    public init(
        apiKey: any SecretReference,
        secrets: any SecretStore,
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = CompatibleChatEndpoint.openAI,
        tokenLimitField: ChatTokenLimitField = .maxTokens
    ) {
        self.apiKey = apiKey
        self.secrets = secrets
        self.transport = transport
        self.baseURL = baseURL
        self.tokenLimitField = tokenLimitField
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let transport = self.transport
        let secrets = self.secrets
        let apiKey = self.apiKey
        let baseURL = self.baseURL
        let tokenLimitField = self.tokenLimitField
        return StreamLoop.open(transport: transport, request: {
            let key = try await secrets.secret(for: apiKey)
            let body = try ChatEncoding.body(for: request, tokenLimitField: tokenLimitField)
            var headers = ["Content-Type": "application/json"]
            if !key.isEmpty {
                headers["Authorization"] = "Bearer \(key)"
            }
            return HTTPRequest(
                url: try ProviderHTTP.url(base: baseURL, path: "/chat/completions"),
                method: "POST",
                headers: headers,
                body: try JSONWalk.encode(body)
            )
        }, accumulator: { ChatAccumulator() })
    }
}

enum ChatEncoding {
    static func body(for request: ModelRequest, tokenLimitField: ChatTokenLimitField) throws -> [String: Any] {
        var messages: [[String: Any]] = []
        if !request.instructions.isEmpty {
            messages.append(["content": request.instructions, "role": "system"])
        }
        for message in request.messages {
            switch message.role {
            case .system, .user:
                messages.append(["content": message.text, "role": message.role.rawValue])
            case .assistant:
                var item: [String: Any] = ["content": message.text, "role": "assistant"]
                if !message.toolCalls.isEmpty {
                    item["tool_calls"] = message.toolCalls.map { call in
                        [
                            "function": [
                                "arguments": call.argumentsJSON,
                                "name": call.name,
                            ],
                            "id": call.id,
                            "type": "function",
                        ] as [String: Any]
                    }
                }
                messages.append(item)
            case .tool:
                messages.append([
                    "content": message.text,
                    "role": "tool",
                    "tool_call_id": message.toolCallID ?? "",
                ])
            }
        }
        var body: [String: Any] = [
            "messages": messages,
            "model": request.model,
            "stream": true,
            "stream_options": ["include_usage": true],
            tokenLimitField.rawValue: request.maxOutputTokens,
        ]
        if !request.tools.isEmpty {
            var tools: [[String: Any]] = []
            for tool in request.tools {
                tools.append([
                    "function": [
                        "description": tool.description,
                        "name": tool.name,
                        "parameters": try JSONWalk.object(text: tool.parametersJSON),
                    ],
                    "type": "function",
                ])
            }
            body["tools"] = tools
        }
        return body
    }
}

private struct ChatAccumulator: SSEReducing {
    private struct PendingCall {
        var id: String
        var name: String
        var arguments: String
        var emitted: Bool
    }

    private var calls: [Int: PendingCall] = [:]

    mutating func consume(event: String?, data: String) throws -> [ModelStreamEvent] {
        let json = try JSONWalk.object(text: data)
        var events: [ModelStreamEvent] = []
        if let usage = JSONWalk.dictionary(json["usage"]) {
            events.append(.usage(ModelUsage(
                inputTokens: JSONWalk.int(usage["prompt_tokens"]),
                outputTokens: JSONWalk.int(usage["completion_tokens"])
            )))
        }
        for choice in JSONWalk.array(json["choices"]) ?? [] {
            guard let choice = JSONWalk.dictionary(choice) else { continue }
            if let delta = JSONWalk.dictionary(choice["delta"]) {
                if let content = JSONWalk.string(delta["content"]), !content.isEmpty {
                    events.append(.textDelta(content))
                }
                for call in JSONWalk.array(delta["tool_calls"]) ?? [] {
                    guard let call = JSONWalk.dictionary(call) else { continue }
                    let index = JSONWalk.int(call["index"]) ?? 0
                    var pending = calls[index] ?? PendingCall(id: "", name: "", arguments: "", emitted: false)
                    if let id = JSONWalk.string(call["id"]) {
                        pending.id = id
                    }
                    if let function = JSONWalk.dictionary(call["function"]) {
                        if let name = JSONWalk.string(function["name"]) {
                            pending.name = name
                        }
                        if let arguments = JSONWalk.string(function["arguments"]), !arguments.isEmpty {
                            pending.arguments += arguments
                            events.append(.toolCallDelta(id: pending.id, name: pending.name, argumentsDelta: arguments))
                        }
                    }
                    calls[index] = pending
                }
            }
            if let reason = JSONWalk.string(choice["finish_reason"]) {
                events.append(contentsOf: emitPending())
                events.append(.stop(StopReason(raw: reason)))
            }
        }
        return events
    }

    mutating func finish() throws -> [ModelStreamEvent] {
        emitPending()
    }

    private mutating func emitPending() -> [ModelStreamEvent] {
        var events: [ModelStreamEvent] = []
        for index in calls.keys.sorted() {
            guard var pending = calls[index], !pending.emitted, !pending.name.isEmpty else { continue }
            pending.emitted = true
            calls[index] = pending
            events.append(.toolCall(ProviderToolCall(id: pending.id, name: pending.name, argumentsJSON: pending.arguments)))
        }
        return events
    }
}
