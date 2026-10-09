import DurableCore
import Foundation

/// A durable routine. This is not the store lease keep-alive.
public struct RoutineID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum CatchUpPolicy: String, Sendable, Equatable, Codable {
    /// Drop slots that were missed while the process was gone, and run the current one.
    case skipMissed
    /// Run only the newest due slot. Older ones are journaled as missed.
    case runLatest
    /// Run missed slots from oldest to newest, at most eight per tick.
    case runAll
}

public enum Cadence: Sendable, Equatable, Codable {
    /// `jitter` is a fraction of the interval, applied as ± that fraction of the slot.
    case every(Duration, jitter: Double)
    case cron(String, timeZone: String)
    case onEvent(String)
}

/// When the routine is allowed to run. Outside this window the tick is skipped.
/// `activeStart` and `activeEnd` are `HH:mm` in `timeZone`.
public struct QuietHours: Sendable, Equatable, Codable {
    public var activeStart: String
    public var activeEnd: String
    public var timeZone: String

    public init(activeStart: String, activeEnd: String, timeZone: String) {
        self.activeStart = activeStart
        self.activeEnd = activeEnd
        self.timeZone = timeZone
    }

    public func isActive(at date: Date) -> Bool {
        guard let zone = TimeZone(identifier: timeZone),
              let start = Self.minutes(activeStart),
              let end = Self.minutes(activeEnd)
        else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if start == end { return true }
        if start < end { return now >= start && now < end }
        return now >= start || now < end
    }

    static func minutes(_ text: String) -> Int? {
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]) else {
            return nil
        }
        guard (0..<24).contains(hour), (0..<60).contains(minute), pieces[0].count == 2, pieces[1].count == 2 else {
            return nil
        }
        return hour * 60 + minute
    }
}

public struct Routine: Sendable, Equatable, Codable {
    public static let checklistByteCap = 256 * 1024

    public var id: RoutineID
    public var agentID: String
    public var cadence: Cadence
    public var quiet: QuietHours?
    public var isolatedSession: Bool
    public var lightContext: Bool
    public var checklist: String
    public var budget: RunBudget
    public var skipWhenEmptyChecklist: Bool
    public var maxConcurrent: Int
    public var minEventSpacing: Duration
    public var catchUp: CatchUpPolicy

    public init(
        id: RoutineID,
        agentID: String,
        cadence: Cadence,
        quiet: QuietHours? = nil,
        isolatedSession: Bool = true,
        lightContext: Bool = false,
        checklist: String,
        budget: RunBudget = RunBudget(maxSteps: 8, maxWallSeconds: 120, onExceeded: .fail),
        skipWhenEmptyChecklist: Bool = true,
        maxConcurrent: Int = 1,
        minEventSpacing: Duration = .seconds(30),
        catchUp: CatchUpPolicy = .runLatest
    ) {
        self.id = id
        self.agentID = agentID
        self.cadence = cadence
        self.quiet = quiet
        self.isolatedSession = isolatedSession
        self.lightContext = lightContext
        self.checklist = checklist
        self.budget = budget
        self.skipWhenEmptyChecklist = skipWhenEmptyChecklist
        self.maxConcurrent = maxConcurrent
        self.minEventSpacing = minEventSpacing
        self.catchUp = catchUp
    }

    func json() -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id.rawValue),
            "agentID": .string(agentID),
            "cadence": cadence.json(),
            "isolatedSession": .bool(isolatedSession),
            "lightContext": .bool(lightContext),
            "checklist": .string(checklist),
            "budget": budget.json(),
            "skipWhenEmptyChecklist": .bool(skipWhenEmptyChecklist),
            "maxConcurrent": .int(Int64(maxConcurrent)),
            "minEventSpacing": .double(minEventSpacing.timeInterval),
            "catchUp": .string(catchUp.rawValue),
        ]
        if let quiet {
            fields["quiet"] = .object([
                "activeStart": .string(quiet.activeStart),
                "activeEnd": .string(quiet.activeEnd),
                "timeZone": .string(quiet.timeZone),
            ])
        }
        return .object(fields)
    }

    static func parse(_ value: JSONValue) throws -> Routine {
        guard let fields = value.objectValue,
              let id = fields["id"]?.stringValue,
              let agentID = fields["agentID"]?.stringValue,
              let cadenceValue = fields["cadence"],
              let checklist = fields["checklist"]?.stringValue,
              let budgetValue = fields["budget"]
        else {
            throw ScheduleError.invalidRoutine
        }
        var quiet: QuietHours?
        if let raw = fields["quiet"]?.objectValue,
           let start = raw["activeStart"]?.stringValue,
           let end = raw["activeEnd"]?.stringValue,
           let zone = raw["timeZone"]?.stringValue
        {
            quiet = QuietHours(activeStart: start, activeEnd: end, timeZone: zone)
        }
        let catchUp = fields["catchUp"]?.stringValue.flatMap(CatchUpPolicy.init(rawValue:)) ?? .runLatest
        return Routine(
            id: RoutineID(id),
            agentID: agentID,
            cadence: try Cadence.parse(cadenceValue),
            quiet: quiet,
            isolatedSession: fields["isolatedSession"]?.boolValue ?? true,
            lightContext: fields["lightContext"]?.boolValue ?? false,
            checklist: checklist,
            budget: try RunBudget.parse(budgetValue),
            skipWhenEmptyChecklist: fields["skipWhenEmptyChecklist"]?.boolValue ?? true,
            maxConcurrent: Int(fields["maxConcurrent"]?.intValue ?? 1),
            minEventSpacing: .seconds(try fields["minEventSpacing"].map { try ScheduleNumbers.double($0) } ?? 30),
            catchUp: catchUp
        )
    }
}

