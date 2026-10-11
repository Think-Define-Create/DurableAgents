import DurableCore
import DurableMCP
import DurableStore
import Foundation
import MCP
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

@Test func annotationMappingDefaultsOpaqueToolsToExternalApproval() {
    let readOnly = MCPEffectMapping.decide(hints: MCPToolHints(readOnlyHint: true, destructiveHint: true))
    #expect(readOnly.effect == .pure)
    #expect(readOnly.requiresApproval == false)

    let idempotent = MCPEffectMapping.decide(hints: MCPToolHints(idempotentHint: true))
    #expect(idempotent.effect == .idempotent)
    #expect(idempotent.requiresApproval == false)

    let destructive = MCPEffectMapping.decide(hints: MCPToolHints(destructiveHint: true))
    #expect(destructive.effect == .external)
    #expect(destructive.requiresApproval == true)
    #expect(destructive.approvalRisk == .high)
    #expect(destructive.replayOnCrash == false)

    let absent = MCPEffectMapping.decide(hints: MCPToolHints())
    #expect(absent.effect == .external)
    #expect(absent.requiresApproval == true)
    #expect(absent.approvalRisk == .standard)
    #expect(absent.replayOnCrash == false)

    let overridden = MCPEffectMapping.decide(
        hints: MCPToolHints(destructiveHint: true),
        override: MCPToolOverride(effect: .idempotent, approval: false, replayOnCrash: true)
    )
    #expect(overridden.effect == .idempotent)
    #expect(overridden.requiresApproval == false)
    #expect(overridden.approvalRisk == .high)
    #expect(overridden.replayOnCrash == true)
    #expect(MCPReconnect.shouldRetry(connectionClosed: true, alreadyRetried: false))
    #expect(!MCPReconnect.shouldRetry(connectionClosed: true, alreadyRetried: true))
    #expect(!MCPReconnect.shouldRetry(connectionClosed: false, alreadyRetried: false))
    #expect(MCPPlatform.stdioAvailable)
    #if os(Linux)
    #expect(MCPPlatform.sseStreamingCompiled == false)
    #else
    #expect(MCPPlatform.sseStreamingCompiled)
    #endif
}

@Test func serverConfigKeepsAccountNamesAndRejectsAnEmptyAllowlist() throws {
    let parsed = try MCPServerConfig.parse(
        """
        {"name":"files","transport":"stdio","command":"/usr/bin/true","envSecrets":{"TOKEN":"files-token"},"headerSecrets":{"Authorization":"files-auth"},"allow":["echo"],"tools":{"echo":{"effect":"pure","approval":false}}}
        """
    )
    #expect(parsed.envSecrets["TOKEN"] == "files-token")
    #expect(parsed.headerSecrets["Authorization"] == "files-auth")
    #expect(parsed.tools["echo"]?.effect == .pure)
    let encoded = try parsed.json()
    #expect(!encoded.contains("super-secret"))
    #expect(throws: MCPCallError.self) {
        try MCPServerConfig(name: "bad.name", transport: "stdio", command: "/bin/true").validate()
    }
    let empty = MCPServerConfig(name: "files", transport: "http", url: "http://127.0.0.1/mcp", allow: [])
    let tools = try MCPToolBridge.makeTools(
        config: empty,
        listed: [MCPListedTool(name: "echo", summary: "", inputSchemaJSON: "{}", hints: MCPToolHints(readOnlyHint: true))],
        caller: StaticCaller(texts: ["nope"])
    )
    #expect(tools.isEmpty)
}

