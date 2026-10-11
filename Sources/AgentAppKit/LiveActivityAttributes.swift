#if canImport(ActivityKit) && !os(macOS)
import ActivityKit

/// Shared by the app and the widget extension so Live Activity state is the same type.
public struct AgentActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var status: String
        public var title: String

        public init(status: String, title: String) {
            self.status = status
            self.title = title
        }
    }

    public var agentTitle: String

    public init(agentTitle: String) {
        self.agentTitle = agentTitle
    }
}
#endif
