import Foundation

public enum ModelKitError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingSecret(String)
    case http(status: Int, body: String)
    case malformed(String)

    public var description: String {
        switch self {
        case .missingSecret(let name):
            return "missing secret \(name)"
        case .http(let status, let body):
            return "HTTP \(status): \(body)"
        case .malformed(let detail):
            return "malformed provider payload: \(detail)"
        }
    }
}

public struct ModelUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

public struct StopReason: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case endTurn
        case toolUse
        case maxTokens
        case refusal
        case aborted
        case unknown
    }

    public var raw: String
    public var kind: Kind

    public init(raw: String) {
        self.raw = raw
        switch raw {
        case "end_turn", "stop", "completed":
            self.kind = .endTurn
        case "tool_use", "tool_calls", "function_call":
            self.kind = .toolUse
        case "max_tokens", "length":
            self.kind = .maxTokens
        case "refusal", "content_filter":
            self.kind = .refusal
        default:
            self.kind = .unknown
        }
    }
}

public struct ProviderToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// In-memory stream. Persist a `ProviderTurn`, not each delta.
public enum ModelStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallDelta(id: String, name: String, argumentsDelta: String)
    case toolCall(ProviderToolCall)
    case usage(ModelUsage)
    case stop(StopReason)
}

public struct ProviderTurn: Sendable, Equatable {
    public var text: String
    public var thinking: String
    public var toolCalls: [ProviderToolCall]
    public var usage: ModelUsage
    public var stop: StopReason?

    public init(
        text: String = "",
        thinking: String = "",
        toolCalls: [ProviderToolCall] = [],
        usage: ModelUsage = ModelUsage(),
        stop: StopReason? = nil
    ) {
        self.text = text
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.usage = usage
        self.stop = stop
    }

    public mutating func apply(_ event: ModelStreamEvent) {
        switch event {
        case .textDelta(let delta):
            text += delta
        case .thinkingDelta(let delta):
            thinking += delta
        case .toolCallDelta:
            break
        case .toolCall(let call):
            toolCalls.append(call)
        case .usage(let next):
            if let value = next.inputTokens { usage.inputTokens = value }
            if let value = next.outputTokens { usage.outputTokens = value }
            if let value = next.cacheReadTokens { usage.cacheReadTokens = value }
            if let value = next.cacheWriteTokens { usage.cacheWriteTokens = value }
        case .stop(let reason):
            stop = reason
        }
    }
}

public struct ModelToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON object schema. Embedded as `input_schema` or `parameters`. Not a secret.
    public var parametersJSON: String

    public init(name: String, description: String, parametersJSON: String = #"{"type":"object","properties":{}}"#) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public struct ModelMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case system
        case user
        case assistant
        case tool
    }

    public var role: Role
    public var text: String
    public var toolCallID: String?
    public var toolName: String?
    public var toolCalls: [ProviderToolCall]

    public init(
        role: Role,
        text: String,
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolCalls: [ProviderToolCall] = []
    ) {
        self.role = role
        self.text = text
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolCalls = toolCalls
    }
}

public struct ModelRequest: Sendable, Equatable {
    public var model: String
    public var instructions: String
    public var messages: [ModelMessage]
    public var tools: [ModelToolDefinition]
    public var maxOutputTokens: Int

    public init(
        model: String,
        instructions: String = "",
        messages: [ModelMessage],
        tools: [ModelToolDefinition] = [],
        maxOutputTokens: Int = 1024
    ) {
        self.model = model
        self.instructions = instructions
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
    }
}

public protocol ModelProvider: Sendable {
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error>
}

extension ModelProvider {
    /// Accumulates the stream into one checkpoint. Token deltas are not returned separately.
    public func complete(_ request: ModelRequest) async throws -> ProviderTurn {
        var turn = ProviderTurn()
        for try await event in stream(request) {
            turn.apply(event)
        }
        return turn
    }
}

public struct ScriptedProvider: ModelProvider {
    public var events: [ModelStreamEvent]

    public init(events: [ModelStreamEvent]) {
        self.events = events
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let events = self.events
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

@available(*, deprecated, renamed: "ModelKitError")
public typealias PiAIError = ModelKitError
