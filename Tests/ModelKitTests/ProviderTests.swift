import Foundation
import Testing

@testable import ModelKit

private struct StaticSecretStore: SecretStore {
    var value: String

    func secret(for reference: any SecretReference) async throws -> String {
        if value.isEmpty {
            throw ModelKitError.missingSecret(reference.account)
        }
        return value
    }
}

private struct SplitTransport: HTTPTransport {
    var payload: Data
    var piece: Int

    func bytes(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        let payload = payload
        let piece = piece
        return AsyncThrowingStream { continuation in
            var index = payload.startIndex
            while index < payload.endIndex {
                let next = payload.index(index, offsetBy: piece, limitedBy: payload.endIndex) ?? payload.endIndex
                continuation.yield(payload[index..<next])
                index = next
            }
            continuation.finish()
        }
    }
}

private let secret = "sk-test-secret-DO-NOT-LOG"

private let sampleRequest = ModelRequest(
    model: "test-model",
    instructions: "Be brief.",
    messages: [
        ModelMessage(role: .user, text: "Look up escrow"),
        ModelMessage(
            role: .assistant,
            text: "Checking.",
            toolCalls: [ProviderToolCall(id: "call_1", name: "lookup", argumentsJSON: #"{"q":"harbor"}"#)]
        ),
        ModelMessage(role: .tool, text: "found", toolCallID: "call_1", toolName: "lookup"),
    ],
    tools: [
        ModelToolDefinition(
            name: "lookup",
            description: "Find a file",
            parametersJSON: #"{"type":"object","properties":{"q":{"type":"string"}}}"#
        ),
    ]
)

@Test func scriptedProviderCheckpointsTheTurn() async throws {
    let provider = ScriptedProvider(events: [
        .textDelta("Hel"),
        .textDelta("lo"),
        .thinkingDelta("note"),
        .toolCallDelta(id: "c1", name: "lookup", argumentsDelta: "{\"q\":"),
        .toolCall(ProviderToolCall(id: "c1", name: "lookup", argumentsJSON: #"{"q":"x"}"#)),
        .usage(ModelUsage(inputTokens: 2, outputTokens: 4)),
        .stop(StopReason(raw: "tool_use")),
    ])
    let turn = try await provider.complete(sampleRequest)
    #expect(turn.text == "Hello")
    #expect(turn.thinking == "note")
    #expect(turn.toolCalls == [ProviderToolCall(id: "c1", name: "lookup", argumentsJSON: #"{"q":"x"}"#)])
    #expect(turn.usage == ModelUsage(inputTokens: 2, outputTokens: 4))
    #expect(turn.stop == StopReason(raw: "tool_use"))
    #expect(turn.stop?.kind == .toolUse)
}

@Test func stopReasonMapsVendorStrings() {
    #expect(StopReason(raw: "end_turn").kind == .endTurn)
    #expect(StopReason(raw: "stop").kind == .endTurn)
    #expect(StopReason(raw: "completed").kind == .endTurn)
    #expect(StopReason(raw: "tool_calls").kind == .toolUse)
    #expect(StopReason(raw: "function_call").kind == .toolUse)
    #expect(StopReason(raw: "length").kind == .maxTokens)
    #expect(StopReason(raw: "max_tokens").kind == .maxTokens)
    #expect(StopReason(raw: "content_filter").kind == .refusal)
    #expect(StopReason(raw: "refusal").kind == .refusal)
    #expect(StopReason(raw: "pause_turn").kind == .unknown)
    #expect(StopReason(raw: "pause_turn").raw == "pause_turn")
}

@Test func environmentSecretStoreReadsTheProcessEnvironment() async throws {
    let store = EnvironmentSecretStore()
    let path = try await store.secret(for: NamedSecret(account: "PATH"))
    #expect(!path.isEmpty)
    do {
        _ = try await store.secret(for: NamedSecret(account: "NO_SUCH_PIAI_SECRET"))
        Issue.record("expected a missing secret")
    } catch let error as ModelKitError {
        #expect(error == .missingSecret("NO_SUCH_PIAI_SECRET"))
    }
}

@Test func keychainStoreIsAppleOnly() {
    #if canImport(Security)
    #expect(SecretStoreSupport.keychainCompiled)
    #else
    #expect(!SecretStoreSupport.keychainCompiled)
    #endif
}

@Test func anthropicFixtureParsesTextThinkingAndToolUse() async throws {
    let transport = RecordingTransport(inner: FixtureTransport(text: anthropicFixture))
    let provider = AnthropicMessages(
        apiKey: NamedSecret(account: "ANTHROPIC_API_KEY"),
        secrets: StaticSecretStore(value: secret),
        transport: transport
    )
    let events = try await collect(provider)
    #expect(events.contains(.textDelta("Hello")))
    #expect(events.contains(.textDelta(" there")))
    #expect(events.contains(.thinkingDelta("Check the file.")))
    #expect(events.contains(.toolCallDelta(id: "toolu_1", name: "lookup", argumentsDelta: #"{"q":"#)))
    #expect(events.contains(.toolCall(ProviderToolCall(
        id: "toolu_1",
        name: "lookup",
        argumentsJSON: #"{"q":"escrow"}"#
    ))))
    #expect(events.contains(.usage(ModelUsage(
        inputTokens: 12,
        outputTokens: 1,
        cacheReadTokens: 3,
        cacheWriteTokens: 1
    ))))
    #expect(events.contains(.usage(ModelUsage(outputTokens: 20))))
    #expect(events.contains(.stop(StopReason(raw: "tool_use"))))

    let turn = try await provider.complete(sampleRequest)
    #expect(turn.text == "Hello there")
    #expect(turn.thinking == "Check the file.")
    #expect(turn.toolCalls.count == 1)
    #expect(turn.usage.inputTokens == 12)
    #expect(turn.usage.outputTokens == 20)
    #expect(turn.usage.cacheReadTokens == 3)
    #expect(turn.usage.cacheWriteTokens == 1)
    #expect(turn.stop?.kind == .toolUse)

    let http = try #require(transport.requests.first)
    try assertSecretStaysInHeader(http, header: "x-api-key")
    let body = try JSONWalk.object(data: http.body)
    #expect(body["model"] as? String == "test-model")
    #expect(body["stream"] as? Bool == true)
    #expect(body["max_tokens"] as? Int == 1024)
    #expect(body["system"] as? String == "Be brief.")
    #expect(http.headers["anthropic-version"] == "2023-06-01")
    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.count == 3)
    #expect(messages[0]["role"] as? String == "user")
    let assistant = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(assistant.contains { ($0["type"] as? String) == "tool_use" && ($0["id"] as? String) == "call_1" })
    let toolResult = try #require(messages[2]["content"] as? [[String: Any]])
    #expect(toolResult.first?["type"] as? String == "tool_result")
    #expect(toolResult.first?["tool_use_id"] as? String == "call_1")
    let tools = try #require(body["tools"] as? [[String: Any]])
    let schema = try #require(tools.first?["input_schema"] as? [String: Any])
    #expect(schema["type"] as? String == "object")
    #expect(tools.first?["name"] as? String == "lookup")
}

