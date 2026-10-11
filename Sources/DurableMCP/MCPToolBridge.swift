import DurableCore
import Foundation

public enum MCPToolBridge {
    public static func exposedName(server: String, tool: String) -> String {
        "mcp.\(server).\(tool)"
    }

    /// Keeps only allowlisted remote tools. An empty allowlist returns no tools.
    ///
    /// Every call sends an idempotency key derived from the engine effect key, the same on every retry.
    /// With a `taskJournal`, a server task id is recorded before polling, and a crash resumes polling
    /// that task instead of calling the tool again. A task that waits on input with nothing to answer
    /// it suspends the run for a person.
    public static func makeTools(
        config: MCPServerConfig,
        listed: [MCPListedTool],
        caller: any MCPToolCaller,
        taskJournal: (any MCPTaskJournal)? = nil
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
            let server = config.name
            let taskTimeout = config.taskTimeoutSeconds
            let context: @Sendable (EffectKey) -> MCPCallContext = { key in
                MCPCallContext(
                    idempotencyKey: MCPProtocol.idempotencyKey(for: key),
                    effectKey: key.raw,
                    server: server,
                    taskJournal: taskJournal,
                    taskTimeoutSeconds: taskTimeout
                )
            }
            let reconcile: (@Sendable (EffectKey, EffectContext) async throws -> Reconciliation)?
            if decision.effect == .external, let taskJournal {
                let replay = decision.replayOnCrash
                reconcile = { key, _ in
                    guard let record = try await taskJournal.entry(effectKey: key.raw) else {
                        if replay {
                            return .notDone
                        }
                        return .unknown(reason: "external tool \(exposed) has no recorded mcp task; the call may have reached the server")
                    }
                    do {
                        let output = try await caller.resumeTask(record, context: context(key))
                        return .done(output.journaled)
                    } catch let waiting as MCPTaskNeedsInput {
                        return .unknown(reason: "mcp task \(waiting.taskID) on \(server) needs input: \(String(waiting.message.prefix(300)))")
                    }
                }
            } else if decision.effect == .external && decision.replayOnCrash {
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
                run: { arguments, effect in
                    let callContext = context(effect.key)
                    do {
                        let output: MCPToolOutput
                        if await caller.timesOutPerRequest {
                            output = try await caller.callTool(name: remoteName, arguments: arguments, context: callContext)
                        } else {
                            output = try await MCPTimeout.run(seconds: timeout) {
                                try await caller.callTool(name: remoteName, arguments: arguments, context: callContext)
                            }
                        }
                        return ToolReturn(output: output.journaled)
                    } catch is SimulatedProcessCrash {
                        throw SimulatedProcessCrash()
                    } catch let error as MCPCallError {
                        throw error
                    } catch let waiting as MCPTaskNeedsInput {
                        throw MCPCallError("mcp task \(waiting.taskID) needs input")
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
