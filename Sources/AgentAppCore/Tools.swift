import DurableCore
import Foundation

public struct WebAllowlist: Sendable, Equatable {
    public var hosts: Set<String>

    public init(hosts: [String] = []) {
        self.hosts = Set(hosts.map { $0.lowercased() })
    }

    /// HTTPS anywhere on the list. HTTP only for localhost and 127.0.0.1.
    public func allows(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), hosts.contains(host) else { return false }
        if url.scheme == "https" { return true }
        if url.scheme == "http", host == "localhost" || host == "127.0.0.1" { return true }
        return false
    }
}

public protocol WebFetchClient: Sendable {
    func fetch(url: URL) async throws -> String
}

public protocol NotesClient: Sendable {
    func upsertReminder(title: String, effectKey: String) async throws -> String
    func upsertReminder(title: String, due: Date?, effectKey: String) async throws -> String
}

extension NotesClient {
    public func upsertReminder(title: String, due: Date?, effectKey: String) async throws -> String {
        try await upsertReminder(title: title, effectKey: effectKey)
    }
}

public struct CalendarEventRecord: Sendable, Equatable {
    public var title: String
    public var effectKey: String?
    public var start: Date?
    public var end: Date?
    public var location: String?

    public init(title: String, effectKey: String? = nil, start: Date? = nil, end: Date? = nil, location: String? = nil) {
        self.title = title
        self.effectKey = effectKey
        self.start = start
        self.end = end
        self.location = location
    }
}

public protocol CalendarClient: Sendable {
    func upcoming(limit: Int) async throws -> [CalendarEventRecord]
    func upsert(title: String, effectKey: String) async throws -> String
    func find(effectKey: String) async throws -> Bool
    func upcoming(days: Int, limit: Int) async throws -> [CalendarEventRecord]
    func upsert(title: String, start: Date?, minutes: Int, effectKey: String) async throws -> String
}

extension CalendarClient {
    public func upcoming(days: Int, limit: Int) async throws -> [CalendarEventRecord] {
        try await upcoming(limit: limit)
    }

    public func upsert(title: String, start: Date?, minutes: Int, effectKey: String) async throws -> String {
        try await upsert(title: title, effectKey: effectKey)
    }
}

