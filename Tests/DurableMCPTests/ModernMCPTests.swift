import DurableCore
import DurableMCP
import DurableStore
import Foundation
import MCP
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func connect(
    _ server: FakeModernServer,
    choice: MCPProtocolChoice = .automatic,
    handler: (any MCPInputHandler)? = nil
) async throws -> MCPClientSession {
    try await MCPClientSession.http(
        endpoint: server.endpoint,
        headers: ["X-Auth": "fake-token"],
        timeoutSeconds: 5,
        protocolChoice: choice,
        server: "fake",
        inputHandler: handler,
        urlSessionConfiguration: server.configuration
    )
}

@Test func discoverNegotiatesTheModernVersionAndSendsRequestMetadata() async throws {
    let schema = JSONValue.object([
        "properties": .object([
            "query": .object(["type": .string("string")]),
            "region": .object(["type": .string("string"), "x-mcp-header": .string("Region")]),
        ]),
        "type": .string("object"),
    ])
    let broken = JSONValue.object([
        "properties": .object(["items": .object([
            "items": .object(["type": .string("string"), "x-mcp-header": .string("Item")]),
            "type": .string("array"),
        ])]),
        "type": .string("object"),
    ])
    let server = FakeModernServer { request, _ in
        switch request.method {
        case "server/discover":
            return FakeModernServer.discover(request)
        case "tools/list":
            return FakeModernServer.result(request, [
                "cacheScope": .string("public"),
                "tools": .array([
                    .object(["annotations": .object(["readOnlyHint": .bool(true)]), "description": .string("Run SQL"), "inputSchema": schema, "name": .string("execute_sql")]),
                    .object(["description": .string("Bad header annotation"), "inputSchema": broken, "name": .string("broken")]),
                ]),
                "ttlMs": .int(0),
            ])
        case "tools/call":
            return FakeModernServer.result(request, ["content": FakeModernServer.text("rows: 3")])
        default:
            return FakeModernServer.error(request, code: -32601, message: "Method not found", status: 404)
        }
    }
    defer { server.stop() }
    let session = try await connect(server)
    #expect(await session.protocolVersion == MCPProtocol.modern)
    let described = try await session.describe()
    #expect(described.era == .modern)
    #expect(described.serverName == "fake")
    #expect(described.supportsTasks)
    #expect(described.instructions == "fake server")

    let discover = try #require(server.requests("server/discover").first)
    #expect(discover.header("MCP-Protocol-Version") == MCPProtocol.modern)
    #expect(discover.header("Mcp-Method") == "server/discover")
    #expect(discover.header("X-Auth") == "fake-token")
    let meta = discover.params["_meta"]
    #expect(meta?[MCPProtocol.protocolVersionKey] == .string(MCPProtocol.modern))
    #expect(meta?[MCPProtocol.clientInfoKey]?["name"] == .string("DurableAgents"))
    #expect(meta?[MCPProtocol.clientCapabilitiesKey]?["extensions"]?[MCPProtocol.tasksExtension] != nil)
    #expect(meta?[MCPProtocol.clientCapabilitiesKey]?["elicitation"] == nil)

    let listed = try await session.listTools()
    #expect(listed.map(\.name) == ["execute_sql"])
    #expect(listed.first?.hints.readOnlyHint == true)

    let output = try await session.callTool(
        name: "execute_sql",
        arguments: .object(["query": .string("select 1"), "region": .string("Zürich")])
    )
    #expect(output.texts == ["rows: 3"])
    let call = try #require(server.requests("tools/call").first)
    #expect(call.header("Mcp-Method") == "tools/call")
    #expect(call.header("Mcp-Name") == "execute_sql")
    #expect(call.header("Mcp-Param-Region") == "=?base64?" + Data("Zürich".utf8).base64EncodedString() + "?=")
    #expect(call.params["_meta"]?[MCPProtocol.protocolVersionKey] == .string(MCPProtocol.modern))
    await session.close()
}

