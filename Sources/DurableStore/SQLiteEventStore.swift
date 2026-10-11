import DurableCore
import Foundation
import GRDB

/// SQLite event log. WAL, `synchronous=FULL`, one lease row, and an epoch that only increases.
///
/// Payloads are canonical JSON text. The schema version is `PRAGMA user_version`.
/// Event payload versions are independent of that and are upcast on read by `EventCodec`.
public final class SQLiteEventStore: EventStore, @unchecked Sendable {
    public let path: String
    private let dbQueue: DatabaseQueue
    private let clock: any StoreClock
    private let liveness: any ProcessLiveness
    private let identifier: String

    public init(
        path: String,
        clock: any StoreClock = SystemClock(),
        liveness: any ProcessLiveness = SystemProcessLiveness()
    ) throws {
        self.path = path
        self.clock = clock
        self.liveness = liveness
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        if directory.path != "/" && directory.path != "." {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            _ = try String.fetchOne(database, sql: "PRAGMA journal_mode = WAL")
            try database.execute(sql: "PRAGMA synchronous = FULL")
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        identifier = try dbQueue.write { database in
            try Self.migrate(database)
            if let existing = try String.fetchOne(
                database,
                sql: "SELECT value FROM meta WHERE key = 'store_id'"
            ) {
                return existing
            }
            let created = UUID().uuidString.lowercased()
            try database.execute(
                sql: "INSERT INTO meta (key, value) VALUES ('store_id', ?)",
                arguments: [created]
            )
            return created
        }
    }

    public func storeID() async throws -> String { identifier }

    public func acquireLease(owner: UUID, pid: Int32, ttl: Duration) async throws -> Lease {
        let now = clock.now()
        let alive = liveness.isAlive(pid:)
        return try await dbQueue.write { database in
            let existing = try Self.fetchLease(database)
            let highWater = try Self.fetchHighWater(database)
            switch ruleLease(existing: existing, highWater: highWater, requester: owner, now: now, isAlive: alive) {
            case .held(let holder):
                throw DurableError.leaseHeld(owner: holder.owner, epoch: holder.epoch)
            case .renew:
                guard let existing else {
                    throw DurableError.invariant("lease disappeared during renew")
                }
                let expires = now.addingTimeInterval(ttl.timeInterval)
                try database.execute(
                    sql: "UPDATE lease SET pid = ?, expires_at = ? WHERE epoch = ?",
                    arguments: [Int64(pid), expires.timeIntervalSince1970, Int64(existing.epoch)]
                )
                return Lease(owner: existing.owner, epoch: existing.epoch, pid: pid, expiresAt: expires)
            case .grant(let epoch):
                let expires = now.addingTimeInterval(ttl.timeInterval)
                try database.execute(sql: "DELETE FROM lease")
                try database.execute(
                    sql: """
                    INSERT INTO lease (singleton, owner, epoch, pid, expires_at)
                    VALUES (1, ?, ?, ?, ?)
                    """,
                    arguments: [
                        owner.uuidString.lowercased(),
                        Int64(epoch),
                        Int64(pid),
                        expires.timeIntervalSince1970,
                    ]
                )
                try database.execute(
                    sql: """
                    INSERT INTO meta (key, value) VALUES ('lease_epoch', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [String(epoch)]
                )
                return Lease(owner: owner, epoch: epoch, pid: pid, expiresAt: expires)
            }
        }
    }

    public func renewLease(fence: FenceToken, ttl: Duration) async throws -> Lease {
        let now = clock.now()
        return try await dbQueue.write { database in
            let existing = try Self.fetchLease(database)
            guard let existing, existing.owner == fence.owner, existing.epoch == fence.epoch else {
                throw DurableError.fenced(expectedEpoch: fence.epoch, actualEpoch: existing?.epoch ?? 0)
            }
            let expires = now.addingTimeInterval(ttl.timeInterval)
            try database.execute(
                sql: "UPDATE lease SET expires_at = ? WHERE epoch = ?",
                arguments: [expires.timeIntervalSince1970, Int64(existing.epoch)]
            )
            return Lease(owner: existing.owner, epoch: existing.epoch, pid: existing.pid, expiresAt: expires)
        }
    }

    public func releaseLease(fence: FenceToken) async throws {
        try await dbQueue.write { database in
            let existing = try Self.fetchLease(database)
            guard let existing, existing.owner == fence.owner, existing.epoch == fence.epoch else {
                throw DurableError.fenced(expectedEpoch: fence.epoch, actualEpoch: existing?.epoch ?? 0)
            }
            try database.execute(sql: "DELETE FROM lease")
            let highWater = max(try Self.fetchHighWater(database), fence.epoch)
            try database.execute(
                sql: """
                INSERT INTO meta (key, value) VALUES ('lease_epoch', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [String(highWater)]
            )
        }
    }

    public func commit(fence: FenceToken, stream: StreamID, events drafts: [EventDraft]) async throws -> [EventEnvelope] {
        let now = clock.now()
        return try await dbQueue.write { database in
            let existing = try Self.fetchLease(database)
            guard let existing, existing.owner == fence.owner, existing.epoch == fence.epoch else {
                throw DurableError.fenced(expectedEpoch: fence.epoch, actualEpoch: existing?.epoch ?? 0)
            }
            let row = try Int64.fetchOne(database, sql: "SELECT COALESCE(MAX(global_seq), 0) FROM events") ?? 0
            var global = UInt64(row) + 1
            let streamRow = try Int64.fetchOne(
                database,
                sql: "SELECT COALESCE(MAX(stream_seq), 0) FROM events WHERE stream = ?",
                arguments: [stream.raw]
            ) ?? 0
            var streamSeq = UInt64(streamRow) + 1
            var written: [EventEnvelope] = []
            written.reserveCapacity(drafts.count)
            for draft in drafts {
                let recorded = draft.recordedAt ?? now
                let payload = draft.payload.canonicalJSON()
                try database.execute(
                    sql: """
                    INSERT INTO events (
                        global_seq, stream, stream_seq, type, schema_version, recorded_at, payload
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        Int64(global),
                        stream.raw,
                        Int64(streamSeq),
                        draft.type,
                        draft.schemaVersion,
                        recorded.timeIntervalSince1970,
                        payload,
                    ]
                )
                written.append(EventEnvelope(
                    globalSeq: global,
                    stream: stream,
                    streamSeq: streamSeq,
                    type: draft.type,
                    schemaVersion: draft.schemaVersion,
                    recordedAt: recorded,
                    payload: draft.payload
                ))
                global += 1
                streamSeq += 1
            }
            return written
        }
    }

    public func readAll() async throws -> [EventEnvelope] {
        try await dbQueue.read { database in
            try Self.fetchEvents(database, stream: nil)
        }
    }

    public func read(stream: StreamID) async throws -> [EventEnvelope] {
        try await dbQueue.read { database in
            try Self.fetchEvents(database, stream: stream)
        }
    }

    public func readAll(after globalSeq: UInt64) async throws -> [EventEnvelope] {
        try await dbQueue.read { database in
            try Self.fetchEvents(database, stream: nil, after: globalSeq)
        }
    }

    public func rewritePayload(globalSeq: UInt64, payload: JSONValue, fence: FenceToken) async throws {
        try await dbQueue.write { database in
            let existing = try Self.fetchLease(database)
            guard let existing, existing.owner == fence.owner, existing.epoch == fence.epoch else {
                throw DurableError.fenced(expectedEpoch: fence.epoch, actualEpoch: existing?.epoch ?? 0)
            }
            try database.execute(
                sql: "UPDATE events SET payload = ? WHERE global_seq = ?",
                arguments: [payload.canonicalJSON(), Int64(globalSeq)]
            )
        }
    }

    private static func migrate(_ database: Database) throws {
        let version = try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0
        if version > 1 {
            throw DurableError.incompatibleSchema(found: version)
        }
        if version == 1 {
            return
        }
        try database.execute(sql: """
        CREATE TABLE meta (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        )
        """)
        try database.execute(sql: """
        CREATE TABLE lease (
            singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
            owner TEXT NOT NULL,
            epoch INTEGER NOT NULL,
            pid INTEGER NOT NULL,
            expires_at REAL NOT NULL
        )
        """)
        try database.execute(sql: """
        CREATE TABLE events (
            global_seq INTEGER PRIMARY KEY NOT NULL,
            stream TEXT NOT NULL,
            stream_seq INTEGER NOT NULL,
            type TEXT NOT NULL,
            schema_version INTEGER NOT NULL,
            recorded_at REAL NOT NULL,
            payload TEXT NOT NULL,
            UNIQUE (stream, stream_seq)
        )
        """)
        try database.execute(sql: "PRAGMA user_version = 1")
    }

    private static func fetchHighWater(_ database: Database) throws -> UInt64 {
        guard let raw = try String.fetchOne(database, sql: "SELECT value FROM meta WHERE key = 'lease_epoch'"),
              let value = UInt64(raw)
        else {
            return 0
        }
        return value
    }

    private static func fetchLease(_ database: Database) throws -> Lease? {
        guard let row = try Row.fetchOne(database, sql: "SELECT owner, epoch, pid, expires_at FROM lease") else {
            return nil
        }
        guard let ownerRaw: String = row["owner"],
              let owner = UUID(uuidString: ownerRaw),
              let epoch: Int64 = row["epoch"],
              let pid: Int64 = row["pid"],
              let expires: Double = row["expires_at"]
        else {
            throw DurableError.invariant("lease row is unreadable")
        }
        return Lease(
            owner: owner,
            epoch: UInt64(epoch),
            pid: Int32(pid),
            expiresAt: Date(timeIntervalSince1970: expires)
        )
    }

    private static func fetchEvents(_ database: Database, stream: StreamID?, after: UInt64? = nil) throws -> [EventEnvelope] {
        let rows: [Row]
        if let after {
            rows = try Row.fetchAll(
                database,
                sql: """
                SELECT global_seq, stream, stream_seq, type, schema_version, recorded_at, payload
                FROM events WHERE global_seq > ? ORDER BY global_seq
                """,
                arguments: [Int64(after)]
            )
        } else if let stream {
            rows = try Row.fetchAll(
                database,
                sql: """
                SELECT global_seq, stream, stream_seq, type, schema_version, recorded_at, payload
                FROM events WHERE stream = ? ORDER BY global_seq
                """,
                arguments: [stream.raw]
            )
        } else {
            rows = try Row.fetchAll(
                database,
                sql: """
                SELECT global_seq, stream, stream_seq, type, schema_version, recorded_at, payload
                FROM events ORDER BY global_seq
                """
            )
        }
        return try rows.map { row in
            guard let global: Int64 = row["global_seq"],
                  let streamRaw: String = row["stream"],
                  let streamSeq: Int64 = row["stream_seq"],
                  let type: String = row["type"],
                  let version: Int64 = row["schema_version"],
                  let recorded: Double = row["recorded_at"],
                  let payloadText: String = row["payload"]
            else {
                throw DurableError.invariant("event row is unreadable")
            }
            return EventEnvelope(
                globalSeq: UInt64(global),
                stream: StreamID(streamRaw),
                streamSeq: UInt64(streamSeq),
                type: type,
                schemaVersion: Int(version),
                recordedAt: Date(timeIntervalSince1970: recorded),
                payload: try JSONValue.parse(payloadText)
            )
        }
    }
}