@Test func inProcessServerMapsReadOnlyAndDestructiveTools() async throws {
    let world = try await DemoServer.make()
    let config = MCPServerConfig(
        name: "demo",
        transport: "http",
        url: "http://127.0.0.1/mcp",
        allow: ["lookup", "wipe"],
        timeoutSeconds: 5
    )
    let listed = try await world.session.listTools()
    let tools = try MCPToolBridge.makeTools(config: config, listed: listed, caller: world.session)
    let lookup = try #require(tools.first { $0.name == "mcp.demo.lookup" })
    let wipe = try #require(tools.first { $0.name == "mcp.demo.wipe" })
    #expect(lookup.effect == .pure)
    #expect(lookup.requiresApproval == false)
    #expect(wipe.effect == .external)
    #expect(wipe.requiresApproval == true)
    #expect(wipe.approvalRisk == .high)
    #expect(!tools.contains { $0.name.contains("hidden") })

    let store = InMemoryEventStore()
    let engine = try await Engine(store: store, tools: tools, leaseTTL: .seconds(3600))
    let read = try await engine.submit(Submission(
        requestID: "read",
        text: "look up",
        script: Script(steps: [
            .tool(name: "mcp.demo.lookup", callID: "c-read", arguments: .object(["text": .string("harbor")])),
            .finish("done"),
        ])
    ))
    #expect(read.runStatus == .completed)
    #expect(await world.calls.count("lookup") == 1)
    let journal = try await store.readAll().map { $0.payload.canonicalJSON() }.joined()
    #expect(journal.contains("harbor"))

    let gated = try await engine.submit(Submission(
        requestID: "wipe",
        text: "wipe",
        script: Script(steps: [
            .tool(name: "mcp.demo.wipe", callID: "c-wipe", arguments: .object(["text": .string("all")])),
            .finish("wiped"),
        ])
    ))
    #expect(gated.runStatus == .suspended)
    #expect(await world.calls.count("wipe") == 0)
    let token = try #require(gated.resumeToken)
    let resumed = try await engine.resume(
        token: token,
        decision: .approved,
        approver: Approver(id: "owner", authLevel: .biometric)
    )
    #expect(resumed.runStatus == .completed)
    #expect(await world.calls.count("wipe") == 1)
    await world.server.stop()
    await world.session.close()
}

@Test func mcpToolCrashSuspendsWithoutASecondCall() async throws {
    let world = try await DemoServer.make()
    let config = MCPServerConfig(
        name: "demo",
        transport: "http",
        url: "http://127.0.0.1/mcp",
        allow: ["charge"],
        timeoutSeconds: 5,
        tools: ["charge": MCPToolOverride(approval: false)]
    )
    let listed = try await world.session.listTools()
    let crashing = CrashAfter(inner: world.session, flag: CrashFlag())
    let tools = try MCPToolBridge.makeTools(config: config, listed: listed, caller: crashing)
    let store = InMemoryEventStore()
    let engine = try await Engine(store: store, tools: tools, leaseTTL: .seconds(3600))
    do {
        _ = try await engine.submit(Submission(
            requestID: "r1",
            text: "charge",
            script: Script(steps: [
                .tool(name: "mcp.demo.charge", callID: "c1", arguments: .object(["text": .string("4")])),
                .finish("done"),
            ])
        ))
        Issue.record("expected a simulated crash")
    } catch is SimulatedProcessCrash {
    }
    await engine.close()
    #expect(await world.calls.count("charge") == 1)
    let midpoint = try await store.readAll()
    #expect(midpoint.contains { $0.type == EventType.effectIntent })
    #expect(!midpoint.contains { $0.type == EventType.effectResult })

    let recovered = try await Engine(store: store, tools: tools, leaseTTL: .seconds(3600))
    let actions = try await recovered.recover()
    #expect(actions.first?.runStatus == .suspended)
    #expect(await world.calls.count("charge") == 1)
    let token = try #require(actions.first?.resumeToken)
    let resumed = try await recovered.resume(
        token: token,
        decision: .approvedWithOutput(.string("settled offline")),
        approver: Approver(id: "owner", authLevel: .session)
    )
    #expect(resumed.runStatus == .completed)
    #expect(await world.calls.count("charge") == 1)
    await world.server.stop()
    await world.session.close()
}

