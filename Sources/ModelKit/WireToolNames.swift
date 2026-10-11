import Foundation

/// Cloud APIs accept tool names matching `^[a-zA-Z0-9_-]+$`. Engine tools use dotted names such as
/// `calendar.read`, so this wrapper renames tools on the way out and restores the names on the way back.
public struct WireToolNames: ModelProvider {
    public var inner: any ModelProvider

    public init(inner: any ModelProvider) {
        self.inner = inner
    }

    /// Replaces every character outside the allowed set with `_` and keeps names to 64 characters.
    public static func wireName(_ name: String) -> String {
        let mapped = name.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
            return allowed || scalar == "_" || scalar == "-" ? Character(scalar) : "_"
        }
        return String(String(mapped).prefix(64))
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        var toWire: [String: String] = [:]
        var fromWire: [String: String] = [:]
        func wire(_ name: String) -> String {
            if let known = toWire[name] { return known }
            var candidate = Self.wireName(name)
            var suffix = 2
            while let taken = fromWire[candidate], taken != name {
                candidate = String(Self.wireName(name).prefix(60)) + "_\(suffix)"
                suffix += 1
            }
            toWire[name] = candidate
            fromWire[candidate] = name
            return candidate
        }
        var outgoing = request
        outgoing.tools = request.tools.map { tool in
            var copy = tool
            copy.name = wire(tool.name)
            return copy
        }
        outgoing.messages = request.messages.map { message in
            var copy = message
            copy.toolName = message.toolName.map(wire)
            copy.toolCalls = message.toolCalls.map { call in
                ProviderToolCall(id: call.id, name: wire(call.name), argumentsJSON: call.argumentsJSON)
            }
            return copy
        }
        let names = fromWire
        let request = outgoing
        let inner = self.inner
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in inner.stream(request) {
                        switch event {
                        case .toolCall(let call):
                            continuation.yield(.toolCall(ProviderToolCall(
                                id: call.id,
                                name: names[call.name] ?? call.name,
                                argumentsJSON: call.argumentsJSON
                            )))
                        case .toolCallDelta(let id, let name, let delta):
                            continuation.yield(.toolCallDelta(id: id, name: names[name] ?? name, argumentsDelta: delta))
                        default:
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
