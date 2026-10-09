import DurableCore
import DurableStore
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Child process used by the crash and restart tests.
///
/// `seed-crash` commits a tool intent, writes an external receipt, then SIGKILLs
/// itself before the result event. `seed-approval` suspends and exits cleanly.
/// `resume-approval` opens that same database and resumes.
@main
struct CrashProbe {
    static func main() async {
        do {
            try await run(parse())
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("crash-probe: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ arguments: Arguments) async throws {
        let store = try SQLiteEventStore(path: arguments.database)
        switch arguments.command {
        case "seed-crash":
            guard let effects = arguments.effects else { throw UsageError() }
            try await seedCrash(store: store, effects: effects)
        case "seed-approval":
            try await seedApproval(store: store)
        case "resume-approval":
            guard let tokenRaw = arguments.token, let token = ResumeToken(raw: tokenRaw) else {
                throw UsageError()
            }
            try await resumeApproval(store: store, token: token)
        default:
            throw UsageError()
        }
    }

    private static func seedCrash(store: SQLiteEventStore, effects: String) async throws {
        let effectsURL = URL(fileURLWithPath: effects, isDirectory: true)
        let tool = Tool(name: "wire", effect: .external, reconcile: { _, _ in
            .unknown(reason: "seed process has no reconcile path")
        }) { _, context in
            try FileManager.default.createDirectory(at: effectsURL, withIntermediateDirectories: true)
            let receipt = effectsURL.appendingPathComponent(context.key.fileToken)
            try Data("sent".utf8).write(to: receipt, options: .atomic)
            try FileHandle.standardOutput.write(contentsOf: Data("INTENT_COMMITTED \(context.key.raw)\n".utf8))
            kill(getpid(), SIGKILL)
            return ToolReturn(output: .string("sent"))
        }
        let engine = try await Engine(store: store, tools: [tool], leaseTTL: .seconds(300))
        _ = try await engine.submit(Submission(
            requestID: "crash-1",
            text: "Send the wire",
            script: Script(steps: [
                .tool(name: "wire", callID: "call-wire", arguments: .object(["amount": .string("10")])),
                .finish("done"),
            ])
        ))
        throw ProbeError("seed-crash returned; the process should have been killed inside the tool")
    }

    private static func seedApproval(store: SQLiteEventStore) async throws {
        let engine = try await Engine(store: store, tools: [], leaseTTL: .seconds(300))
        let result = try await engine.submit(Submission(
            requestID: "approval-1",
            text: "Send the wire after a human says yes",
            script: Script(steps: [
                .assistant("I need approval before sending."),
                .approval(id: "wire-ok", prompt: "Send the wire?"),
                .finish("wire-approved"),
            ])
        ))
        guard let token = result.resumeToken else {
            throw ProbeError("seed-approval did not suspend, status \(String(describing: result.runStatus))")
        }
        try FileHandle.standardOutput.write(contentsOf: Data("SUSPENDED \(token.raw)\n".utf8))
        await engine.close()
    }

    private static func resumeApproval(store: SQLiteEventStore, token: ResumeToken) async throws {
        let engine = try await Engine(store: store, tools: [], leaseTTL: .seconds(300))
        let recovered = try await engine.recover()
        guard recovered.contains(where: { $0.resumeToken == token && $0.runStatus == .suspended }) else {
            throw ProbeError("resume-approval did not find a suspended run: \(recovered)")
        }
        let result = try await engine.resume(token: token, decision: .approved)
        guard result.runStatus == .completed, result.finalText == "wire-approved" else {
            throw ProbeError("resume finished as \(result.runStatus) text \(result.finalText ?? "")")
        }
        try FileHandle.standardOutput.write(contentsOf: Data("COMPLETED \(result.finalText ?? "")\n".utf8))
        await engine.close()
    }
}

private struct Arguments {
    var command: String
    var database: String
    var effects: String?
    var token: String?
}

private func parse() throws -> Arguments {
    var argv = Array(CommandLine.arguments.dropFirst())
    guard let command = argv.first else { throw UsageError() }
    argv.removeFirst()
    var database: String?
    var effects: String?
    var token: String?
    var index = 0
    while index < argv.count {
        let flag = argv[index]
        index += 1
        guard index < argv.count else { throw UsageError() }
        let value = argv[index]
        index += 1
        switch flag {
        case "--database":
            database = value
        case "--effects":
            effects = value
        case "--token":
            token = value
        default:
            throw UsageError()
        }
    }
    guard let database else { throw UsageError() }
    return Arguments(command: command, database: database, effects: effects, token: token)
}

private struct UsageError: Error, CustomStringConvertible {
    var description: String {
        "usage: CrashProbe seed-crash|seed-approval|resume-approval --database PATH [--effects PATH] [--token TOKEN]"
    }
}

private struct ProbeError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