@Test func callTimeoutFailsWithoutWaitingForTheRemote() async throws {
    let config = MCPServerConfig(
        name: "slow",
        transport: "http",
        url: "http://127.0.0.1/mcp",
        allow: ["nap"],
        timeoutSeconds: 0.2
    )
    let tools = try MCPToolBridge.makeTools(
        config: config,
        listed: [MCPListedTool(name: "nap", summary: "sleep", inputSchemaJSON: "{}", hints: MCPToolHints(readOnlyHint: true))],
        caller: SlowCaller()
    )
    let store = InMemoryEventStore()
    let engine = try await Engine(store: store, tools: tools, leaseTTL: .seconds(3600))
    let started = Date()
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "nap",
        script: Script(steps: [
            .tool(name: "mcp.slow.nap", callID: "c1", arguments: .object([:])),
            .finish("done"),
        ])
    ))
    #expect(result.runStatus == .failed)
    #expect(Date().timeIntervalSince(started) < 2)
    let blob = try await store.readAll().map { $0.payload.canonicalJSON() }.joined()
    #expect(blob.contains("mcp call timed out"))
}

@Test func durableServerApprovesOnlyAllowlistedIdentities() async throws {
    let calls = LocalCalls()
    let tool = Tool(name: "wire", effect: .external, requiresApproval: true, approvalRisk: .high) { _, _ in
        await calls.bump()
        return ToolReturn(output: .string("sent"))
    }
    let store = InMemoryEventStore()
    let engine = try await Engine(
        store: store,
        tools: [tool],
        model: ScriptedModelStep(steps: [
            .tool(name: "wire", callID: "c1", arguments: .object([:])),
            .finish("sent"),
        ]),
        leaseTTL: .seconds(3600)
    )
    let host = DurableMCPServer(engine: engine, store: store, approverIDs: ["ada"])
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await host.start(transport: serverTransport)
    let session = try await MCPClientSession.connected(clientTransport)
    let started = try await session.callTool(
        name: "start_run",
        arguments: .object(["requestId": .string("r1"), "text": .string("wire it")])
    )
    #expect(started.isError == false)
    let body = try JSONValue.parse(started.texts[0])
    #expect(body["runStatus"]?.stringValue == RunStatus.suspended.rawValue)
    let conversation = try #require(body["conversationId"]?.stringValue)
    let token = try #require(body["resumeToken"]?.stringValue)
    let approval = try #require(ResumeToken(raw: token)?.approvalID)

    let stranger = try await session.callTool(name: "approve", arguments: .object([
        "approvalId": .string(approval),
        "approverId": .string("eve"),
        "authLevel": .string(AuthenticationLevel.biometric.rawValue),
        "conversationId": .string(conversation),
    ]))
    #expect(stranger.isError == true)
    #expect(stranger.texts.joined().contains("approver is not allowed"))
    #expect(await calls.count == 0)

    let weak = try await session.callTool(name: "approve", arguments: .object([
        "approvalId": .string(approval),
        "approverId": .string("ada"),
        "authLevel": .string(AuthenticationLevel.session.rawValue),
        "conversationId": .string(conversation),
    ]))
    #expect(weak.isError == true)
    #expect(await calls.count == 0)

    let pending = try await session.callTool(name: "list_pending_approvals", arguments: .object([:]))
    #expect(pending.texts.joined().contains(approval))

    let approved = try await session.callTool(name: "approve", arguments: .object([
        "approvalId": .string(approval),
        "approverId": .string("ada"),
        "authLevel": .string(AuthenticationLevel.devicePasscode.rawValue),
        "conversationId": .string(conversation),
    ]))
    #expect(approved.isError == false)
    #expect(approved.texts.joined().contains("completed"))
    #expect(await calls.count == 1)
    let exported = try await session.callTool(name: "export_audit", arguments: .object([:]))
    #expect(exported.isError == false)
    #expect(exported.texts.joined().contains("approval.resolved"))
    #expect(!exported.texts.joined().contains("wire it"))
    await session.close()
    await host.stop()
}

