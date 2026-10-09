import DurableCore
import Foundation

public enum MCPToolBridge {
    public static func exposedName(server: String, tool: String) -> String {
        "mcp.\(server).\(tool)"
    }

    /// Keeps only allowlisted remote tools. An empty allowlist returns no tools.
    public static func makeTools(
        config: MCPServerConfig,
        listed: [MCPListedTool],
        caller: any MCPToolCaller
    ) throws -> [Tool] {
        try config.validate()
        let allowed = Set(config.allow)
        var tools: [Tool] = []
        var seen: Set<String> = []
        for remote in listed where allowed.contains(remote.name) {
            let exposed = exposedName(server: config.name, tool: remote.name)
            if seen.contains(exposed) {
                throw MCPCallError("duplicate mcp tool \(exposed)")
            }
            seen.insert(exposed)
            let decision = MCPEffectMapping.decide(hints: remote.hints, override: config.tools[remote.name])
            let reconcile: (@Sendable (EffectKey, EffectContext) async throws -> Reconciliation)?
            if decision.effect == .external && decision.replayOnCrash {
                reconcile = { _, _ in .notDone }
            } else {
                reconcile = nil
            }
            let remoteName = remote.name
            let timeout = config.timeoutSeconds
            let summary = remote.summary
            let schema = remote.inputSchemaJSON.isEmpty
                ? #"{"type":"object","properties":{}}"#
                : remote.inputSchemaJSON
            tools.append(Tool(
                name: exposed,
                effect: decision.effect,
                summary: summary,
                parametersJSON: schema,
                requiresApproval: decision.requiresApproval,
                approvalRisk: decision.approvalRisk,
                reconcile: reconcile,
                run: { arguments, _ in
                    do {
                        let output = try await MCPTimeout.run(seconds: timeout) {
                            try await caller.callTool(name: remoteName, arguments: arguments)
                        }
                        return ToolReturn(output: output.journaled)
                    } catch is SimulatedProcessCrash {
                        throw SimulatedProcessCrash()
                    } catch let error as MCPCallError {
                        throw error
                    } catch is CancellationError {
                        throw MCPCallError("mcp call cancelled")
                    } catch {
                        throw MCPCallError("mcp call failed")
                    }
                }
            ))
        }
        return tools
    }
}
