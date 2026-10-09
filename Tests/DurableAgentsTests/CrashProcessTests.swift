import DurableCore
import DurableStore
import Foundation
import Testing

@Test func sigkillMidToolRecoversInAFreshProcess() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("durable-sigkill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = root.appendingPathComponent("events.sqlite")
    let effects = root.appendingPathComponent("effects", isDirectory: true)
    let probe = try crashProbeURL()

    let seeded = try runProbe(probe, arguments: [
        "seed-crash",
        "--database", database.path,
        "--effects", effects.path,
    ])
    #expect(seeded.output.contains("INTENT_COMMITTED"))
    if !wasKilled(seeded) {
        Issue.record("probe exited \(seeded.status) reason \(seeded.reason) output:\n\(seeded.output)")
    }
    #expect(wasKilled(seeded))

    let receipts = try FileManager.default.contentsOfDirectory(at: effects, includingPropertiesForKeys: nil)
    #expect(receipts.count == 1)
    let receiptText = try String(contentsOf: try #require(receipts.first), encoding: .utf8)
    #expect(receiptText == "sent")

    let store = try SQLiteEventStore(path: database.path)
    let before = try await store.readAll()
    #expect(before.contains { $0.type == EventType.effectIntent })
    #expect(!before.contains { $0.type == EventType.effectResult })

    let tool = Tool(name: "wire", effect: .external, reconcile: { key, _ in
        let receipt = effects.appendingPathComponent(key.fileToken)
        guard FileManager.default.fileExists(atPath: receipt.path) else {
            return .notDone
        }
        let text = try String(contentsOf: receipt, encoding: .utf8)
        return .done(.string(text))
    }) { _, _ in
        let marker = effects.appendingPathComponent("reran")
        try Data("reran".utf8).write(to: marker)
        return ToolReturn(output: .string("reran"))
    }

    let engine = try await Engine(store: store, tools: [tool])
    let actions = try await engine.recover()
    let action = try #require(actions.first)
    #expect(action.runStatus == .completed)
    #expect(action.finalText == "done")

    let events = try await store.readAll()
    let result = try requireResult(in: events)
    #expect(result.payload["output"]?.stringValue == "sent")
    #expect(result.payload["reconciled"]?.boolValue == true)
    #expect(result.payload["replayed"]?.boolValue == false)
    #expect(!FileManager.default.fileExists(atPath: effects.appendingPathComponent("reran").path))
    let afterReceipts = try FileManager.default.contentsOfDirectory(at: effects, includingPropertiesForKeys: nil)
    #expect(afterReceipts.count == 1)
    await engine.close()
}

@Test func approvalSuspendSurvivesProcessRestart() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("durable-approval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = root.appendingPathComponent("events.sqlite")
    let probe = try crashProbeURL()

    let seeded = try runProbe(probe, arguments: [
        "seed-approval",
        "--database", database.path,
    ])
    if seeded.status != 0 {
        Issue.record("seed-approval exited \(seeded.status): \(seeded.output)")
    }
    #expect(seeded.status == 0)
    let tokenLine = try #require(seeded.output.split(separator: "\n").first { $0.hasPrefix("SUSPENDED ") })
    let token = String(tokenLine.dropFirst("SUSPENDED ".count))
    #expect(ResumeToken(raw: token) != nil)

    let resumed = try runProbe(probe, arguments: [
        "resume-approval",
        "--database", database.path,
        "--token", token,
    ])
    if resumed.status != 0 {
        Issue.record("resume-approval exited \(resumed.status): \(resumed.output)")
    }
    #expect(resumed.status == 0)
    #expect(resumed.output.contains("COMPLETED wire-approved"))

    let store = try SQLiteEventStore(path: database.path)
    let events = try await store.readAll()
    #expect(events.contains { $0.type == EventType.approvalRequested })
    #expect(events.contains { $0.type == EventType.approvalResolved })
    #expect(events.contains { $0.type == EventType.runCompleted && $0.payload["finalText"]?.stringValue == "wire-approved" })
}

private struct ProbeRun {
    var status: Int32
    var reason: Process.TerminationReason
    var output: String
}

private func runProbe(_ executable: URL, arguments: [String]) throws -> ProbeRun {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: data, as: UTF8.self)
    return ProbeRun(status: process.terminationStatus, reason: process.terminationReason, output: output)
}

private func wasKilled(_ run: ProbeRun) -> Bool {
    if run.reason == .uncaughtSignal && (run.status == SIGKILL || run.status == 9) {
        return true
    }
    return run.status == 9 || run.status == 137
}

/// On macOS, Swift Testing runs under `swiftpm-testing-helper`, so also look in the package's `.build`.
private func crashProbeURL() throws -> URL {
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    for _ in 0..<8 {
        url.deleteLastPathComponent()
        let candidate = url.appendingPathComponent("CrashProbe")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    let build = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build")
    for configuration in ["debug", "release"] {
        let candidate = build.appendingPathComponent(configuration).appendingPathComponent("CrashProbe")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    throw ProbeMissing("CrashProbe not found from \(CommandLine.arguments[0])")
}

private struct ProbeMissing: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
