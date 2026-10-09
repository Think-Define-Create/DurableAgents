@testable import DurableCore
import DurableStore
import Foundation
import DurableImport
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Test func piDurableImportMapsTranscriptsAndReportsLosses() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("pi.sqlite").path
    let destination = directory.appendingPathComponent("events.sqlite").path
    try writeSQLite(source, sql: fixtureSQL)

    let store = try SQLiteEventStore(path: destination)
    let report = try await DurableImporter.importDatabase(source: source, into: store)
    #expect(report.conversations == 2)
    #expect(report.entries == 6)
    #expect(report.losses.contains { $0.code == "live-task" })
    #expect(report.losses.contains { $0.code == "chord-delta" })
    #expect(report.losses.contains { $0.code == "image" })
    #expect(report.losses.contains { $0.code == "fork-pointer" })
    #expect(report.losses.contains { $0.code == "effects" })

    let events = try await store.readAll()
    let opened = events.filter { $0.type == EventType.conversationOpened }
    #expect(opened.count == 2)
    #expect(opened.contains { $0.payload["forkedFrom"]?.stringValue == "pi:1" })
    let messages = try events.compactMap { try EventCodec.transcriptMessage($0) }
    #expect(messages.contains { $0.role == "user" && $0.text == "Look up 14 Harbor Lane" })
    #expect(messages.contains { $0.role == "assistant" && $0.text == "Checking." })
    #expect(messages.contains { $0.role == "tool" && $0.text == "active" && $0.callID == "call_1" })
    let toolNote = try #require(events.first {
        $0.type == EventType.importNote && $0.payload["subject"]?.stringValue == "toolCall"
    })
    #expect(toolNote.payload["tool"]?.stringValue == "lookupProperty")
    #expect(toolNote.payload["arguments"]?["query"]?.stringValue == "14 Harbor Lane")
    #expect(events.contains { $0.type == EventType.contextCompacted && $0.payload["throughMessageID"]?.stringValue == "pi:3" })
    #expect(events.contains { $0.type == EventType.importNote && $0.payload["subject"]?.stringValue == "system" })
    let task = try #require(events.first {
        $0.type == EventType.importNote && $0.payload["subject"]?.stringValue == "task" && $0.payload["status"]?.stringValue == "running"
    })
    #expect(task.payload["kind"]?.stringValue == "pi.generation")
    #expect(events.map { $0.payload.canonicalJSON() }.joined().contains("Bearer sk-") == false)

    let folded = try Projection.fold(events)
    #expect(folded.conversations["pi:1"]?.messages.contains { $0.text == "Checking." } == true)
}

@Test func newerPiDurableSchemaIsRejected() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-import-new-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("pi.sqlite").path
    try writeSQLite(source, sql: """
        CREATE TABLE durable_schema (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          version INTEGER NOT NULL
        );
        INSERT INTO durable_schema (singleton, version) VALUES (1, 2);
        """)
    let store = InMemoryEventStore(storeID: "import")
    await #expect(throws: ImportError.self) {
        try await DurableImporter.importDatabase(source: source, into: store)
    }
}

@Test func piDurableImportCLIPrintsTheLossReport() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-import-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("pi.sqlite").path
    let destination = directory.appendingPathComponent("events.sqlite").path
    try writeSQLite(source, sql: fixtureSQL)
    let binary = try importBinary()
    let output = try runImport(binary, ["--source", source, "--destination", destination])
    #expect(output.status == 0)
    #expect(output.stdout.contains("live-task"))
    #expect(output.stdout.contains("conversations 2"))
    #expect(output.stdout.contains("sk-") == false)
}

