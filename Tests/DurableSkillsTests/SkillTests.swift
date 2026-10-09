import DurableCore
import DurableSkills
import DurableStore
import Foundation
import Testing

@Test func theParserWarnsAndNeverMarksAScriptExecutable() {
    let long = String(repeating: "d", count: 1100)
    let markdown = """
    ---
    name: Not A Slug
    description: \(long)
    license: MIT
    metadata:
      owner: local
    allowed-tools: web.fetch notes.reminder
    ---
    Use the forecast. SECRET_BODY
    """
    let parsed = SkillParser.parse(
        directoryName: "weather",
        markdown: markdown,
        files: ["scripts/run.sh": "echo hi", "references/places.md": "Paris"]
    )
    #expect(!parsed.warnings.isEmpty)
    #expect(parsed.executable == false)
    #expect(parsed.scripts == ["scripts/run.sh"])
    #expect(parsed.metadata["owner"] == "local")
    #expect(parsed.narrowed(["web.fetch", "calendar.write", "shell"]) == ["web.fetch"])
    #expect(!parsed.body.isEmpty)
}

@Test func agentEditsStayProposedAndScriptsStayText() async throws {
    let harness = try await open()
    let markdown = """
    ---
    name: weather
    description: Local forecast
    allowed-tools: web.fetch
    ---
    SECRET_BODY ask the user before leaving the device.
    """
    let installed = try await harness.library.install(
        directoryName: "weather",
        markdown: markdown,
        files: ["scripts/run.sh": "echo no", "references/places.md": "Paris"],
        editor: "user"
    )
    #expect(installed.approvedByUser)
    #expect(installed.executable == false)
    let block = try await harness.library.metadataBlock()
    #expect(block.contains("weather: Local forecast"))
    #expect(!block.contains("SECRET_BODY"))
    let proposal = try await harness.library.propose(
        directoryName: "weather",
        markdown: markdown.replacingOccurrences(of: "SECRET_BODY", with: "NEW_BODY"),
        author: "agent"
    )
    #expect(try await harness.library.metadataBlock().contains("Local forecast"))
    let applied = try await harness.library.decide(proposalID: proposal.id, approved: true, approver: "user")
    #expect(applied?.version == 2)
    #expect(applied?.body.contains("NEW_BODY") == true)
    let activated = try await harness.library.activate("weather")
    #expect(activated.contentSHA256 == applied?.contentSHA256)
    let script = try await harness.library.readResource("weather", path: "scripts/run.sh")
    #expect(script.text == "echo no")
    #expect(script.executable == false)
    let reverted = try await harness.library.revert(name: "weather", toVersion: 1, editor: "user")
    #expect(reverted.version == 3)
    #expect(reverted.body.contains("SECRET_BODY"))
    let events = try await harness.store.readAll()
    #expect(events.contains { $0.type == EventType.skillActivated && $0.payload["executable"]?.boolValue == false })
    await harness.engine.close()
}

@Test func importingAFolderRoundTripsAndTheToolDoesNotRunTheScript() async throws {
    let harness = try await open()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-\(UUID().uuidString)", isDirectory: true)
    let folder = root.appendingPathComponent("weather", isDirectory: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("references"), withIntermediateDirectories: true)
    let markdown = """
    ---
    name: weather
    description: Local forecast
    ---
    Read the reference.
    """
    try markdown.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try "echo no".write(to: folder.appendingPathComponent("scripts/run.sh"), atomically: true, encoding: .utf8)
    try "Paris".write(to: folder.appendingPathComponent("references/places.md"), atomically: true, encoding: .utf8)
    let installed = try await harness.library.importDirectory(folder, editor: "user")
    #expect(installed.name == "weather")
    #expect(installed.scripts == ["scripts/run.sh"])
    let exported = try await harness.library.exportFolder("weather")
    #expect(exported["SKILL.md"] == markdown)
    #expect(exported["references/places.md"] == "Paris")

    let tools = harness.library.tools()
    await harness.engine.close()
    let engine = try await Engine(
        store: harness.store,
        tools: tools,
        clock: harness.clock,
        leaseTTL: .seconds(3600)
    )
    let result = try await engine.submit(Submission(
        requestID: "skill",
        text: "load",
        script: Script(steps: [
            .tool(name: "skill.activate", callID: "a", arguments: .object(["name": .string("weather")])),
            .tool(name: "skill.read_resource", callID: "b", arguments: .object([
                "name": .string("weather"),
                "path": .string("scripts/run.sh"),
            ])),
            .finish("done"),
        ])
    ))
    #expect(result.runStatus == .completed)
    let events = try await engine.events(for: result.conversationID)
    let outputs = events.filter { $0.type == EventType.effectResult }.compactMap { $0.payload["output"] }
    #expect(outputs.contains { $0["body"]?.stringValue?.contains("Read the reference") == true && $0["executable"]?.boolValue == false })
    #expect(outputs.contains { $0["text"]?.stringValue == "echo no" && $0["executable"]?.boolValue == false })
    await engine.close()
}

private struct Harness {
    var store: InMemoryEventStore
    var clock: ManualClock
    var engine: Engine
    var library: SkillLibrary
}

private func open() async throws -> Harness {
    let clock = ManualClock()
    let store = InMemoryEventStore(clock: clock, liveness: ScriptedLiveness())
    let engine = try await Engine(store: store, clock: clock, leaseTTL: .seconds(3600))
    return Harness(store: store, clock: clock, engine: engine, library: SkillLibrary(engine: engine, store: store, clock: clock))
}
