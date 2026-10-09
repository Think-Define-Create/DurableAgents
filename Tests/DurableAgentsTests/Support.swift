import DurableCore
import DurableStore
import Foundation
import Testing

enum StoreKind: String, Sendable, CustomStringConvertible {
    case memory
    case sqlite

    var description: String { rawValue }
}

struct Harness {
    var store: any EventStore
    var clock: ManualClock
    var liveness: ScriptedLiveness

    func engine(
        tools: [Tool] = [],
        timers: any TimerScheduling = NoOpTimerScheduling(),
        leaseTTL: Duration = .seconds(3600)
    ) async throws -> Engine {
        try await Engine(store: store, tools: tools, timers: timers, leaseTTL: leaseTTL)
    }
}

func makeHarness(_ kind: StoreKind) throws -> Harness {
    let clock = ManualClock()
    let liveness = ScriptedLiveness()
    switch kind {
    case .memory:
        return Harness(
            store: InMemoryEventStore(clock: clock, liveness: liveness),
            clock: clock,
            liveness: liveness
        )
    case .sqlite:
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("events.sqlite").path
        return Harness(
            store: try SQLiteEventStore(path: database, clock: clock, liveness: liveness),
            clock: clock,
            liveness: liveness
        )
    }
}

actor Recorder {
    struct Call: Sendable, Equatable {
        var key: EffectKey
        var attempt: Int
        var isReplay: Bool
    }

    private(set) var calls: [Call] = []

    func add(_ context: EffectContext) {
        calls.append(Call(key: context.key, attempt: context.attempt, isReplay: context.isReplay))
    }
}

actor Once {
    private var armed = true

    func consume() -> Bool {
        if armed {
            armed = false
            return true
        }
        return false
    }
}

func crashScript(tool: String, callID: String, arguments: JSONValue = .object([:])) -> Script {
    Script(steps: [
        .tool(name: tool, callID: callID, arguments: arguments),
        .finish("done"),
    ])
}

func requireIntent(in events: [EventEnvelope]) throws -> EventEnvelope {
    let intents = events.filter { $0.type == EventType.effectIntent }
    #expect(intents.count == 1)
    return try #require(intents.first)
}

func requireResult(in events: [EventEnvelope]) throws -> EventEnvelope {
    let results = events.filter { $0.type == EventType.effectResult }
    #expect(results.count == 1)
    return try #require(results.first)
}