@Test func aLegacyServerFallsBackToTheSDKHandshake() async throws {
    let server = FakeModernServer { request, _ in
        switch request.method {
        case "server/discover":
            // A legacy server: no recognized modern error in the body.
            return .empty(status: 400)
        case "initialize":
            return FakeModernServer.result(request, [
                "capabilities": .object(["tools": .object([:])]),
                "protocolVersion": .string(MCPProtocol.legacy),
                "serverInfo": .object(["name": .string("old"), "version": .string("1.0")]),
            ])
        case "notifications/initialized":
            return .empty(status: 202)
        case "tools/list":
            return FakeModernServer.result(request, [
                "tools": .array([.object(["inputSchema": .object(["type": .string("object")]), "name": .string("ping")])]),
            ])
        case "tools/call":
            return FakeModernServer.result(request, ["content": FakeModernServer.text("pong")])
        default:
            return FakeModernServer.error(request, code: -32601, message: "Method not found")
        }
    }
    defer { server.stop() }
    let session = try await connect(server)
    #expect(await session.protocolVersion == MCPProtocol.legacy)
    #expect(try await session.describe().era == .legacy)
    #expect(try await session.listTools().map(\.name) == ["ping"])
    let output = try await session.callTool(
        name: "ping",
        arguments: .object([:]),
        context: MCPCallContext(idempotencyKey: "dak-legacy", server: "fake")
    )
    #expect(output.texts == ["pong"])
    #expect(server.count("initialize") == 1)
    // The legacy call still carries the idempotency key in `_meta`.
    #expect(server.requests("tools/call").first?.params["_meta"]?[MCPProtocol.idempotencyKeyMeta] == .string("dak-legacy"))
    await session.close()

    let strict = FakeModernServer { _, _ in .empty(status: 400) }
    defer { strict.stop() }
    await #expect(throws: MCPCallError.self) {
        _ = try await connect(strict, choice: .modern)
    }
}

@Test func aModernErrorOnTheProbeDoesNotFallBack() async throws {
    let server = FakeModernServer { request, _ in
        FakeModernServer.error(
            request,
            code: MCPProtocol.unsupportedProtocolVersion,
            message: "Unsupported protocol version",
            data: .object(["requested": .string(MCPProtocol.modern), "supported": .array([.string("2099-01-01")])]),
            status: 400
        )
    }
    defer { server.stop() }
    await #expect(throws: MCPCallError.self) {
        _ = try await connect(server)
    }
    #expect(server.count("initialize") == 0)
}

@Test func inputRequiredRetriesWithTheAnswerAndTheExactRequestState() async throws {
    let server = FakeModernServer { request, earlier in
        switch request.method {
        case "server/discover":
            return FakeModernServer.discover(request)
        case "tools/call":
            switch earlier {
            case 0:
                return FakeModernServer.result(request, [
                    "inputRequests": .object([
                        "github_login": .object([
                            "method": .string("elicitation/create"),
                            "params": .object([
                                "message": .string("Your GitHub username?"),
                                "mode": .string("form"),
                                "requestedSchema": .object([
                                    "properties": .object(["name": .object(["type": .string("string")])]),
                                    "type": .string("object"),
                                ]),
                            ]),
                        ]),
                    ]),
                    "requestState": .string("opaque-1"),
                    "resultType": .string("input_required"),
                ])
            case 1:
                // Load shedding: state only. The client retries at once without inputs.
                return FakeModernServer.result(request, [
                    "requestState": .string("opaque-2"),
                    "resultType": .string("input_required"),
                ])
            default:
                return FakeModernServer.result(request, ["content": FakeModernServer.text("hello octocat")])
            }
        default:
            return FakeModernServer.error(request, code: -32601, message: "Method not found", status: 404)
        }
    }
    defer { server.stop() }
    let asked = AskedLog()
    let handler = MCPElicitationHandler { request in
        await asked.add(request)
        return MCPElicitationAnswer(action: .accept, content: ["name": .string("octocat")])
    }
    let session = try await connect(server, handler: handler)
    let output = try await session.callTool(name: "greet", arguments: .object([:]))
    #expect(output.texts == ["hello octocat"])

    let seen = await asked.requests
    #expect(seen.count == 1)
    #expect(seen.first?.key == "github_login")
    #expect(seen.first?.message == "Your GitHub username?")
    #expect(seen.first?.elicitationMode == "form")
    #expect(seen.first?.server == "fake")

    let calls = server.requests("tools/call")
    #expect(calls.count == 3)
    #expect(Set(calls.map(\.id)).count == 3)
    #expect(calls[0].params["requestState"] == nil)
    #expect(calls[1].params["requestState"] == .string("opaque-1"))
    #expect(calls[1].params["inputResponses"]?["github_login"]?["action"] == .string("accept"))
    #expect(calls[1].params["inputResponses"]?["github_login"]?["content"]?["name"] == .string("octocat"))
    #expect(calls[2].params["requestState"] == .string("opaque-2"))
    #expect(calls[2].params["inputResponses"] == nil)
    #expect(calls[0].params["_meta"]?[MCPProtocol.clientCapabilitiesKey]?["elicitation"] != nil)
    await session.close()
}