extension Cadence {
    func json() -> JSONValue {
        switch self {
        case .every(let duration, let jitter):
            return .object([
                "kind": .string("every"),
                "seconds": .double(duration.timeInterval),
                "jitter": .double(jitter),
            ])
        case .cron(let expression, let timeZone):
            return .object([
                "kind": .string("cron"),
                "expression": .string(expression),
                "timeZone": .string(timeZone),
            ])
        case .onEvent(let name):
            return .object([
                "kind": .string("event"),
                "name": .string(name),
            ])
        }
    }

    static func parse(_ value: JSONValue) throws -> Cadence {
        guard let fields = value.objectValue, let kind = fields["kind"]?.stringValue else {
            throw ScheduleError.invalidRoutine
        }
        switch kind {
        case "every":
            let seconds = try fields["seconds"].map { try ScheduleNumbers.double($0) } ?? 0
            let jitter = try fields["jitter"].map { try ScheduleNumbers.double($0) } ?? 0
            return .every(.seconds(seconds), jitter: jitter)
        case "cron":
            guard let expression = fields["expression"]?.stringValue, let zone = fields["timeZone"]?.stringValue else {
                throw ScheduleError.invalidRoutine
            }
            return .cron(expression, timeZone: zone)
        case "event":
            guard let name = fields["name"]?.stringValue else { throw ScheduleError.invalidRoutine }
            return .onEvent(name)
        default:
            throw ScheduleError.invalidRoutine
        }
    }
}

public enum HeartbeatOutcome: Sendable, Equatable, Codable {
    case noReply
    case notify(text: String, dedupeKey: String)
    case updateChecklist(String)

    func json() -> JSONValue {
        switch self {
        case .noReply:
            return .object(["kind": .string("noReply")])
        case .notify(let text, let dedupeKey):
            return .object([
                "kind": .string("notify"),
                "text": .string(text),
                "dedupeKey": .string(dedupeKey),
            ])
        case .updateChecklist(let checklist):
            return .object([
                "kind": .string("updateChecklist"),
                "checklist": .string(checklist),
            ])
        }
    }

    static func parse(_ value: JSONValue) -> HeartbeatOutcome? {
        guard let kind = value["kind"]?.stringValue else { return nil }
        switch kind {
        case "noReply":
            return .noReply
        case "notify":
            return .notify(text: value["text"]?.stringValue ?? "", dedupeKey: value["dedupeKey"]?.stringValue ?? "")
        case "updateChecklist":
            return .updateChecklist(value["checklist"]?.stringValue ?? "")
        default:
            return nil
        }
    }
}

public struct RoutineFiring: Sendable, Equatable {
    public var routineID: RoutineID
    public var requestID: String
    public var slot: Date
    public var skipped: String?
    public var outcome: HeartbeatOutcome?
    public var conversationID: ConversationID?
}

public enum ScheduleError: Error, Equatable, Sendable {
    case checklistTooLarge(Int)
    case invalidCron(String)
    case invalidTimeZone(String)
    case invalidQuietHours(String)
    case invalidRoutine
    case invalidHeartbeat
}

enum ScheduleNumbers {
    static func double(_ value: JSONValue) throws -> Double {
        switch value {
        case .double(let number):
            return number
        case .int(let number):
            return Double(number)
        default:
            throw ScheduleError.invalidRoutine
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Stable unit in `0...1` for one slot. `0.5` is no shift.
public protocol ScheduleJitter: Sendable {
    func unit(routine: RoutineID, slot: Date) -> Double
}

public struct ZeroScheduleJitter: ScheduleJitter {
    public init() {}

    public func unit(routine: RoutineID, slot: Date) -> Double { 0.5 }
}

public enum RoutineStream {
    public static let id = StreamID("routines")
}
