import DurableCore
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Fake property book, outbox, and calendar. Nothing here leaves the app.
final class EscrowWorld: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var crashArmed = false

    init(directory: URL) {
        self.directory = directory
    }

    static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("EscrowAssistant", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func armCrash() {
        lock.lock()
        crashArmed = true
        lock.unlock()
    }

    func tools() -> [Tool] {
        [
            Tool(
                name: "lookupProperty",
                effect: .pure,
                summary: "Look up a property by address or parcel id. Read only."
            ) { [self] input, _ in
                ToolReturn(output: self.lookup(input["query"]?.stringValue ?? ""))
            },
            Tool(
                name: "sendEmail",
                effect: .external,
                summary: "Send one email. Arguments: to, subject, body.",
                reconcile: { [self] key, _ in
                    if let receipt = self.receipt(for: key) {
                        return .done(receipt)
                    }
                    return .notDone
                }
            ) { [self] input, context in
                let receipt = self.emailReceipt(input)
                try self.remember(key: context.key, receipt: receipt)
                if self.consumeCrash() {
                    Self.terminateMidTool()
                }
                return ToolReturn(output: receipt)
            },
            Tool(
                name: "scheduleClosing",
                effect: .idempotent,
                summary: "Book a closing. Arguments: when, address."
            ) { [self] input, context in
                ToolReturn(output: self.schedule(
                    when: input["when"]?.stringValue ?? "Friday 10:00",
                    address: input["address"]?.stringValue ?? "14 Harbor Lane",
                    key: context.key
                ))
            },
        ]
    }

    func lookup(_ query: String) -> JSONValue {
        let lower = query.lowercased()
        if lower.contains("harbor") || lower.contains("1044") || lower.contains("14") {
            return .object([
                "address": .string("14 Harbor Lane"),
                "parcel": .string("P-1044"),
                "status": .string("in escrow"),
                "price": .string("840000"),
            ])
        }
        return .object([
            "address": .string(query.isEmpty ? "unknown" : query),
            "status": .string("not on file"),
        ])
    }

    func emailReceipt(_ input: JSONValue) -> JSONValue {
        .object([
            "status": .string("sent"),
            "to": .string(input["to"]?.stringValue ?? "buyer@example.com"),
            "subject": .string(input["subject"]?.stringValue ?? "Escrow update"),
            "body": .string(input["body"]?.stringValue ?? ""),
        ])
    }

    func receipt(for key: EffectKey) -> JSONValue? {
        load(file: "outbox.json")[key.raw]
    }

    func remember(key: EffectKey, receipt: JSONValue) throws {
        var all = load(file: "outbox.json")
        all[key.raw] = receipt
        try save(all, file: "outbox.json")
    }

    func schedule(when: String, address: String, key: EffectKey) -> JSONValue {
        var all = load(file: "closings.json")
        if let existing = all[key.raw] {
            return existing
        }
        let value = JSONValue.object([
            "when": .string(when),
            "address": .string(address),
            "status": .string("scheduled"),
        ])
        all[key.raw] = value
        try? save(all, file: "closings.json")
        return value
    }

    private func consumeCrash() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let armed = crashArmed
        crashArmed = false
        return armed
    }

    private func load(file: String) -> [String: JSONValue] {
        let url = directory.appendingPathComponent(file)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = try? JSONValue.parse(text),
              let object = parsed.objectValue
        else {
            return [:]
        }
        return object
    }

    private func save(_ object: [String: JSONValue], file: String) throws {
        let text = JSONValue.object(object).canonicalJSON()
        let url = directory.appendingPathComponent(file)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private static func terminateMidTool() -> Never {
        #if canImport(Darwin)
        kill(getpid(), SIGKILL)
        #endif
        fatalError("process did not terminate")
    }
}