@Test func anthropicStreamSurvivesSplitChunks() async throws {
    let payload = Data(anthropicFixture.utf8)
    let provider = AnthropicMessages(
        apiKey: NamedSecret(account: "ANTHROPIC_API_KEY"),
        secrets: StaticSecretStore(value: secret),
        transport: SplitTransport(payload: payload, piece: 9)
    )
    let turn = try await provider.complete(sampleRequest)
    #expect(turn.text == "Hello there")
    #expect(turn.toolCalls.first?.argumentsJSON == #"{"q":"escrow"}"#)
}

@Test func responsesFixtureUsesCallIDAndDoesNotDuplicateTheTool() async throws {
    let transport = RecordingTransport(inner: FixtureTransport(text: responsesFixture))
    let provider = OpenAIResponses(
        apiKey: NamedSecret(account: "OPENAI_API_KEY"),
        secrets: StaticSecretStore(value: secret),
        transport: transport
    )
    let events = try await collect(provider)
    let toolCalls = events.compactMap { event -> ProviderToolCall? in
        if case .toolCall(let call) = event { return call }
        return nil
    }
    #expect(toolCalls == [ProviderToolCall(id: "call_1", name: "lookup", argumentsJSON: #"{"q":"escrow"}"#)])
    #expect(events.contains(.thinkingDelta("Thinking")))
    #expect(events.contains(.textDelta("Done")))
    #expect(events.contains(.usage(ModelUsage(inputTokens: 8, outputTokens: 4, cacheReadTokens: 2))))
    #expect(events.contains(.stop(StopReason(raw: "tool_use"))))

    let http = try #require(transport.requests.first)
    try assertSecretStaysInHeader(http, header: "Authorization", headerValue: "Bearer \(secret)")
    let body = try JSONWalk.object(data: http.body)
    #expect(body["max_output_tokens"] as? Int == 1024)
    #expect(body["max_tokens"] == nil)
    #expect(body["instructions"] as? String == "Be brief.")
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.contains { ($0["type"] as? String) == "function_call" && ($0["call_id"] as? String) == "call_1" })
    #expect(input.contains { ($0["type"] as? String) == "function_call_output" && ($0["output"] as? String) == "found" })
    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect(tools.first?["type"] as? String == "function")
    #expect(tools.first?["name"] as? String == "lookup")
}

