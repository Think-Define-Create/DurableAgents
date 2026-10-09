import DurableCore
import Foundation

/// Failure text that is safe to journal. It never includes a secret, a URL, or a response body.
public struct MCPCallError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Account names only. The value is resolved at connect or send time and is not journaled.
public protocol MCPSecretStore: Sendable {
    func secret(account: String) async throws -> String?
}

/// Hints copied from an MCP `Tool.annotations` object.
///
/// The spec fields are `title`, `readOnlyHint`, `destructiveHint`, `idempotentHint`,
/// and `openWorldHint`. They are hints. `openWorldHint` is kept and does not select an effect kind.
public struct MCPToolHints: Sendable, Equatable {
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    public var isAbsent: Bool {
        readOnlyHint == nil && destructiveHint == nil && idempotentHint == nil
    }
}

/// Per-tool override from the server config. Set fields replace the annotation mapping.
public struct MCPToolOverride: Codable, Sendable, Equatable {
    public var effect: EffectKind?
    public var approval: Bool?
    public var risk: ApprovalRisk?
    public var replayOnCrash: Bool?

    public init(
        effect: EffectKind? = nil,
        approval: Bool? = nil,
        risk: ApprovalRisk? = nil,
        replayOnCrash: Bool? = nil
    ) {
        self.effect = effect
        self.approval = approval
        self.risk = risk
        self.replayOnCrash = replayOnCrash
    }
}

/// How one remote MCP tool is registered on the engine.
public struct MCPEffectDecision: Sendable, Equatable {
    public var effect: EffectKind
    public var requiresApproval: Bool
    public var approvalRisk: ApprovalRisk
    /// When true, an `external` tool reconciles as `.notDone` and the same call runs again.
    /// When false, there is no reconcile hook, so a crash suspends for a person.
    public var replayOnCrash: Bool

    public init(
        effect: EffectKind,
        requiresApproval: Bool,
        approvalRisk: ApprovalRisk,
        replayOnCrash: Bool
    ) {
        self.effect = effect
        self.requiresApproval = requiresApproval
        self.approvalRisk = approvalRisk
        self.replayOnCrash = replayOnCrash
    }
}

public enum MCPEffectMapping {
    /// Config fields that are set win. The rest come from annotations.
    ///
    /// `readOnlyHint == true` is `pure` and does not ask for approval, even if a destructive hint is also set.
    /// `idempotentHint == true` (and not read-only) is `idempotent` without approval.
    /// `destructiveHint == true` is `external`, approval required, risk `high`.
    /// Missing hints are `external`, approval required, risk `standard`.
    /// Neither case installs a reconcile hook unless `replayOnCrash` is set.
    public static func decide(hints: MCPToolHints, override: MCPToolOverride? = nil) -> MCPEffectDecision {
        let base = fromHints(hints)
        guard let override else { return base }
        return MCPEffectDecision(
            effect: override.effect ?? base.effect,
            requiresApproval: override.approval ?? base.requiresApproval,
            approvalRisk: override.risk ?? base.approvalRisk,
            replayOnCrash: override.replayOnCrash ?? base.replayOnCrash
        )
    }

    private static func fromHints(_ hints: MCPToolHints) -> MCPEffectDecision {
        if hints.readOnlyHint == true {
            return MCPEffectDecision(
                effect: .pure,
                requiresApproval: false,
                approvalRisk: .standard,
                replayOnCrash: false
            )
        }
        if hints.idempotentHint == true {
            return MCPEffectDecision(
                effect: .idempotent,
                requiresApproval: false,
                approvalRisk: .standard,
                replayOnCrash: false
            )
        }
        if hints.destructiveHint == true {
            return MCPEffectDecision(
                effect: .external,
                requiresApproval: true,
                approvalRisk: .high,
                replayOnCrash: false
            )
        }
        return MCPEffectDecision(
            effect: .external,
            requiresApproval: true,
            approvalRisk: .standard,
            replayOnCrash: false
        )
    }
}

public enum MCPReconnect {
    /// One new connection after `connectionClosed`. Other MCP errors are not retried.
    public static func shouldRetry(connectionClosed: Bool, alreadyRetried: Bool) -> Bool {
        connectionClosed && !alreadyRetried
    }
}

enum MCPTimeout {
    static func run<T: Sendable>(
        seconds: Double,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if seconds <= 0 {
            return try await body()
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await body()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MCPCallError("mcp call timed out")
            }
            let value = try await group.next()
            group.cancelAll()
            guard let value else {
                throw MCPCallError("mcp call failed")
            }
            return value
        }
    }
}
