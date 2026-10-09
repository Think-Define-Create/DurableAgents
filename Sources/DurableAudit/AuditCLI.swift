import ArgumentParser
import DurableCore
import DurableStore
import Foundation

@main
struct DurableAudit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "durable-audit",
        abstract: "Verify the event-log hash chain and export an audit trail.",
        subcommands: [Tip.self, Verify.self, Export.self]
    )
}

struct DatabaseOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the SQLite event log.")
    var database: String
}

struct Tip: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the hash-chain tip of the stored log.")

    @OptionGroup var database: DatabaseOptions

    func run() async throws {
        let report = try await AuditCommands.inspect(path: database.database)
        print(report.tip)
        if !report.intact {
            throw ExitCode.failure
        }
    }
}

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check sequence integrity and, when --expect is set, the hash-chain tip."
    )

    @OptionGroup var database: DatabaseOptions

    @Option(name: .long, help: "Tip previously printed by the tip command.")
    var expect: String?

    func run() async throws {
        let report = try await AuditCommands.inspect(path: database.database)
        print("events \(report.eventCount)")
        print("tip \(report.tip)")
        for problem in report.problems {
            FileHandle.standardError.write(Data("\(problem)\n".utf8))
        }
        if !report.intact {
            throw ExitCode.failure
        }
        if let expect, expect != report.tip {
            FileHandle.standardError.write(Data("tip does not match --expect\n".utf8))
            throw ExitCode.failure
        }
    }
}

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export effect intents, results, and approvals. Payloads are not included."
    )

    @OptionGroup var database: DatabaseOptions

    @Option(name: .long, help: "jsonl or csv.")
    var format: AuditFormat = .jsonl

    func run() async throws {
        let events = try await AuditCommands.events(path: database.database)
        switch format {
        case .jsonl:
            print(AuditExport.jsonl(events))
        case .csv:
            print(AuditExport.csv(events))
        }
    }
}

enum AuditFormat: String, ExpressibleByArgument {
    case jsonl
    case csv
}

enum AuditCommands {
    static func events(path: String) async throws -> [EventEnvelope] {
        let store = try SQLiteEventStore(path: path)
        return try await store.readAll()
    }

    static func inspect(path: String) async throws -> ChainReport {
        EventHashChain.inspect(try await events(path: path))
    }
}