@Test func stdioFixtureDoesNotJournalTheEnvSecret() async throws {
    let binary = try fixtureBinary()
    let secret = "mcp-stdio-secret-value"
    let config = MCPServerConfig(
        name: "fixture",
        transport: "stdio",
        command: binary,
        envSecrets: ["FIXTURE_TOKEN": "fixture-token"],
        allow: ["echo"],
        timeoutSeconds: 5
    )
    let session = try await MCPClientSession.connect(config, secrets: DictionarySecrets(["fixture-token": secret]))
    // The fixture is an SDK server, so the discover probe falls back to the legacy handshake.
    #expect(await session.protocolVersion == MCPProtocol.legacy)
    let listed = try await session.listTools()
    #expect(listed.contains { $0.name == "echo" && $0.hints.readOnlyHint == true })
    let tools = try MCPToolBridge.makeTools(config: config, listed: listed, caller: session)
    let store = InMemoryEventStore()
    let engine = try await Engine(store: store, tools: tools, leaseTTL: .seconds(3600))
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "echo",
        script: Script(steps: [
            .tool(name: "mcp.fixture.echo", callID: "c1", arguments: .object(["text": .string("hello")])),
            .finish("done"),
        ])
    ))
    #expect(result.runStatus == .completed)
    let blob = try await store.readAll().map { $0.payload.canonicalJSON() }.joined(separator: "\n")
    #expect(blob.contains("hello present"))
    #expect(!blob.contains(secret))
    #expect(!blob.contains("fixture-token"))
    await session.close()
}

@Test func streamableHTTPPostsJSONAndKeepsTheHeaderSecretOutOfTheLog() async throws {
    let secret = "mcp-http-header-secret"
    let store = InMemoryEventStore()
    let engine = try await Engine(
        store: store,
        model: ScriptedModelStep(steps: [.finish("done")]),
        leaseTTL: .seconds(3600)
    )
    let host = DurableMCPServer(engine: engine, store: store, approverIDs: [])
    try await host.prepareHTTP()
    let refused = await host.handleHTTP(HTTPRequest(method: "GET"))
    #expect(refused.statusCode == 405)
    let loop = MCPLoopback { request in
        await host.handleHTTP(request)
    }
    let port = try loop.start()
    let session = try await MCPClientSession.http(
        endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!,
        headers: ["X-MCP-Auth": secret],
        timeoutSeconds: 5
    )
    let started = try await session.callTool(
        name: "start_run",
        arguments: .object(["requestId": .string("r1"), "text": .string("status please")])
    )
    #expect(started.isError == false)
    #expect(started.texts.joined().contains("completed"))
    #expect(await session.protocolVersion == MCPProtocol.modern)
    let raw = loop.recorded().joined()
    #expect(raw.lowercased().contains("x-mcp-auth: \(secret)"))
    #expect(raw.lowercased().contains("mcp-method: tools/call"))
    #expect(raw.lowercased().contains("mcp-name: start_run"))
    let blob = try await store.readAll().map { $0.payload.canonicalJSON() }.joined(separator: "\n")
    #expect(blob.contains("status please"))
    #expect(!blob.contains(secret))
    await session.close()
    await host.stop()
    loop.stop()
}

@Test func stdioSpeaksTheModernProtocolToAModernServer() async throws {
    let binary = try fixtureBinary()
    let config = MCPServerConfig(
        name: "modern",
        transport: "stdio",
        command: binary,
        args: ["--modern"],
        allow: ["echo"],
        timeoutSeconds: 5
    )
    let session = try await MCPClientSession.connect(config, secrets: DictionarySecrets([:]))
    #expect(await session.protocolVersion == MCPProtocol.modern)
    #expect(try await session.describe().serverName == "mcp-fixture-modern")
    let listed = try await session.listTools()
    let tools = try MCPToolBridge.makeTools(config: config, listed: listed, caller: session)
    let store = InMemoryEventStore()
    let engine = try await Engine(store: store, tools: tools, leaseTTL: .seconds(3600))
    let result = try await engine.submit(Submission(
        requestID: "r1",
        text: "echo",
        script: Script(steps: [
            .tool(name: "mcp.modern.echo", callID: "c1", arguments: .object(["text": .string("hi")])),
            .finish("done"),
        ])
    ))
    #expect(result.runStatus == .completed)
    let blob = try await store.readAll().map { $0.payload.canonicalJSON() }.joined(separator: "\n")
    #expect(blob.contains("hi modern key=dak-"))
    await session.close()

    let legacyOnly = MCPServerConfig(name: "modern", transport: "stdio", command: binary, args: ["--modern"], allow: ["echo"], timeoutSeconds: 5, protocolVersion: .modern)
    let pinned = try await MCPClientSession.connect(legacyOnly, secrets: DictionarySecrets([:]))
    #expect(await pinned.protocolVersion == MCPProtocol.modern)
    await pinned.close()
}

