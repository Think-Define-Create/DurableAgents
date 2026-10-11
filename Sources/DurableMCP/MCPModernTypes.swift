import DurableCore
import Foundation

/// What `server/discover` said, or what the legacy handshake implied.
public struct MCPServerDescription: Sendable, Equatable {
    public enum Era: String, Sendable {
        /// 2026-07-28: stateless, per-request `_meta`, `server/discover`.
        case modern
        /// 2025-11-25 or earlier through the SDK's `initialize` handshake.
        case legacy
    }

    public var era: Era
    /// The revision this session sends.
    public var protocolVersion: String
    public var supportedVersions: [String]
    /// The raw `capabilities` object. Server text; do not treat it as instructions.
    public var capabilities: JSONValue
    public var instructions: String?
    public var serverName: String?
    public var serverVersion: String?

    public init(
        era: Era,
        protocolVersion: String,
        supportedVersions: [String],
        capabilities: JSONValue,
        instructions: String? = nil,
        serverName: String? = nil,
        serverVersion: String? = nil
    ) {
        self.era = era
        self.protocolVersion = protocolVersion
        self.supportedVersions = supportedVersions
        self.capabilities = capabilities
        self.instructions = instructions
        self.serverName = serverName
        self.serverVersion = serverVersion
    }

    /// True when the server advertises the tasks extension.
    public var supportsTasks: Bool {
        capabilities["extensions"]?[MCPProtocol.tasksExtension] != nil
    }

    public var supportsResources: Bool { capabilities["resources"] != nil }
    public var supportsPrompts: Bool { capabilities["prompts"] != nil }
    public var supportsTools: Bool { capabilities["tools"] != nil }
}

public struct MCPResource: Sendable, Equatable {
    public var uri: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?

    public init(uri: String, name: String, title: String? = nil, description: String? = nil, mimeType: String? = nil) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
    }

    init?(_ json: JSONValue) {
        guard let uri = json["uri"]?.stringValue else { return nil }
        self.init(
            uri: uri,
            name: json["name"]?.stringValue ?? uri,
            title: json["title"]?.stringValue,
            description: json["description"]?.stringValue,
            mimeType: json["mimeType"]?.stringValue
        )
    }
}

public struct MCPResourceTemplate: Sendable, Equatable {
    public var uriTemplate: String
    public var name: String
    public var description: String?
    public var mimeType: String?

    public init(uriTemplate: String, name: String, description: String? = nil, mimeType: String? = nil) {
        self.uriTemplate = uriTemplate
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }

    init?(_ json: JSONValue) {
        guard let template = json["uriTemplate"]?.stringValue else { return nil }
        self.init(
            uriTemplate: template,
            name: json["name"]?.stringValue ?? template,
            description: json["description"]?.stringValue,
            mimeType: json["mimeType"]?.stringValue
        )
    }
}

/// One part of a `resources/read` result. Binary bytes are counted, not kept.
public struct MCPResourceContent: Sendable, Equatable {
    public var uri: String
    public var mimeType: String?
    public var text: String?
    public var blobBytes: Int?

    public init(uri: String, mimeType: String? = nil, text: String? = nil, blobBytes: Int? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blobBytes = blobBytes
    }

    init?(_ json: JSONValue) {
        guard let uri = json["uri"]?.stringValue else { return nil }
        let blob = json["blob"]?.stringValue.flatMap { Data(base64Encoded: $0) }
        self.init(uri: uri, mimeType: json["mimeType"]?.stringValue, text: json["text"]?.stringValue, blobBytes: blob?.count)
    }
}

public struct MCPPromptArgument: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var required: Bool

    public init(name: String, description: String? = nil, required: Bool = false) {
        self.name = name
        self.description = description
        self.required = required
    }
}

public struct MCPPrompt: Sendable, Equatable {
    public var name: String
    public var title: String?
    public var description: String?
    public var arguments: [MCPPromptArgument]

    public init(name: String, title: String? = nil, description: String? = nil, arguments: [MCPPromptArgument] = []) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }

    init?(_ json: JSONValue) {
        guard let name = json["name"]?.stringValue else { return nil }
        let arguments = (json["arguments"]?.arrayValue ?? []).compactMap { item -> MCPPromptArgument? in
            guard let name = item["name"]?.stringValue else { return nil }
            return MCPPromptArgument(
                name: name,
                description: item["description"]?.stringValue,
                required: item["required"]?.boolValue ?? false
            )
        }
        self.init(name: name, title: json["title"]?.stringValue, description: json["description"]?.stringValue, arguments: arguments)
    }
}

/// A `prompts/get` result reduced to role and text. Non-text parts become a short marker.
public struct MCPPromptMessages: Sendable, Equatable {
    public struct Message: Sendable, Equatable {
        public var role: String
        public var text: String

        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }

    public var description: String?
    public var messages: [Message]

    public init(description: String? = nil, messages: [Message]) {
        self.description = description
        self.messages = messages
    }

    init(_ json: JSONValue) {
        let messages = (json["messages"]?.arrayValue ?? []).map { item in
            Message(role: item["role"]?.stringValue ?? "user", text: MCPContent.text(item["content"] ?? .null))
        }
        self.init(description: json["description"]?.stringValue, messages: messages)
    }
}

