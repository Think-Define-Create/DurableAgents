import Foundation

public enum AgentError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingAgent
    case archived
    case emptyTitle
    case noConversation
    case badToken
    case onDeviceBlocked
    case stdioUnavailable
    case mcpListenUnavailable
    case invalidURL

    public var description: String {
        switch self {
        case .missingAgent: "No agent with that id."
        case .archived: "This agent is archived."
        case .emptyTitle: "Give the agent a name."
        case .noConversation: "This agent has no conversation yet."
        case .badToken: "That approval token is not valid."
        case .onDeviceBlocked: "On-device only mode blocks this cloud provider or network tool."
        case .stdioUnavailable: "stdio MCP servers are available on macOS, not on iOS."
        case .mcpListenUnavailable: "Exposing the engine as an MCP server is available on macOS."
        case .invalidURL: "That URL is not valid."
        }
    }
}

public enum ProviderKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case scripted
    case apple
    case anthropic
    case openai
    case compatible
}

/// One model's settings for an agent. `secretAccount` is a Keychain or environment name, never the key.
public struct ProviderChoice: Codable, Sendable, Equatable {
    public var kind: ProviderKind
    public var model: String
    public var baseURL: String?
    public var secretAccount: String?

    public init(kind: ProviderKind, model: String, baseURL: String? = nil, secretAccount: String? = nil) {
        self.kind = kind
        self.model = model
        self.baseURL = baseURL
        self.secretAccount = secretAccount
    }

    public static let demo = ProviderChoice(kind: .scripted, model: "lumen-demo")

    public static func anthropic(model: String = "claude-sonnet-4-5", account: String = "ANTHROPIC_API_KEY") -> ProviderChoice {
        ProviderChoice(kind: .anthropic, model: model, secretAccount: account)
    }

    public static func openAI(model: String = "gpt-5", account: String = "OPENAI_API_KEY") -> ProviderChoice {
        ProviderChoice(kind: .openai, model: model, secretAccount: account)
    }

    public static func compatible(model: String, baseURL: String, account: String = "OPENAI_API_KEY") -> ProviderChoice {
        ProviderChoice(kind: .compatible, model: model, baseURL: baseURL, secretAccount: account)
    }

    public static let apple = ProviderChoice(kind: .apple, model: "apple-foundation")
}

public enum OnDevicePolicy {
    public static func blocksCloud(_ choice: ProviderChoice) -> Bool {
        switch choice.kind {
        case .anthropic, .openai, .compatible:
            return true
        case .scripted, .apple:
            return false
        }
    }

    /// Network tools and HTTP MCP are refused. Local stdio MCP, EventKit, and contacts stay available.
    public static func blocksNetwork(_ onDeviceOnly: Bool) -> Bool {
        onDeviceOnly
    }
}

public struct AgentProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var conversationID: String?
    public var provider: ProviderChoice
    public var archived: Bool
    public var createdAt: Date
    public var forkedFrom: String?

    public init(
        id: String,
        title: String,
        conversationID: String? = nil,
        provider: ProviderChoice,
        archived: Bool = false,
        createdAt: Date = Date(),
        forkedFrom: String? = nil
    ) {
        self.id = id
        self.title = title
        self.conversationID = conversationID
        self.provider = provider
        self.archived = archived
        self.createdAt = createdAt
        self.forkedFrom = forkedFrom
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var onDeviceOnly: Bool
    public var appLock: Bool
    public var retentionDays: Int
    public var extraRedaction: [String]
    public var otelEndpoint: String
    public var webAllowHosts: [String]
    public var completedOnboarding: Bool
    /// Account names the loopback MCP server may use to approve. Empty refuses every approval.
    public var mcpApproverIDs: [String]

    public init(
        onDeviceOnly: Bool = false,
        appLock: Bool = false,
        retentionDays: Int = 365,
        extraRedaction: [String] = [],
        otelEndpoint: String = "",
        webAllowHosts: [String] = [],
        completedOnboarding: Bool = false,
        mcpApproverIDs: [String] = ["local"]
    ) {
        self.onDeviceOnly = onDeviceOnly
        self.appLock = appLock
        self.retentionDays = retentionDays
        self.extraRedaction = extraRedaction
        self.otelEndpoint = otelEndpoint
        self.webAllowHosts = webAllowHosts
        self.completedOnboarding = completedOnboarding
        self.mcpApproverIDs = mcpApproverIDs
    }
}

public struct AgentDirectory: Codable, Sendable, Equatable {
    public var agents: [AgentProfile]
    public var settings: AppSettings

    public init(agents: [AgentProfile] = [], settings: AppSettings = AppSettings()) {
        self.agents = agents
        self.settings = settings
    }

    public static func load(from directory: URL) throws -> AgentDirectory {
        let url = directory.appendingPathComponent("lumen-directory.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AgentDirectory()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AgentDirectory.self, from: data)
    }

    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("lumen-directory.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    public func agent(_ id: String) -> AgentProfile? {
        agents.first { $0.id == id }
    }

    public mutating func upsert(_ profile: AgentProfile) {
        if let index = agents.firstIndex(where: { $0.id == profile.id }) {
            agents[index] = profile
        } else {
            agents.append(profile)
        }
    }
}

/// Hosts the model reads while the engine holds its lock. Not the session actor.
public actor ProviderTable {
    private var byConversation: [String: ProviderChoice] = [:]
    private var pending: ProviderChoice = .demo

    public init() {}

    public func prepare(_ choice: ProviderChoice) {
        pending = choice
    }

    public func bind(_ conversationID: String, _ choice: ProviderChoice) {
        byConversation[conversationID] = choice
    }

    public func choice(for conversationID: String) -> ProviderChoice {
        if let known = byConversation[conversationID] {
            return known
        }
        byConversation[conversationID] = pending
        return pending
    }
}

public actor PolicyBox {
    public private(set) var onDeviceOnly: Bool

    public init(onDeviceOnly: Bool = false) {
        self.onDeviceOnly = onDeviceOnly
    }

    public func set(_ on: Bool) {
        onDeviceOnly = on
    }
}