@Test func listResultsAreCachedForTtlMsAndInvalidatedByListChanged() async throws {
    let server = FakeModernServer { request, _ in
        switch request.method {
        case "server/discover":
            return FakeModernServer.discover(request)
        case "tools/list":
            return FakeModernServer.result(request, [
                "cacheScope": .string("public"),
                "tools": .array([.object(["inputSchema": .object(["type": .string("object")]), "name": .string("a")])]),
                "ttlMs": .int(300),
            ])
        case "resources/read":
            return FakeModernServer.result(request, [
                "cacheScope": .string("private"),
                "contents": .array([.object(["mimeType": .string("text/plain"), "text": .string("v1"), "uri": request.params["uri"] ?? .null])]),
                "ttlMs": .int(60_000),
            ])
        case "prompts/list":
            return FakeModernServer.result(request, [
                "prompts": .array([.object(["arguments": .array([.object(["name": .string("topic"), "required": .bool(true)])]), "name": .string("brief")])]),
                "ttlMs": .int(0),
            ])
        case "subscriptions/listen":
            let id = request.id
            let subscription = JSONValue.object([MCPProtocol.subscriptionIDKey: id])
            return .sse([
                .object(["jsonrpc": .string("2.0"), "method": .string("notifications/subscriptions/acknowledged"), "params": .object([
                    "_meta": subscription,
                    "notifications": .object(["resourceSubscriptions": .array([.string("file:///a")]), "toolsListChanged": .bool(true)]),
                ])]),
                .object(["jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed"), "params": .object(["_meta": subscription])]),
                .object(["jsonrpc": .string("2.0"), "method": .string("notifications/resources/updated"), "params": .object(["_meta": subscription, "uri": .string("file:///a")])]),
                .object(["id": id, "jsonrpc": .string("2.0"), "result": .object(["_meta": subscription, "resultType": .string("complete")])]),
            ])
        default:
            return FakeModernServer.error(request, code: -32601, message: "Method not found", status: 404)
        }
    }
    defer { server.stop() }
    let session = try await connect(server)

    _ = try await session.listTools()
    _ = try await session.listTools()
    #expect(server.count("tools/list") == 1)
    try await Task.sleep(for: .milliseconds(450))
    _ = try await session.listTools()
    #expect(server.count("tools/list") == 2)

    let first = try await session.readResource(uri: "file:///a")
    _ = try await session.readResource(uri: "file:///a")
    #expect(first.first?.text == "v1")
    #expect(server.count("resources/read") == 1)

    // ttlMs 0 is immediately stale.
    #expect(try await session.listPrompts().first?.arguments.first?.required == true)
    _ = try await session.listPrompts()
    #expect(server.count("prompts/list") == 2)

    _ = try await session.listTools()
    #expect(server.count("tools/list") == 2)
    let events = try await session.listen(MCPSubscriptionFilter(toolsListChanged: true, resourceSubscriptions: ["file:///a"]))
    var seen: [MCPServerEvent] = []
    for try await event in events {
        seen.append(event)
    }
    #expect(seen == [
        .acknowledged(MCPSubscriptionFilter(toolsListChanged: true, resourceSubscriptions: ["file:///a"])),
        .toolsListChanged,
        .resourceUpdated(uri: "file:///a"),
        .closed,
    ])
    let listen = try #require(server.requests("subscriptions/listen").first)
    #expect(listen.params["notifications"]?["toolsListChanged"] == .bool(true))
    #expect(listen.params["notifications"]?["resourceSubscriptions"] == .array([.string("file:///a")]))

    // The notifications invalidated the fresh tool list and the resource.
    _ = try await session.listTools()
    #expect(server.count("tools/list") == 3)
    _ = try await session.readResource(uri: "file:///a")
    #expect(server.count("resources/read") == 2)
    await session.close()
}