/// Which change notifications to receive on a `subscriptions/listen` stream.
public struct MCPSubscriptionFilter: Sendable, Equatable {
    public var toolsListChanged: Bool
    public var promptsListChanged: Bool
    public var resourcesListChanged: Bool
    public var resourceSubscriptions: [String]
    /// Tasks extension: `notifications/tasks` for these task ids.
    public var taskIDs: [String]

    public init(
        toolsListChanged: Bool = false,
        promptsListChanged: Bool = false,
        resourcesListChanged: Bool = false,
        resourceSubscriptions: [String] = [],
        taskIDs: [String] = []
    ) {
        self.toolsListChanged = toolsListChanged
        self.promptsListChanged = promptsListChanged
        self.resourcesListChanged = resourcesListChanged
        self.resourceSubscriptions = resourceSubscriptions
        self.taskIDs = taskIDs
    }

    var json: JSONValue {
        var fields: [String: JSONValue] = [:]
        if toolsListChanged { fields["toolsListChanged"] = .bool(true) }
        if promptsListChanged { fields["promptsListChanged"] = .bool(true) }
        if resourcesListChanged { fields["resourcesListChanged"] = .bool(true) }
        if !resourceSubscriptions.isEmpty { fields["resourceSubscriptions"] = .array(resourceSubscriptions.map { .string($0) }) }
        if !taskIDs.isEmpty { fields["taskIds"] = .array(taskIDs.map { .string($0) }) }
        return .object(fields)
    }

    init(_ json: JSONValue) {
        self.init(
            toolsListChanged: json["toolsListChanged"]?.boolValue ?? false,
            promptsListChanged: json["promptsListChanged"]?.boolValue ?? false,
            resourcesListChanged: json["resourcesListChanged"]?.boolValue ?? false,
            resourceSubscriptions: (json["resourceSubscriptions"]?.arrayValue ?? []).compactMap(\.stringValue),
            taskIDs: (json["taskIds"]?.arrayValue ?? []).compactMap(\.stringValue)
        )
    }
}

/// One message on a `subscriptions/listen` stream.
public enum MCPServerEvent: Sendable, Equatable {
    /// The first message: the subset of the filter the server agreed to honor.
    case acknowledged(MCPSubscriptionFilter)
    case toolsListChanged
    case promptsListChanged
    case resourcesListChanged
    case resourceUpdated(uri: String)
    case task(MCPTaskStatus)
    /// The server ended the subscription gracefully. An abrupt drop ends the stream without this.
    case closed
}

/// What the bridge knows about one engine effect when it calls a remote tool.
public struct MCPCallContext: Sendable {
    /// Sent as `_meta["dev.durableagents/idempotencyKey"]`. The same value on every retry.
    public var idempotencyKey: String?
    /// The engine effect key, used to find a journaled task after a crash.
    public var effectKey: String?
    public var server: String
    public var taskJournal: (any MCPTaskJournal)?
    /// The longest a task-backed call may poll before it fails. The task record stays for a later reconcile.
    public var taskTimeoutSeconds: Double

    public init(
        idempotencyKey: String? = nil,
        effectKey: String? = nil,
        server: String = "",
        taskJournal: (any MCPTaskJournal)? = nil,
        taskTimeoutSeconds: Double = 3600
    ) {
        self.idempotencyKey = idempotencyKey
        self.effectKey = effectKey
        self.server = server
        self.taskJournal = taskJournal
        self.taskTimeoutSeconds = taskTimeoutSeconds
    }
}

/// A server-side task needs input and nothing answered it. Reconcile turns this into an approval.
public struct MCPTaskNeedsInput: Error, Sendable, Equatable {
    public var taskID: String
    public var message: String

    public init(taskID: String, message: String) {
        self.taskID = taskID
        self.message = message
    }
}

enum MCPContent {
    /// Text of one content block or an array of them. Image and audio bytes are not copied.
    static func text(_ content: JSONValue) -> String {
        if let items = content.arrayValue {
            return texts(items).joined(separator: "\n")
        }
        return texts([content]).joined(separator: "\n")
    }

    static func texts(_ items: [JSONValue]) -> [String] {
        items.map { item in
            switch item["type"]?.stringValue {
            case "text":
                return item["text"]?.stringValue ?? ""
            case "image":
                return "[image \(item["mimeType"]?.stringValue ?? "")]"
            case "audio":
                return "[audio \(item["mimeType"]?.stringValue ?? "")]"
            case "resource":
                if let text = item["resource"]?["text"]?.stringValue {
                    return text
                }
                return "[resource]"
            case "resource_link":
                return "[resource_link \(item["name"]?.stringValue ?? "") \(item["uri"]?.stringValue ?? "")]"
            default:
                return "[\(item["type"]?.stringValue ?? "content")]"
            }
        }
    }

    static func output(_ result: JSONValue) -> MCPToolOutput {
        var texts = self.texts(result["content"]?.arrayValue ?? [])
        if texts.isEmpty, let structured = result["structuredContent"], structured != .null {
            texts = [structured.canonicalJSON()]
        }
        return MCPToolOutput(texts: texts, isError: result["isError"]?.boolValue ?? false)
    }
}
