import DurableCore
import Foundation

/// The routine's reply. OpenClaw names the same contract `heartbeat_respond`.
/// `noReply` is a silent ack: the scheduler does not notify.
public enum HeartbeatTool {
    public static let name = "heartbeat.respond"

    public static let parameters = """
    {"type":"object","properties":{"outcome":{"type":"string","enum":["noReply","notify","updateChecklist"]},"text":{"type":"string"},"dedupeKey":{"type":"string"},"checklist":{"type":"string"}},"required":["outcome"]}
    """

    public static func make() -> Tool {
        Tool(
            name: name,
            effect: .pure,
            summary: "Say whether a routine has anything to report. noReply stays silent. OpenClaw calls this heartbeat_respond.",
            parametersJSON: parameters
        ) { input, _ in
            guard let outcome = input["outcome"]?.stringValue else {
                throw ScheduleError.invalidHeartbeat
            }
            switch outcome {
            case "noReply":
                return ToolReturn(output: .object(["outcome": .string("noReply")]))
            case "notify":
                return ToolReturn(output: .object([
                    "outcome": .string("notify"),
                    "text": .string(input["text"]?.stringValue ?? ""),
                    "dedupeKey": .string(input["dedupeKey"]?.stringValue ?? "heartbeat"),
                ]))
            case "updateChecklist":
                return ToolReturn(output: .object([
                    "outcome": .string("updateChecklist"),
                    "checklist": .string(input["checklist"]?.stringValue ?? ""),
                ]))
            default:
                throw ScheduleError.invalidHeartbeat
            }
        }
    }
}
