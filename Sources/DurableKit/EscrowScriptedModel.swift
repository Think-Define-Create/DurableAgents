import DurableCore
import Foundation

/// Deterministic escrow planner used when the on-device model is unavailable.
///
/// The next step is a function of the latest user message, the tools already
/// finished in this run, and the human approvals granted in this run.
public struct EscrowScriptedModel: ModelStep {
    public static let closingApprovalID = "closing"
    public static let closingPrompt = "Approve scheduling this closing?"

    public init() {}

    public func plan(context: ModelContext) async throws -> ScriptedStep {
        let userText = context.messages.last(where: { $0.role == "user" })?.text ?? ""
        let lower = userText.lowercased()
        let toolsDone = Set(context.completedTools.map(\.name))

        if wantsEmail(lower) {
            let recipient = Self.emailAddress(in: userText)
            if !toolsDone.contains("sendEmail") {
                return .tool(
                    name: "sendEmail",
                    callID: "email-\(context.completedSteps)",
                    arguments: .object([
                        "to": .string(recipient),
                        "subject": .string("Escrow update"),
                        "body": .string(userText),
                    ])
                )
            }
            return .finish("The email is in the outbox for \(recipient).")
        }

        if wantsClosing(lower) {
            if !context.grantedApprovalIDs.contains(Self.closingApprovalID) {
                return .approval(id: Self.closingApprovalID, prompt: Self.closingPrompt)
            }
            if !toolsDone.contains("scheduleClosing") {
                return .tool(
                    name: "scheduleClosing",
                    callID: "closing-\(context.completedSteps)",
                    arguments: .object([
                        "when": .string(Self.when(in: lower)),
                        "address": .string(Self.address(in: lower)),
                    ])
                )
            }
            return .finish("Closing is on the calendar for \(Self.address(in: lower)).")
        }

        if wantsLookup(lower) {
            if !toolsDone.contains("lookupProperty") {
                return .tool(
                    name: "lookupProperty",
                    callID: "lookup-\(context.completedSteps)",
                    arguments: .object(["query": .string(userText)])
                )
            }
            return .finish(Self.lookupSentence(context.completedTools.last(where: { $0.name == "lookupProperty" })?.output))
        }

        return .finish("I can look up a property, send an email, or schedule a closing.")
    }

    private func wantsEmail(_ lower: String) -> Bool {
        if lower.contains("email") { return true }
        if lower.contains("send") && lower.contains("buyer") { return true }
        return false
    }

    private func wantsClosing(_ lower: String) -> Bool {
        lower.contains("clos") || lower.contains("schedule")
    }

    private func wantsLookup(_ lower: String) -> Bool {
        lower.contains("property") || lower.contains("lookup") || lower.contains("harbor")
            || lower.contains("address") || lower.contains("parcel")
    }

    static func emailAddress(in text: String) -> String {
        let token = text.split(whereSeparator: { $0.isWhitespace }).first { $0.contains("@") }
        if let token {
            return String(token)
        }
        return "buyer@example.com"
    }

    static func when(in lower: String) -> String {
        if lower.contains("monday") { return "Monday 10:00" }
        if lower.contains("thursday") { return "Thursday 10:00" }
        return "Friday 10:00"
    }

    static func address(in lower: String) -> String {
        if lower.contains("harbor") || lower.contains("14") {
            return "14 Harbor Lane"
        }
        return "14 Harbor Lane"
    }

    static func lookupSentence(_ output: JSONValue?) -> String {
        guard let fields = output?.objectValue,
              let address = fields["address"]?.stringValue,
              let status = fields["status"]?.stringValue
        else {
            return "I could not read a property record."
        }
        if let parcel = fields["parcel"]?.stringValue {
            return "\(address) (\(parcel)) is \(status)."
        }
        return "\(address) is \(status)."
    }
}
