import DurableCore
import Foundation
import Logging

/// Writes span start and end lines through swift-log. Attributes are scrubbed again here.
public struct LoggingTracer: RunTracing {
    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    public func begin(name: String, attributes: [String: SpanAttribute]) async -> SpanHandle {
        let handle = SpanHandle(id: UUID().uuidString, name: name)
        logger.info("span.begin", metadata: metadata(name: name, id: handle.id, attributes: attributes))
        return handle
    }

    public func end(_ span: SpanHandle, attributes: [String: SpanAttribute]) async {
        logger.info("span.end", metadata: metadata(name: span.name, id: span.id, attributes: attributes))
    }

    private func metadata(name: String, id: String, attributes: [String: SpanAttribute]) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "span": .string(name),
            "spanID": .string(id),
        ]
        for (key, value) in SpanScrub.scrub(attributes) {
            metadata[key] = .string(SpanScrub.render(value))
        }
        return metadata
    }
}
