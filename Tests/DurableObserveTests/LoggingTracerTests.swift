import DurableCore
import DurableObserve
import Foundation
import Logging
import Testing

final class MemoryLog: LogHandler, @unchecked Sendable {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info
    private let lock = NSLock()
    private var lines: [String] = []

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:]) { _, new in new }
        let rendered = merged.keys.sorted().map { key in
            "\(key)=\(merged[key] ?? .string(""))"
        }.joined(separator: " ")
        lock.lock()
        lines.append("\(event.message) \(rendered)")
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

@Test func loggingTracerOmitsPromptAndSecretAttributes() async {
    let memory = MemoryLog()
    let tracer = LoggingTracer(logger: Logger(label: "test", factory: { _ in memory }))
    _ = await tracer.begin(name: "model.plan", attributes: [
        "conversation": .string("c1"),
        "prompt": .string("wire funds to user@example.com"),
        "authorization": .string("Bearer sk-live"),
        "step": .int(0),
    ])
    let text = memory.snapshot()
    #expect(text.contains("span.begin"))
    #expect(text.contains("conversation=c1"))
    #expect(text.contains("step=0"))
    #expect(text.contains("wire funds") == false)
    #expect(text.contains("user@example.com") == false)
    #expect(text.contains("sk-live") == false)
    #expect(text.contains("Bearer") == false)
}
