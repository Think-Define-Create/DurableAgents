import AgentAppCore
import Contacts
import EventKit
import Foundation
import Vision

#if canImport(VisionKit)
import VisionKit
#endif

enum AppleToolHosts {
    static func make() -> ToolHosts {
        ToolHosts(
            web: URLSessionWebFetch(),
            notes: EventKitNotes(),
            calendar: EventKitCalendar(),
            contacts: ContactsSearch(),
            documents: VisionDocuments()
        )
    }
}

/// A tool error the model can read and explain, instead of an empty result.
enum HostAccessError: Error, CustomStringConvertible {
    case denied(String)

    var description: String {
        switch self {
        case .denied(let name): "\(name) access is off for Assistant. Turn it on in Settings, Privacy & Security, \(name)."
        }
    }
}

struct URLSessionWebFetch: WebFetchClient {
    func fetch(url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class EventKitNotes: NotesClient, @unchecked Sendable {
    private let store = EKEventStore()

    func upsertReminder(title: String, effectKey: String) async throws -> String {
        try await upsertReminder(title: title, due: nil, effectKey: effectKey)
    }

    func upsertReminder(title: String, due: Date?, effectKey: String) async throws -> String {
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw HostAccessError.denied("Reminders") }
        let existing = try await reminders()
        if let match = existing.first(where: { $0.notes == effectKey }) {
            return match.id
        }
        guard let calendar = store.defaultCalendarForNewReminders() else { return "no-calendar" }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = effectKey
        reminder.calendar = calendar
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    private struct ReminderRef: Sendable {
        var id: String
        var notes: String?
    }

    /// Copies out the fields we need so no `EKReminder` crosses the continuation.
    private func reminders() async throws -> [ReminderRef] {
        let predicate = store.predicateForReminders(in: nil)
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let refs = (reminders ?? []).map { ReminderRef(id: $0.calendarItemIdentifier, notes: $0.notes) }
                continuation.resume(returning: refs)
            }
        }
    }
}

final class EventKitCalendar: CalendarClient, @unchecked Sendable {
    private let store = EKEventStore()

    func upcoming(limit: Int) async throws -> [CalendarEventRecord] {
        try await upcoming(days: 30, limit: limit)
    }

    func upcoming(days: Int, limit: Int) async throws -> [CalendarEventRecord] {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw HostAccessError.denied("Calendar") }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Date().addingTimeInterval(TimeInterval(days) * 60 * 60 * 24)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.endDate > Date() }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { event in
                CalendarEventRecord(
                    title: event.title ?? "",
                    effectKey: event.notes,
                    start: event.startDate,
                    end: event.endDate,
                    location: event.location
                )
            }
    }

    func upsert(title: String, effectKey: String) async throws -> String {
        try await upsert(title: title, start: nil, minutes: 60, effectKey: effectKey)
    }

    func upsert(title: String, start: Date?, minutes: Int, effectKey: String) async throws -> String {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw HostAccessError.denied("Calendar") }
        if try await find(effectKey: effectKey) {
            return effectKey
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = effectKey
        let begin = start ?? Date().addingTimeInterval(3600)
        event.startDate = begin
        event.endDate = begin.addingTimeInterval(TimeInterval(minutes) * 60)
        guard let calendar = store.defaultCalendarForNewEvents else { return "no-calendar" }
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier
    }

    func find(effectKey: String) async throws -> Bool {
        let end = Date().addingTimeInterval(60 * 60 * 24 * 365)
        let start = Date().addingTimeInterval(-60 * 60 * 24 * 30)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).contains { $0.notes == effectKey }
    }
}

final class ContactsSearch: ContactsClient, @unchecked Sendable {
    private let store = CNContactStore()

    func search(name: String) async throws -> [String] {
        let granted = try await store.requestAccess(for: .contacts)
        guard granted else { throw HostAccessError.denied("Contacts") }
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let matches = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        return matches.prefix(10).compactMap { contact in
            guard let full = CNContactFormatter.string(from: contact, style: .fullName) else { return nil }
            let phones = contact.phoneNumbers.map(\.value.stringValue)
            let emails = contact.emailAddresses.map { $0.value as String }
            let details = (phones + emails).joined(separator: ", ")
            return details.isEmpty ? full : "\(full): \(details)"
        }
    }
}

struct VisionDocuments: DocumentTextClient {
    func recognize(data: Data) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation])?.compactMap { observation in
                    observation.topCandidates(1).first?.string
                } ?? []
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            do {
                try VNImageRequestHandler(data: data).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