private struct DictionarySecrets: MCPSecretStore {
    var values: [String: String]

    init(_ values: [String: String]) {
        self.values = values
    }

    func secret(account: String) async throws -> String? {
        values[account]
    }
}

private struct StaticCaller: MCPToolCaller {
    var texts: [String]

    func callTool(name: String, arguments: JSONValue) async throws -> MCPToolOutput {
        MCPToolOutput(texts: texts, isError: false)
    }
}

private struct SlowCaller: MCPToolCaller {
    func callTool(name: String, arguments: JSONValue) async throws -> MCPToolOutput {
        try await Task.sleep(for: .seconds(5))
        return MCPToolOutput(texts: ["late"], isError: false)
    }
}

private actor CrashFlag {
    private var armed = true

    func consume() -> Bool {
        if armed {
            armed = false
            return true
        }
        return false
    }
}

private struct CrashAfter: MCPToolCaller {
    var inner: MCPClientSession
    var flag: CrashFlag

    func callTool(name: String, arguments: JSONValue) async throws -> MCPToolOutput {
        let output = try await inner.callTool(name: name, arguments: arguments)
        if await flag.consume() {
            throw SimulatedProcessCrash()
        }
        return output
    }
}

private actor LocalCalls {
    private var calls = 0

    func bump() {
        calls += 1
    }

    var count: Int { calls }
}

private actor DemoCalls {
    private var names: [String] = []

    func bump(_ name: String) {
        names.append(name)
    }

    func count(_ name: String) -> Int {
        names.filter { $0 == name }.count
    }
}

private struct DemoServer {
    var server: Server
    var session: MCPClientSession
    var calls: DemoCalls

    static func make() async throws -> DemoServer {
        let calls = DemoCalls()
        let server = Server(
            name: "demo",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        let schema = Value.object([
            "properties": .object(["text": .object(["type": .string("string")])]),
            "type": .string("object"),
        ])
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [
                Tool(name: "lookup", description: "Read a record", inputSchema: schema, annotations: .init(readOnlyHint: true)),
                Tool(name: "wipe", description: "Delete records", inputSchema: schema, annotations: .init(destructiveHint: true)),
                Tool(name: "charge", description: "Charge a card", inputSchema: schema, annotations: .init(destructiveHint: true)),
                Tool(name: "hidden", description: "Not on the allowlist", inputSchema: schema, annotations: .init(readOnlyHint: true)),
            ])
        }
        await server.withMethodHandler(CallTool.self) { params in
            await calls.bump(params.name)
            let text = params.arguments?["text"]?.stringValue ?? params.name
            return CallTool.Result(
                content: [.text(text: text, annotations: nil, _meta: nil)],
                isError: false
            )
        }
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let session = try await MCPClientSession.connected(clientTransport)
        return DemoServer(server: server, session: session, calls: calls)
    }
}

private func fixtureBinary() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    // Search every build directory (`.build`, or a `--build-path` like `.build-x`) and take the newest
    // fixture, so a test run does not pick up a stale binary from another build path.
    let builds = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix(".build") }
    var candidates: [URL] = []
    for build in builds {
        // `debug` (and `<triple>/debug` on Linux), or `out/Products/Debug` with the Xcode build system.
        candidates.append(build.appendingPathComponent("debug/mcp-fixture"))
        candidates.append(build.appendingPathComponent("out/Products/Debug/mcp-fixture"))
        for child in (try? FileManager.default.contentsOfDirectory(at: build, includingPropertiesForKeys: nil)) ?? [] {
            candidates.append(child.appendingPathComponent("debug/mcp-fixture"))
        }
    }
    var newest: (URL, Date)?
    for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)[.modificationDate] as? Date) ?? .distantPast
        if newest == nil || modified > newest!.1 {
            newest = (url, modified)
        }
    }
    guard let newest else {
        throw MCPCallError("mcp-fixture binary was not built")
    }
    return newest.0.path
}

