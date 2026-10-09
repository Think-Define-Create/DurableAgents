import DurableCore
import DurableStore
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Test func durableAuditVerifiesTipAndExportsWithoutSecrets() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("durable-audit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = directory.appendingPathComponent("events.sqlite").path
    let store = try SQLiteEventStore(path: database)
    let tool = Tool(name: "echo", effect: .pure) { _, _ in
        ToolReturn(output: .string("ok"))
    }
    let engine = try await Engine(
        store: store,
        tools: [tool],
        leaseTTL: .seconds(3600)
    )
    _ = try await engine.submit(Submission(
        requestID: "r1",
        text: "hide sk-audit-secret",
        script: Script(steps: [
            .tool(name: "echo", callID: "c1", arguments: .object(["body": .string("sk-audit-secret")])),
            .finish("done"),
        ])
    ))
    await engine.close()

    let binary = try auditBinary()
    let tip = try runAudit(binary, ["tip", "--database", database])
    let trimmed = tip.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(trimmed.isEmpty == false)

    let verified = try runAudit(binary, ["verify", "--database", database, "--expect", trimmed])
    #expect(verified.status == 0)
    #expect(verified.stdout.contains("tip \(trimmed)"))

    let mismatch = try runAudit(binary, ["verify", "--database", database, "--expect", "not-the-tip"])
    #expect(mismatch.status != 0)

    let exported = try runAudit(binary, ["export", "--database", database, "--format", "jsonl"])
    #expect(exported.status == 0)
    #expect(exported.stdout.contains("effect.intent"))
    #expect(exported.stdout.contains("sk-audit-secret") == false)
    #expect(exported.stdout.contains("hide sk-audit-secret") == false)
}

private struct AuditOutput {
    var status: Int32
    var stdout: String
    var stderr: String
}

private func runAudit(_ binary: String, _ arguments: [String]) throws -> AuditOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return AuditOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

private func auditBinary() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let build = root.appendingPathComponent(".build")
    guard let enumerator = FileManager.default.enumerator(at: build, includingPropertiesForKeys: nil) else {
        throw DurableError.invariant("missing .build")
    }
    var found: String?
    for case let url as URL in enumerator {
        if url.lastPathComponent == "durable-audit", !url.hasDirectoryPath, !url.path.contains(".dSYM") {
            found = url.path
            break
        }
    }
    return try #require(found)
}
