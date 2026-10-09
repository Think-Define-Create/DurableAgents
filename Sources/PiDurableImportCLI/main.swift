import ArgumentParser
import DurableCore
import DurableStore
import Foundation
import PiDurableImport

@main
struct PiDurableImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pi-durable-import",
        abstract: "Copy a pi-durable SQLite database into a DurableAgents event log."
    )

    @Option(name: .long, help: "Path to the pi-durable SQLite file.")
    var source: String

    @Option(name: .long, help: "Path to the DurableAgents SQLite event log to create or append to.")
    var destination: String

    func run() async throws {
        let store = try SQLiteEventStore(path: destination)
        let report = try await PiDurableImporter.importDatabase(source: source, into: store)
        print(report.text)
        if !report.losses.isEmpty {
            FileHandle.standardError.write(Data("import is lossy; see the loss lines above\n".utf8))
        }
    }
}