@Test func aCrashWhileATaskRunsResumesPollingTheSameTask() async throws {
    let server = FakeModernServer { request, earlier in
        switch request.method {
        case "server/discover":
            return FakeModernServer.discover(request)
        case "tools/list":
            return FakeModernServer.result(request, [
                "tools": .array([.object(["inputSchema": .object(["type": .string("object")]), "name": .string("build_report")])]),
                "ttlMs": .int(0),
            ])
        case "tools/call":
            return FakeModernServer.result(request, [
                "createdAt": .string("2026-10-10T00:00:00Z"),
                "lastUpdatedAt": .string("2026-10-10T00:00:00Z"),
                "pollIntervalMs": .int(10),
                "resultType": .string("task"),
                "status": .string("working"),
                "taskId": .string("task-77"),
                "ttlMs": .int(60_000),
            ])
        case "tasks/get":
            if earlier < 2 {
                return FakeModernServer.result(request, [
                    "createdAt": .string("2026-10-10T00:00:00Z"),
                    "lastUpdatedAt": .string("2026-10-10T00:00:01Z"),
                    "pollIntervalMs": .int(10),
                    "status": .string("working"),
                    "taskId": request.params["taskId"] ?? .null,
                    "ttlMs": .int(60_000),
                ])
            }
            return FakeModernServer.result(request, [
                "createdAt": .string("2026-10-10T00:00:00Z"),
                "lastUpdatedAt": .string("2026-10-10T00:00:02Z"),
                "result": .object(["content": FakeModernServer.text("report ready"), "resultType": .string("complete")]),
                "status": .string("completed"),
                "taskId": request.params["taskId"] ?? .null,
                "ttlMs": .int(60_000),
            ])
        default:
            return FakeModernServer.error(request, code: -32601, message: "Method not found", status: 404)
        }
    }
    defer { server.stop() }
    let session = try await connect(server)
    let config = MCPServerConfig(
        name: "fake",
        transport: "http",
        url: server.endpoint.absoluteString,
        allow: ["build_report"],
        timeoutSeconds: 5,
        tools: ["build_report": MCPToolOverride(approval: false)]
    )
    let listed = try await session.listTools()
    let journal = InMemoryMCPTaskJournal()
    let crashing = try MCPToolBridge.makeTools(config: config, listed: listed, caller: session, taskJournal: CrashAfterRecord(inner: journal))
    let store = InMemoryEventStore()
    let engine = try await Engine(store: store, tools: crashing, leaseTTL: .seconds(3600))
    do {
        _ = try await engine.submit(Submission(
            requestID: "r1",
            text: "report",
            script: Script(steps: [
                .tool(name: "mcp.fake.build_report", callID: "c1", arguments: .object([:])),
                .finish("done"),
            ])
        ))
        Issue.record("expected a simulated crash")
    } catch is SimulatedProcessCrash {
    }
    await engine.close()
    #expect(server.count("tools/call") == 1)
    #expect(server.count("tasks/get") == 0)
    #expect(await journal.all.map(\.taskID) == ["task-77"])

    let tools = try MCPToolBridge.makeTools(config: config, listed: listed, caller: session, taskJournal: journal)
    let recovered = try await Engine(store: store, tools: tools, leaseTTL: .seconds(3600))
    let actions = try await recovered.recover()
    #expect(actions.first?.runStatus == .completed)
    #expect(server.count("tools/call") == 1)
    #expect(server.count("tasks/get") == 3)
    #expect(await journal.all.isEmpty)
    let blob = try await store.readAll().map { $0.payload.canonicalJSON() }.joined(separator: "\n")
    #expect(blob.contains("report ready"))
    #expect(blob.contains("task-77"))
    await session.close()
}