private final class MCPLoopback: @unchecked Sendable {
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var requests: [String] = []
    private var thread: Thread?

    init(_ handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.handler = handler
    }

    func start() throws -> Int {
        #if canImport(Glibc) || canImport(Musl)
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
        #if canImport(Glibc) || canImport(Musl)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw MCPCallError("socket") }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                bind(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            closeSocket(fd)
            throw MCPCallError("bind")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                getsockname(fd, sock, &length)
            }
        }
        guard named == 0 else {
            closeSocket(fd)
            throw MCPCallError("getsockname")
        }
        let port = Int(UInt16(bigEndian: actual.sin_port))
        lock.lock()
        listenFD = fd
        running = true
        lock.unlock()
        let thread = Thread { [weak self] in
            self?.serve()
        }
        thread.start()
        self.thread = thread
        return port
    }

    func stop() {
        lock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            closeSocket(fd)
        }
    }

    func recorded() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private func serve() {
        while true {
            lock.lock()
            let keep = running
            let fd = listenFD
            lock.unlock()
            if !keep || fd < 0 { return }
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            guard let raw = readRequest(client) else {
                closeSocket(client)
                continue
            }
            lock.lock()
            requests.append(raw)
            lock.unlock()
            let http = parse(raw)
            let box = ResponseBox()
            let semaphore = DispatchSemaphore(value: 0)
            let handler = self.handler
            Task {
                box.response = await handler(http)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)
            let payload = box.response.map(wire) ?? Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            _ = payload.withUnsafeBytes { pointer in
                send(client, pointer.baseAddress, pointer.count, sendFlags)
            }
            closeSocket(client)
        }
    }

    private func parse(_ raw: String) -> HTTPRequest {
        let lines = httpLines(raw)
        let head = lines.first ?? "POST /mcp HTTP/1.1"
        let method = head.split(separator: " ").first.map(String.init) ?? "POST"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let split = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<split])
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let body = httpBody(raw).data(using: .utf8)
        return HTTPRequest(method: method, headers: headers, body: body, path: "/mcp")
    }

    private func wire(_ response: HTTPResponse) -> Data {
        let body = response.bodyData ?? Data()
        var headers = response.headers
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        var text = "HTTP/1.1 \(response.statusCode) OK\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    private func readRequest(_ client: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let marker = Array("\r\n\r\n".utf8)
        while data.count < 1_000_000 {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(client, base, raw.count, 0)
            }
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if let end = indexAfterMarker(data, marker: marker) {
                let header = String(decoding: data[..<(data.startIndex + (end - marker.count))], as: UTF8.self)
                let length = contentLength(header)
                if data.count >= end + length {
                    return String(decoding: data.prefix(end + length), as: UTF8.self)
                }
            }
        }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }

    private func indexAfterMarker(_ data: Data, marker: [UInt8]) -> Int? {
        guard data.count >= marker.count else { return nil }
        let bytes = Array(data)
        var index = 0
        while index + marker.count <= bytes.count {
            if Array(bytes[index..<(index + marker.count)]) == marker {
                return index + marker.count
            }
            index += 1
        }
        return nil
    }

    private func contentLength(_ header: String) -> Int {
        for line in httpLines(header) {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    private func httpLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                if !current.isEmpty { lines.append(current) }
                current = ""
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private func httpBody(_ raw: String) -> String {
        let marker = "\r\n\r\n"
        guard let range = raw.range(of: marker) else { return "" }
        return String(raw[range.upperBound...])
    }

    private var sendFlags: Int32 {
        #if canImport(Glibc) || canImport(Musl)
        Int32(MSG_NOSIGNAL)
        #else
        0
        #endif
    }

    private func closeSocket(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #elseif canImport(Musl)
        _ = Musl.close(fd)
        #else
        _ = Darwin.close(fd)
        #endif
    }
}

private final class ResponseBox: @unchecked Sendable {
    var response: HTTPResponse?
}