private func writeSQLite(_ path: String, sql: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [path]
    let input = Pipe()
    process.standardInput = input
    process.standardError = Pipe()
    try process.run()
    input.fileHandleForWriting.write(Data(sql.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

private struct ImportOutput {
    var status: Int32
    var stdout: String
}

private func runImport(_ binary: String, _ arguments: [String]) throws -> ImportOutput {
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
    return ImportOutput(status: process.terminationStatus, stdout: stdout)
}

private func importBinary() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let build = root.appendingPathComponent(".build")
    guard let enumerator = FileManager.default.enumerator(at: build, includingPropertiesForKeys: nil) else {
        throw ImportError.schema("missing .build")
    }
    for case let url as URL in enumerator {
        if url.lastPathComponent == "durable-import", !url.hasDirectoryPath, !url.path.contains(".dSYM") {
            return url.path
        }
    }
    throw ImportError.schema("durable-import binary was not built")
}

private let fixtureSQL = """
CREATE TABLE durable_schema (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  version INTEGER NOT NULL CHECK (version >= 0)
) STRICT;
INSERT INTO durable_schema (singleton, version) VALUES (1, 1);
CREATE TABLE durable_metadata (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  next_id TEXT NOT NULL,
  next_seq INTEGER NOT NULL
) STRICT;
INSERT INTO durable_metadata (singleton, next_id, next_seq) VALUES (1, '20', 10);
CREATE TABLE record_ids (
  id INTEGER PRIMARY KEY,
  record_type TEXT NOT NULL CHECK (record_type IN ('conversation', 'entry', 'task', 'submission', 'document'))
) STRICT;
INSERT INTO record_ids (id, record_type) VALUES (1, 'conversation'), (2, 'conversation');
CREATE TABLE conversations (
  id INTEGER PRIMARY KEY,
  owner_conversation_id INTEGER,
  owner_task_id INTEGER,
  record TEXT NOT NULL CHECK (json_valid(record))
) STRICT;
INSERT INTO conversations (id, owner_conversation_id, owner_task_id, record) VALUES
  (1, NULL, NULL, '{"id":"1"}'),
  (2, 1, NULL, '{"id":"2"}');
CREATE TABLE entries (
  id INTEGER PRIMARY KEY,
  conversation_id INTEGER NOT NULL,
  head INTEGER,
  commit_seq INTEGER NOT NULL,
  record TEXT NOT NULL CHECK (json_valid(record))
) STRICT;
INSERT INTO entries (id, conversation_id, head, commit_seq, record) VALUES
  (1, 1, NULL, 1, '{"id":"1","conversationId":"1","kind":"pi.user","model":[{"role":"user","content":"Look up 14 Harbor Lane","timestamp":1}]}'),
  (2, 1, NULL, 2, '{"id":"2","conversationId":"1","kind":"pi.assistant","model":[{"role":"assistant","content":[{"type":"text","text":"Checking."},{"type":"thinking","thinking":"private"},{"type":"toolCall","id":"call_1","name":"lookupProperty","arguments":{"query":"14 Harbor Lane"}},{"type":"image","data":"abc","mimeType":"image/png"}],"stopReason":"toolUse","timestamp":2}]}'),
  (3, 1, NULL, 3, '{"id":"3","conversationId":"1","kind":"pi.tool-result","model":[{"role":"toolResult","toolCallId":"call_1","toolName":"lookupProperty","content":[{"type":"text","text":"active"}],"isError":false,"timestamp":3}]}'),
  (4, 1, 3, 4, '{"id":"4","conversationId":"1","kind":"pi.compaction","head":"3","model":[{"role":"user","content":"Earlier notes were folded.","timestamp":4}],"data":{"reason":"threshold"}}'),
  (5, 1, NULL, 5, '{"id":"5","conversationId":"1","kind":"pi.system","model":[{"role":"system","content":"","timestamp":5}]}'),
  (6, 2, NULL, 6, '{"id":"6","conversationId":"2","kind":"pi.user","model":[{"role":"user","content":"Continue from the fork","timestamp":6}]}');
CREATE TABLE tasks (
  id INTEGER PRIMARY KEY,
  conversation_id INTEGER NOT NULL,
  kind TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'waiting', 'completing', 'terminal')),
  abort_requested INTEGER NOT NULL CHECK (abort_requested IN (0, 1)),
  background INTEGER NOT NULL CHECK (background IN (0, 1)),
  record TEXT NOT NULL CHECK (json_valid(record))
) STRICT;
INSERT INTO tasks (id, conversation_id, kind, status, abort_requested, background, record) VALUES
  (10, 1, 'pi.tool', 'terminal', 0, 0, '{"id":"10","kind":"pi.tool","version":1,"status":"terminal"}'),
  (11, 1, 'pi.generation', 'running', 0, 0, '{"id":"11","kind":"pi.generation","version":1,"state":{"status":"running","checkpoint":{"phase":"stream"}},"memos":{"authorization":"Bearer sk-not-a-header"}}');
CREATE TABLE submissions (
  id INTEGER PRIMARY KEY,
  conversation_id INTEGER NOT NULL,
  request_id TEXT,
  status TEXT NOT NULL CHECK (status IN ('queued', 'placed', 'done', 'unanswered')),
  record TEXT NOT NULL CHECK (json_valid(record))
) STRICT;
INSERT INTO submissions (id, conversation_id, request_id, status, record) VALUES
  (12, 1, 'req-1', 'done', '{"id":"12","status":"done","requestId":"req-1"}');
CREATE TABLE documents (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,
  family INTEGER NOT NULL CHECK (family IN (0, 1)),
  key_value TEXT NOT NULL,
  scope_kind TEXT NOT NULL CHECK (scope_kind IN ('session', 'conversation', 'task')),
  owner_id INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  retired_at INTEGER,
  record TEXT NOT NULL CHECK (json_valid(record))
) STRICT;
INSERT INTO documents (id, kind, family, key_value, scope_kind, owner_id, created_at, retired_at, record) VALUES
  (13, 'pi.usage', 0, '', 'conversation', 1, 1, NULL, '{"id":"13","kind":"pi.usage"}');
CREATE TABLE document_revisions (
  document_id INTEGER NOT NULL,
  seq INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('base', 'delta')),
  version INTEGER NOT NULL,
  content TEXT NOT NULL CHECK (json_valid(content)),
  PRIMARY KEY (document_id, seq)
) STRICT;
INSERT INTO document_revisions (document_id, seq, kind, version, content) VALUES
  (13, 1, 'base', 1, '{"tokens":1}'),
  (13, 2, 'delta', 1, '{"op":"replace"}');
"""