@Test func aTaskWaitingOnInputSuspendsForAPersonAfterACrash() async throws {
    let server = FakeModernServer { request, _ in
        switch request.method {
        case "server/discover":
            return FakeModernServer.discover(request)
        case "tasks/get":
            return FakeModernServer.result(request, [
                "createdAt": .string("2026-10-10T00:00:00Z"),
                "inputRequests": .object(["confirm": .object([
                    "method": .string("elicitation/create"),
                    "params": .object(["message": .string("Deploy to production?"), "requestedSchema": .object(["properties": .object([:]), "type": .string("object")])]),
                ])]),
                "lastUpdatedAt": .string("2026-10-10T00:00:01Z"),
                "status": .string("input_required"),
                "taskId": .string("task-9"),
                "ttlMs": .null,
            ])
        default:
            return FakeModernServer.error(request, code: -32601, message: "Method not found", status: 404)
        }
    }
    defer { server.stop() }
    let session = try await connect(server)
    let config = MCPServerConfig(
        name: "fake",
        transport: "http",
        url: server.endpoint.absoluteString,
        allow: ["deploy"],
        timeoutSeconds: 5,
        tools: ["deploy": MCPToolOverride(approval: false)]
    )
    let listed = [MCPListedTool(name: "deploy", summary: "", inputSchemaJSON: "{}", hints: MCPToolHints())]
    let journal = InMemoryMCPTaskJournal()
    let crashing = try MCPToolBridge.makeTools(config: config, listed: listed, caller: PlantTask(journal: journal, taskID: "task-9"), taskJournal: journal)
    let store = InMemoryEventStore()
    let engine = try await Engine(store: store, tools: crashing, leaseTTL: .seconds(3600))
    do {
        _ = try await engine.submit(Submission(
            requestID: "r1",
            text: "deploy",
            script: Script(steps: [.tool(name: "mcp.fake.deploy", callID: "c1", arguments: .object([:])), .finish("done")])
        ))
        Issue.record("expected a simulated crash")
    } catch is SimulatedProcessCrash {
    }
    await engine.close()

    let tools = try MCPToolBridge.makeTools(config: config, listed: listed, caller: session, taskJournal: journal)
    let recovered = try await Engine(store: store, tools: tools, leaseTTL: .seconds(3600))
    let actions = try await recovered.recover()
    #expect(actions.first?.runStatus == .suspended)
    let blob = try await store.readAll().map { $0.payload.canonicalJSON() }.joined(separator: "\n")
    #expect(blob.contains("needs input: Deploy to production?"))
    #expect(server.count("tasks/get") == 1)
    await session.close()
}

@Test func theIdempotencyKeyIsStableAcrossARetry() async throws {
    let server = FakeModernServer { request, _ in
        switch request.method {
        case "server/discover":
            return FakeModernServer.discover(request)
        case "tools/call":
            return FakeModernServer.result(request, ["content": FakeModernServer.text("charged")])
        default:
            return FakeModernServer.error(request, code: -32601, message: "Method not found", status: 404)
        }
    }
    defer { server.stop() }
    let session = try await connect(server)
    let config = MCPServerConfig(
        name: "fake",
        transport: "http",
        url: server.endpoint.absoluteString,
        allow: ["charge"],
        timeoutSeconds: 5,
        tools: ["charge": MCPToolOverride(approval: false, replayOnCrash: true)]
    )
    let listed = [MCPListedTool(name: "charge", summary: "", inputSchemaJSON: "{}", hints: MCPToolHints(destructiveHint: true))]
    let crashing = try MCPToolBridge.makeTools(config: config, listed: listed, caller: CrashAfterCall(inner: session, flag: OnceFlag()))
    let store = InMemoryEventStore()
    let engine = try await Engine(store: store, tools: crashing, leaseTTL: .seconds(3600))
    do {
        _ = try await engine.submit(Submission(
            requestID: "r1",
            text: "charge",
            script: Script(steps: [.tool(name: "mcp.fake.charge", callID: "c1", arguments: .object(["cents": .int(400)])), .finish("done")])
        ))
        Issue.record("expected a simulated crash")
    } catch is SimulatedProcessCrash {
    }
    await engine.close()

    let tools = try MCPToolBridge.makeTools(config: config, listed: listed, caller: session)
    let recovered = try await Engine(store: store, tools: tools, leaseTTL: .seconds(3600))
    let actions = try await recovered.recover()
    #expect(actions.first?.runStatus == .completed)
    let keys = server.requests("tools/call").map { $0.params["_meta"]?[MCPProtocol.idempotencyKeyMeta] }
    #expect(keys.count == 2)
    #expect(keys[0] != nil)
    #expect(keys[0] == keys[1])

    let storeID = try await store.storeID()
    let conversation = try #require(try await recovered.listConversations().first)
    let expected = MCPProtocol.idempotencyKey(for: EffectKey.derive(storeID: storeID, conversation: conversation, call: CallID("c1")))
    #expect(keys[0] == .string(expected))
    #expect(MCPProtocol.idempotencyKey(for: EffectKey(raw: "fx:a:b:c1")) != MCPProtocol.idempotencyKey(for: EffectKey(raw: "fx:a:b:c2")))
    #expect(!expected.contains(storeID))
    await session.close()
}