@Test func chatCompletionsAccumulateToolCallsAndOmitAnEmptyAuthorization() async throws {
    let transport = RecordingTransport(inner: FixtureTransport(text: chatFixture))
    let provider = OpenAICompatibleChat(
        apiKey: NamedSecret(account: "OPENAI_API_KEY"),
        secrets: EmptySecretStore(),
        transport: transport,
        baseURL: CompatibleChatEndpoint.ollama
    )
    let turn = try await provider.complete(sampleRequest)
    #expect(turn.text == "Hi")
    #expect(turn.toolCalls == [ProviderToolCall(id: "call_abc", name: "lookup", argumentsJSON: #"{"q":"x"}"#)])
    #expect(turn.usage == ModelUsage(inputTokens: 5, outputTokens: 3))
    #expect(turn.stop == StopReason(raw: "tool_calls"))

    let http = try #require(transport.requests.first)
    let bodyText = String(decoding: http.body, as: UTF8.self)
    #expect(!bodyText.contains(secret))
    #expect(http.headers["Authorization"] == nil)
    #expect(http.url.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
    let body = try JSONWalk.object(data: http.body)
    #expect(body["stream"] as? Bool == true)
    let options = try #require(body["stream_options"] as? [String: Any])
    #expect(options["include_usage"] as? Bool == true)
    #expect(body["max_tokens"] as? Int == 1024)
    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.first?["role"] as? String == "system")
    #expect(messages.contains { ($0["role"] as? String) == "tool" && ($0["tool_call_id"] as? String) == "call_1" })
    let tools = try #require(body["tools"] as? [[String: Any]])
    let function = try #require(tools.first?["function"] as? [String: Any])
    #expect(function["name"] as? String == "lookup")
}

@Test func chatCompletionWithAKeyPutsItOnlyInTheHeader() async throws {
    let transport = RecordingTransport(inner: FixtureTransport(text: chatFixture))
    let provider = OpenAICompatibleChat(
        apiKey: NamedSecret(account: "GROQ_API_KEY"),
        secrets: StaticSecretStore(value: secret),
        transport: transport,
        baseURL: CompatibleChatEndpoint.groq,
        tokenLimitField: .maxCompletionTokens
    )
    _ = try await provider.complete(ModelRequest(model: "llama", messages: [ModelMessage(role: .user, text: "hi")]))
    let http = try #require(transport.requests.first)
    try assertSecretStaysInHeader(http, header: "Authorization", headerValue: "Bearer \(secret)")
    let body = try JSONWalk.object(data: http.body)
    #expect(body["max_completion_tokens"] as? Int == 1024)
    #expect(body["max_tokens"] == nil)
    #expect(http.url.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
}

@Test func httpErrorDoesNotParseABodyAsEvents() async throws {
    let provider = AnthropicMessages(
        apiKey: NamedSecret(account: "ANTHROPIC_API_KEY"),
        secrets: StaticSecretStore(value: secret),
        transport: FixtureTransport(text: "nope", status: 401)
    )
    do {
        _ = try await provider.complete(sampleRequest)
        Issue.record("expected an HTTP error")
    } catch let error as ModelKitError {
        #expect(error == .http(status: 401, body: "nope"))
    }
}

private func collect(_ provider: any ModelProvider) async throws -> [ModelStreamEvent] {
    var events: [ModelStreamEvent] = []
    for try await event in provider.stream(sampleRequest) {
        events.append(event)
    }
    return events
}

private func assertSecretStaysInHeader(_ request: HTTPRequest, header: String, headerValue: String? = nil) throws {
    let body = String(decoding: request.body, as: UTF8.self)
    #expect(!body.contains(secret))
    #expect(request.headers[header] == (headerValue ?? secret))
}

private let anthropicFixture = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-5","stop_reason":null,"usage":{"input_tokens":12,"output_tokens":1,"cache_read_input_tokens":3,"cache_creation_input_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Check the file."}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" there"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: content_block_start
data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"lookup","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"q\\":"}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\\"escrow\\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":2}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":20}}

event: message_stop
data: {"type":"message_stop"}

"""

private let responsesFixture = """
data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"lookup","arguments":""}}

data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":0,"delta":"{\\"q\\":"}

data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":0,"delta":"\\"escrow\\"}"}

data: {"type":"response.function_call_arguments.done","item_id":"fc_1","output_index":0,"name":"lookup","arguments":"{\\"q\\":\\"escrow\\"}"}

data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"lookup","arguments":"{\\"q\\":\\"escrow\\"}"}}

data: {"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":1,"summary_index":0,"delta":"Thinking"}

data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":2,"content_index":0,"delta":"Done"}

data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":8,"output_tokens":4,"input_tokens_details":{"cached_tokens":2}}}}

"""

private let chatFixture = """
data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Hi"},"finish_reason":null}]}

data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"lookup","arguments":""}}]},"finish_reason":null}]}

data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"q\\":\\"x\\"}"}}]},"finish_reason":null}]}

data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3}}

data: [DONE]

"""
