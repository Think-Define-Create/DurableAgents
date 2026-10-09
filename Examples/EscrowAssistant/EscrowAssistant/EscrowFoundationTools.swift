import DurableCore
import DurableFoundationModels
import DurableKit
import Foundation

#if canImport(FoundationModels)
import FoundationModels

enum EscrowPrompts {
    static let instructions = """
    You are an escrow assistant in a demo. Use only the provided tools. \
    Call at most one tool. Never claim a tool ran unless its result is already in the conversation. \
    lookupProperty is read-only. sendEmail sends one message. scheduleClosing books a closing; \
    the app may pause for approval before that tool runs. If a closing was just approved, call scheduleClosing. \
    Do not invent records, emails, or dates.
    """
}

@available(iOS 26, macOS 26, *)
struct LookupPropertyFMTool: FoundationModels.Tool {
    let capture: FoundationToolCapture
    let name = "lookupProperty"
    let description = "Look up a property by address or parcel id."
    let includesSchemaInInstructions = true

    @Generable
    struct Arguments {
        @Guide(description: "Address or parcel id")
        var query: String
    }

    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments: Arguments) async throws -> String {
        capture.record(name: name, arguments: .object(["query": .string(arguments.query)]))
        throw HaltForJournal()
    }
}

@available(iOS 26, macOS 26, *)
struct SendEmailFMTool: FoundationModels.Tool {
    let capture: FoundationToolCapture
    let name = "sendEmail"
    let description = "Send one email."
    let includesSchemaInInstructions = true

    @Generable
    struct Arguments {
        @Guide(description: "Recipient email address")
        var to: String
        @Guide(description: "Subject line")
        var subject: String
        @Guide(description: "Plain-text body")
        var body: String
    }

    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments: Arguments) async throws -> String {
        capture.record(name: name, arguments: .object([
            "to": .string(arguments.to),
            "subject": .string(arguments.subject),
            "body": .string(arguments.body),
        ]))
        throw HaltForJournal()
    }
}

@available(iOS 26, macOS 26, *)
struct ScheduleClosingFMTool: FoundationModels.Tool {
    let capture: FoundationToolCapture
    let name = "scheduleClosing"
    let description = "Book a closing on the calendar."
    let includesSchemaInInstructions = true

    @Generable
    struct Arguments {
        @Guide(description: "When the closing happens")
        var when: String
        @Guide(description: "Property address")
        var address: String
    }

    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments: Arguments) async throws -> String {
        capture.record(name: name, arguments: .object([
            "when": .string(arguments.when),
            "address": .string(arguments.address),
        ]))
        throw HaltForJournal()
    }
}

@available(iOS 26, macOS 26, *)
enum EscrowOnDeviceModel {
    static func make() -> any ModelStep {
        FoundationModelsStep(
            instructions: EscrowPrompts.instructions,
            gates: [
                "scheduleClosing": FoundationModelsStep.ApprovalGate(
                    approvalID: EscrowScriptedModel.closingApprovalID,
                    prompt: EscrowScriptedModel.closingPrompt
                ),
            ],
            makeTools: { capture in
                [
                    LookupPropertyFMTool(capture: capture),
                    SendEmailFMTool(capture: capture),
                    ScheduleClosingFMTool(capture: capture),
                ]
            }
        )
    }
}
#endif
