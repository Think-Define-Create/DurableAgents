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

struct URLSessionWebFetch: WebFetchClient {
    func fetch(url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class EventKitNotes: NotesClient, @unchecked Sendable {
    private let store = EKEventStore()

    func upsertReminder(title: String, effectKey: String) async throws -> String {
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { return "denied" }
        let existing = try await reminders()
        if let match = existing.first(where: { $0.notes == effectKey }) {
            return match.calendarItemIdentifier
        }
        guard let calendar = store.defaultCalendarForNewReminders() else { return "no-calendar" }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = effectKey
        reminder.calendar = calendar
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    private func reminders() async throws -> [EKReminder] {
        let predicate = store.predicateForReminders(in: nil)
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }
}

final class EventKitCalendar: CalendarClient, @unchecked Sendable {
    private let store = EKEventStore()

    func upcoming(limit: Int) async throws -> [CalendarEventRecord] {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { return [] }
        let end = Date().addingTimeInterval(60 * 60 * 24 * 30)
        let predicate = store.predicateForEvents(withStart: Date(), end: end, calendars: nil)
        return store.events(matching: predicate).prefix(limit).map { event in
            CalendarEventRecord(title: event.title, effectKey: event.notes)
        }
    }

    func upsert(title: String, effectKey: String) async throws -> String {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { return "denied" }
        if try await find(effectKey: effectKey) {
            return effectKey
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = effectKey
        event.startDate = Date().addingTimeInterval(3600)
        event.endDate = Date().addingTimeInterval(7200)
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
        guard granted else { return [] }
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let matches = try store.unifiedContacts(matching: predicate, keysToFetch: [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)])
        return matches.compactMap { CNContactFormatter.string(from: $0, style: .fullName) }
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