@Test func durableServerAnswersBothEras() async throws {
    let store = InMemoryEventStore()
    let engine = try await Engine(
        store: store,
        model: ScriptedModelStep(steps: [.finish("done")]),
        leaseTTL: .seconds(3600)
    )
    let host = DurableMCPServer(engine: engine, store: store, approverIDs: [])
    try await host.prepareHTTP()

    func post(_ body: JSONValue, headers: [String: String]) async -> (Int, JSONValue?) {
        let reply = await host.respond(HTTPRequest(method: "POST", headers: headers, body: Data(body.canonicalJSON().utf8), path: "/mcp"))
        return (reply.status, reply.body.flatMap { try? JSONValue.parse(String(decoding: $0, as: UTF8.self)) })
    }
    let meta = JSONValue.object([
        MCPProtocol.clientCapabilitiesKey: .object([:]),
        MCPProtocol.protocolVersionKey: .string(MCPProtocol.modern),
    ])
    let modernHeaders = ["MCP-Protocol-Version": MCPProtocol.modern, "Mcp-Method": "server/discover"]
    let (status, discovered) = await post(
        .object(["id": .int(1), "jsonrpc": .string("2.0"), "method": .string("server/discover"), "params": .object(["_meta": meta])]),
        headers: modernHeaders
    )
    #expect(status == 200)
    #expect(discovered?["result"]?["supportedVersions"]?.arrayValue?.contains(.string(MCPProtocol.modern)) == true)
    #expect(discovered?["result"]?["resultType"] == .string("complete"))
    #expect(discovered?["result"]?["ttlMs"] != nil)

    let (mismatch, mismatchBody) = await post(
        .object(["id": .int(2), "jsonrpc": .string("2.0"), "method": .string("tools/list"), "params": .object(["_meta": meta])]),
        headers: modernHeaders
    )
    #expect(mismatch == 400)
    #expect(mismatchBody?["error"]?["code"] == .int(Int64(MCPProtocol.headerMismatch)))

    let oldMeta = JSONValue.object([MCPProtocol.clientCapabilitiesKey: .object([:]), MCPProtocol.protocolVersionKey: .string("1900-01-01")])
    let (unsupported, unsupportedBody) = await post(
        .object(["id": .int(3), "jsonrpc": .string("2.0"), "method": .string("tools/list"), "params": .object(["_meta": oldMeta])]),
        headers: ["MCP-Protocol-Version": "1900-01-01", "Mcp-Method": "tools/list"]
    )
    #expect(unsupported == 400)
    #expect(unsupportedBody?["error"]?["code"] == .int(Int64(MCPProtocol.unsupportedProtocolVersion)))
    #expect(unsupportedBody?["error"]?["data"]?["supported"]?.arrayValue?.contains(.string(MCPProtocol.modern)) == true)

    let session = try await host.modernLoopbackClient()
    #expect(await session.protocolVersion == MCPProtocol.modern)
    let listed = try await session.listTools()
    #expect(listed.contains { $0.name == "start_run" })
    #expect(listed.first { $0.name == "get_run_status" }?.hints.readOnlyHint == true)
    let started = try await session.callTool(
        name: "start_run",
        arguments: .object(["requestId": .string("modern-1"), "text": .string("hello")])
    )
    #expect(started.isError == false)
    #expect(started.texts.joined().contains("completed"))
    let events = try await session.listen(MCPSubscriptionFilter(toolsListChanged: true))
    var iterator = events.makeAsyncIterator()
    #expect(try await iterator.next() == .acknowledged(MCPSubscriptionFilter()))
    await host.stop()
    #expect(try await iterator.next() == .closed)
    await session.close()

    let legacy = try await MCPClientSession.connected(try await legacyPair(host: DurableMCPServer(engine: engine, store: store, approverIDs: [])))
    #expect(await legacy.protocolVersion == MCPProtocol.legacy)
    #expect(try await legacy.listTools().contains { $0.name == "start_run" })
    await legacy.close()
}