/// Reads the times models write: ISO 8601 with or without seconds and offset, in the device time zone.
public enum ToolDates {
    public static func parse(_ text: String?, timeZone: TimeZone = .current) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'h:mm a", "yyyy-MM-dd h:mm a", "yyyy-MM-dd h a", "yyyy-MM-dd",
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return natural(text)
    }

    /// Phrases such as "tomorrow at 9am", which small models often write instead of ISO dates.
    public static func natural(_ text: String) -> Date? {
        #if canImport(Darwin)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range), let date = match.date else { return nil }
        return date
        #else
        return nil
        #endif
    }

    /// The local-time form tools accept, such as "2026-10-11T09:00".
    public static func local(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    /// Local time with the weekday, such as "Sat 2026-10-10 15:00".
    public static func describe(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

public protocol ContactsClient: Sendable {
    func search(name: String) async throws -> [String]
}

public protocol DocumentTextClient: Sendable {
    func recognize(data: Data) async throws -> String
}

public struct ToolHosts: Sendable {
    public var web: any WebFetchClient
    public var notes: any NotesClient
    public var calendar: any CalendarClient
    public var contacts: any ContactsClient
    public var documents: any DocumentTextClient

    public init(
        web: any WebFetchClient,
        notes: any NotesClient,
        calendar: any CalendarClient,
        contacts: any ContactsClient,
        documents: any DocumentTextClient
    ) {
        self.web = web
        self.notes = notes
        self.calendar = calendar
        self.contacts = contacts
        self.documents = documents
    }

    public static func memory() -> ToolHosts {
        ToolHosts(
            web: MemoryWebFetch(),
            notes: MemoryNotes(),
            calendar: MemoryCalendar(),
            contacts: MemoryContacts(),
            documents: MemoryDocuments()
        )
    }
}

public enum BuiltinToolID {
    public static let webFetch = "web.fetch"
    public static let reminder = "notes.reminder"
    public static let calendarRead = "calendar.read"
    public static let calendarWrite = "calendar.write"
    public static let contactsSearch = "contacts.search"
    public static let documentOCR = "document.ocr"
}

public enum BuiltinTools {
    /// A failed host call becomes a result the model can explain, such as a missing permission.
    /// Throwing would schedule automatic retries and leave the chat waiting.
    static func readable(
        _ body: @escaping @Sendable (JSONValue, EffectContext) async throws -> ToolReturn
    ) -> @Sendable (JSONValue, EffectContext) async throws -> ToolReturn {
        { arguments, context in
            do {
                return try await body(arguments, context)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return ToolReturn(output: .object(["error": .string(String(describing: error))]))
            }
        }
    }

    public static func make(
        hosts: ToolHosts,
        policy: PolicyBox,
        allowlist: WebAllowlist
    ) -> [Tool] {
        let web = hosts.web
        let notes = hosts.notes
        let calendar = hosts.calendar
        let contacts = hosts.contacts
        let documents = hosts.documents
        return [
            Tool(
                name: BuiltinToolID.webFetch,
                effect: .idempotent,
                summary: "GET a URL on the allowlist. Refuses other hosts and refuses every host when on-device only is on.",
                parametersJSON: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#,
                run: readable { arguments, _ in
                    if await policy.onDeviceOnly {
                        return ToolReturn(output: .object(["refused": .string("on-device only")]))
                    }
                    guard let raw = arguments["url"]?.stringValue, let url = URL(string: raw) else {
                        return ToolReturn(output: .object(["refused": .string("missing url")]))
                    }
                    guard allowlist.allows(url) else {
                        return ToolReturn(output: .object(["refused": .string("host not allowlisted")]))
                    }
                    let body = try await web.fetch(url: url)
                    return ToolReturn(output: .object(["text": .string(String(body.prefix(8_000)))]))
                }
            ),
            Tool(
                name: BuiltinToolID.reminder,
                effect: .idempotent,
                summary: "Create a reminder in Reminders. due is optional local time like 2026-10-11T09:00.",
                parametersJSON: #"{"type":"object","properties":{"title":{"type":"string","description":"What to do, without the date or time"},"due":{"type":"string","description":"Local date and time like 2026-10-11T09:00"}},"required":["title"]}"#,
                requiresApproval: true,
                run: readable { arguments, context in
                    let title = arguments["title"]?.stringValue ?? "Reminder"
                    let asked = arguments["due"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let due = ToolDates.parse(asked)
                    // A reminder without a time never alerts, so an unreadable time is an error, not a silent drop.
                    if !asked.isEmpty, due == nil {
                        return ToolReturn(output: .object([
                            "error": .string("Could not read the time \"\(asked)\". Use local time like 2026-10-11T09:00."),
                        ]))
                    }
                    let id = try await notes.upsertReminder(title: title, due: due, effectKey: context.key.raw)
                    var output: [String: JSONValue] = ["id": .string(id), "title": .string(title)]
                    if let due {
                        output["due"] = .string(ToolDates.describe(due))
                        output["alert"] = .string(due > Date() ? "set" : "none, the time has passed")
                    } else {
                        output["alert"] = .string("none, no time was given")
                    }
                    return ToolReturn(output: .object(output))
                }
            ),
            Tool(
                name: BuiltinToolID.calendarRead,
                effect: .pure,
                summary: "Read upcoming calendar events with their times. days is how far ahead to look.",
                parametersJSON: #"{"type":"object","properties":{"days":{"type":"integer","description":"How many days ahead to look"}}}"#,
                run: readable { arguments, _ in
                    let limit = min(max(Int(arguments["limit"]?.intValue ?? 10), 1), 50)
                    let days = min(max(Int(arguments["days"]?.intValue ?? 7), 1), 365)
                    let events = try await calendar.upcoming(days: days, limit: limit)
                    let rows = events.map { record in
                        var row: [String: JSONValue] = ["title": .string(record.title)]
                        if let start = record.start { row["start"] = .string(ToolDates.describe(start)) }
                        if let end = record.end { row["end"] = .string(ToolDates.describe(end)) }
                        if let location = record.location, !location.isEmpty { row["location"] = .string(location) }
                        return JSONValue.object(row)
                    }
                    return ToolReturn(output: .object(["events": .array(rows)]))
                }
            ),
            Tool(
                name: BuiltinToolID.calendarWrite,
                effect: .external,
                summary: "Create a calendar event. start is local time like 2026-10-11T15:00. minutes defaults to 60.",
                parametersJSON: #"{"type":"object","properties":{"title":{"type":"string","description":"Event name, without the date or time"},"start":{"type":"string","description":"Local date and time like 2026-10-11T15:00"},"minutes":{"type":"integer","description":"Length in minutes"}},"required":["title","start"]}"#,
                requiresApproval: true,
                reconcile: { key, _ in
                    if try await calendar.find(effectKey: key.raw) {
                        return .done(.object(["effectKey": .string(key.raw), "status": .string("exists")]))
                    }
                    return .notDone
                },
                run: readable { arguments, context in
                    let title = arguments["title"]?.stringValue ?? "Event"
                    let start = ToolDates.parse(arguments["start"]?.stringValue)
                    let minutes = min(max(Int(arguments["minutes"]?.intValue ?? 60), 5), 24 * 60)
                    let id = try await calendar.upsert(title: title, start: start, minutes: minutes, effectKey: context.key.raw)
                    var output: [String: JSONValue] = ["id": .string(id), "title": .string(title), "minutes": .int(Int64(minutes))]
                    if let start { output["start"] = .string(ToolDates.describe(start)) }
                    return ToolReturn(output: .object(output))
                }
            ),
            Tool(
                name: BuiltinToolID.contactsSearch,
                effect: .pure,
                summary: "Search contacts by name. Returns names with phone numbers and emails.",
                parametersJSON: #"{"type":"object","properties":{"name":{"type":"string","description":"The person's name"}},"required":["name"]}"#,
                run: readable { arguments, _ in
                    let name = arguments["name"]?.stringValue ?? ""
                    let matches = try await contacts.search(name: name)
                    return ToolReturn(output: .object(["matches": .array(matches.map(JSONValue.string))]))
                }
            ),
            Tool(
                name: BuiltinToolID.documentOCR,
                effect: .pure,
                summary: "Read text from a document the user already attached. Bytes stay on device.",
                parametersJSON: #"{"type":"object","properties":{"base64":{"type":"string"}},"required":["base64"]}"#,
                run: readable { arguments, _ in
                    guard let encoded = arguments["base64"]?.stringValue, let data = Data(base64Encoded: encoded) else {
                        return ToolReturn(output: .object(["refused": .string("missing document")]))
                    }
                    let text = try await documents.recognize(data: data)
                    return ToolReturn(output: .object(["text": .string(text)]))
                }
            ),
        ]
    }
}

public actor MemoryWebFetch: WebFetchClient {
    public private(set) var urls: [String] = []

    public init() {}

    public func fetch(url: URL) async throws -> String {
        urls.append(url.absoluteString)
        return "fetched"
    }
}

public actor MemoryNotes: NotesClient {
    public private(set) var byKey: [String: String] = [:]

    public init() {}

    public func upsertReminder(title: String, effectKey: String) async throws -> String {
        if let existing = byKey[effectKey] {
            return existing
        }
        let id = "rem_" + String(byKey.count + 1)
        byKey[effectKey] = id
        _ = title
        return id
    }
}

public actor MemoryCalendar: CalendarClient {
    public private(set) var events: [CalendarEventRecord] = []

    public init() {}

    public func upcoming(limit: Int) async throws -> [CalendarEventRecord] {
        Array(events.prefix(limit))
    }

    public func upsert(title: String, effectKey: String) async throws -> String {
        if let index = events.firstIndex(where: { $0.effectKey == effectKey }) {
            return "evt_\(index)"
        }
        events.append(CalendarEventRecord(title: title, effectKey: effectKey))
        return "evt_\(events.count - 1)"
    }

    public func find(effectKey: String) async throws -> Bool {
        events.contains { $0.effectKey == effectKey }
    }
}

public actor MemoryContacts: ContactsClient {
    public var names: [String]

    public init(names: [String] = ["Ada Lovelace", "Grace Hopper"]) {
        self.names = names
    }

    public func search(name: String) async throws -> [String] {
        let needle = name.lowercased()
        return names.filter { $0.lowercased().contains(needle) }
    }
}

public actor MemoryDocuments: DocumentTextClient {
    public init() {}

    public func recognize(data: Data) async throws -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}
