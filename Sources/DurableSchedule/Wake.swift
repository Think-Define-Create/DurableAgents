import Foundation

/// Asks the host to wake the process, and to show a local notification when a routine has something to say.
/// A silent ack does not call `notify`. There is no server push behind this protocol.
public protocol WakeScheduler: Sendable {
    func scheduleWake(at date: Date, identifier: String) async
    func notify(identifier: String, body: String, dedupeKey: String) async
}

public struct NoOpWakeScheduler: WakeScheduler {
    public init() {}

    public func scheduleWake(at date: Date, identifier: String) async {}

    public func notify(identifier: String, body: String, dedupeKey: String) async {}
}

public actor DeterministicWakeScheduler: WakeScheduler {
    public struct Wake: Sendable, Equatable {
        public var date: Date
        public var identifier: String
    }

    public struct Notice: Sendable, Equatable {
        public var identifier: String
        public var body: String
        public var dedupeKey: String
    }

    public private(set) var wakes: [Wake] = []
    public private(set) var notifications: [Notice] = []

    public init() {}

    public func scheduleWake(at date: Date, identifier: String) async {
        wakes.append(Wake(date: date, identifier: identifier))
    }

    public func notify(identifier: String, body: String, dedupeKey: String) async {
        notifications.append(Notice(identifier: identifier, body: body, dedupeKey: dedupeKey))
    }
}