@Test func fileTaskJournalSurvivesReopening() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-tasks-\(UUID().uuidString)")
        .appendingPathComponent("tasks.json")
    let first = FileMCPTaskJournal(url: url)
    try await first.record(MCPTaskRecord(effectKey: "fx:1", server: "s", tool: "t", taskID: "task-1"))
    let reopened = FileMCPTaskJournal(url: url)
    #expect(try await reopened.entry(effectKey: "fx:1")?.taskID == "task-1")
    try await reopened.remove(effectKey: "fx:1")
    #expect(try await FileMCPTaskJournal(url: url).entry(effectKey: "fx:1") == nil)
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func serverConfigDefaultsToAutomaticProtocolSelection() throws {
    let old = try MCPServerConfig.parse(#"{"name":"a","transport":"http","url":"https://x.test/mcp","allow":["t"]}"#)
    #expect(old.protocolVersion == .automatic)
    #expect(old.taskTimeoutSeconds == 3600)
    let pinned = try MCPServerConfig.parse(#"{"name":"a","transport":"http","url":"https://x.test/mcp","protocolVersion":"2025-11-25"}"#)
    #expect(pinned.protocolVersion == .legacy)
    #expect(try MCPServerConfig.parse(try pinned.json()) == pinned)
}

// MARK: Helpers

private func legacyPair(host: DurableMCPServer) async throws -> any Transport {
    let (client, server) = await InMemoryTransport.createConnectedPair()
    try await host.start(transport: server)
    return client
}

private actor AskedLog {
    private(set) var requests: [MCPInputRequest] = []

    func add(_ request: MCPInputRequest) {
        requests.append(request)
    }
}

private actor OnceFlag {
    private var armed = true

    func consume() -> Bool {
        defer { armed = false }
        return armed
    }
}

/// Records the task id, then dies the way a killed process would.
private actor CrashAfterRecord: MCPTaskJournal {
    let inner: InMemoryMCPTaskJournal
    private var crashed = false

    init(inner: InMemoryMCPTaskJournal) {
        self.inner = inner
    }

    func record(_ entry: MCPTaskRecord) async throws {
        await inner.record(entry)
        if !crashed {
            crashed = true
            throw SimulatedProcessCrash()
        }
    }

    func entry(effectKey: String) async throws -> MCPTaskRecord? {
        await inner.entry(effectKey: effectKey)
    }

    func remove(effectKey: String) async throws {
        await inner.remove(effectKey: effectKey)
    }
}

/// Stands in for a call whose server answered with a task: records it, then crashes.
private struct PlantTask: MCPToolCaller {
    var journal: InMemoryMCPTaskJournal
    var taskID: String

    func callTool(name: String, arguments: JSONValue) async throws -> MCPToolOutput {
        throw MCPCallError("unused")
    }

    func callTool(name: String, arguments: JSONValue, context: MCPCallContext) async throws -> MCPToolOutput {
        await journal.record(MCPTaskRecord(effectKey: context.effectKey ?? "", server: context.server, tool: name, taskID: taskID))
        throw SimulatedProcessCrash()
    }
}

/// Lets the remote call land, then crashes before the engine journals the result.
private struct CrashAfterCall: MCPToolCaller {
    var inner: MCPClientSession
    var flag: OnceFlag

    func callTool(name: String, arguments: JSONValue) async throws -> MCPToolOutput {
        try await inner.callTool(name: name, arguments: arguments)
    }

    func callTool(name: String, arguments: JSONValue, context: MCPCallContext) async throws -> MCPToolOutput {
        let output = try await inner.callTool(name: name, arguments: arguments, context: context)
        if await flag.consume() {
            throw SimulatedProcessCrash()
        }
        return output
    }
}
