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
}

public struct CalendarEventRecord: Sendable, Equatable {
    public var title: String
    public var effectKey: String?

    public init(title: String, effectKey: String? = nil) {
        self.title = title
        self.effectKey = effectKey
    }
}

public protocol CalendarClient: Sendable {
    func upcoming(limit: Int) async throws -> [CalendarEventRecord]
    func upsert(title: String, effectKey: String) async throws -> String
    func find(effectKey: String) async throws -> Bool
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
                run: { arguments, _ in
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
                summary: "Create or reuse a reminder tagged with the effect key.",
                parametersJSON: #"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}"#,
                requiresApproval: true,
                run: { arguments, context in
                    let title = arguments["title"]?.stringValue ?? "Reminder"
                    let id = try await notes.upsertReminder(title: title, effectKey: context.key.raw)
                    return ToolReturn(output: .object(["id": .string(id), "effectKey": .string(context.key.raw)]))
                }
            ),
            Tool(
                name: BuiltinToolID.calendarRead,
                effect: .pure,
                summary: "Read upcoming calendar events.",
                parametersJSON: #"{"type":"object","properties":{"limit":{"type":"integer"}}}"#,
                run: { arguments, _ in
                    let limit = Int(arguments["limit"]?.intValue ?? 5)
                    let events = try await calendar.upcoming(limit: limit)
                    let rows = events.map { record in
                        JSONValue.object([
                            "title": .string(record.title),
                            "effectKey": record.effectKey.map(JSONValue.string) ?? .null,
                        ])
                    }
                    return ToolReturn(output: .object(["events": .array(rows)]))
                }
            ),
            Tool(
                name: BuiltinToolID.calendarWrite,
                effect: .external,
                summary: "Create a calendar event. Recovery looks up the effect key instead of creating a second event.",
                parametersJSON: #"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}"#,
                requiresApproval: true,
                reconcile: { key, _ in
                    if try await calendar.find(effectKey: key.raw) {
                        return .done(.object(["effectKey": .string(key.raw), "status": .string("exists")]))
                    }
                    return .notDone
                },
                run: { arguments, context in
                    let title = arguments["title"]?.stringValue ?? "Event"
                    let id = try await calendar.upsert(title: title, effectKey: context.key.raw)
                    return ToolReturn(output: .object(["id": .string(id), "effectKey": .string(context.key.raw)]))
                }
            ),
            Tool(
                name: BuiltinToolID.contactsSearch,
                effect: .pure,
                summary: "Search contacts by name.",
                parametersJSON: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#,
                run: { arguments, _ in
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
                run: { arguments, _ in
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
