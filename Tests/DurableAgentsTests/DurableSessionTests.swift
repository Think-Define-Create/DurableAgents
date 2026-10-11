#if canImport(FoundationModels)
import DurableCore
@testable import DurableFoundationModels
import DurableStore
import Foundation
import FoundationModels
import ModelKit
import Testing

@available(macOS 26, iOS 26, *)
@Test func theJournalBecomesAStructuredTranscript() throws {
    let history = TranscriptHistory(messages: [
        ModelMessage(role: .user, text: "My sister is Ana."),
        ModelMessage(role: .assistant, text: "Noted."),
        ModelMessage(role: .user, text: "Ask Bea about her."),
        ModelMessage(role: .assistant, text: "", toolCalls: [ProviderToolCall(id: "c1", name: "bots_ask", argumentsJSON: #"{"bot":"Bea"}"#)]),
        ModelMessage(role: .tool, text: "Bea says hi", toolCallID: "c1", toolName: "bots_ask"),
    ], budget: 10_000)
    // The turn ends on a tool result. The prompt asks about the result without repeating the request,
    // which the on-device guardrail can take as a second request to act.
    #expect(history.prompt.contains("tool result"))

    let kinds = history.entries.map { entry -> String in
        switch entry {
        case .prompt: "prompt"
        case .response: "response"
        case .toolCalls: "toolCalls"
        case .toolOutput: "toolOutput"
        default: "other"
        }
    }
    #expect(kinds == ["prompt", "response", "prompt", "toolCalls", "toolOutput"])
}

@available(macOS 26, iOS 26, *)
@Test func aTightBudgetDropsTheOldestMessages() throws {
    let history = TranscriptHistory(messages: [
        ModelMessage(role: .user, text: String(repeating: "old ", count: 200)),
        ModelMessage(role: .assistant, text: "", toolCalls: [ProviderToolCall(id: "c1", name: "t", argumentsJSON: String(repeating: "x", count: 400))]),
        ModelMessage(role: .tool, text: "result", toolCallID: "c1", toolName: "t"),
        ModelMessage(role: .assistant, text: "Done."),
        ModelMessage(role: .user, text: "Thanks"),
    ], budget: 20)
    #expect(history.prompt == "Thanks")
    #expect(history.entries.count <= 2)
}

/// A tool whose calls are counted, so the test can show it ran exactly once.
@available(macOS 26, iOS 26, *)
private struct SaveNote: FoundationModels.Tool {
    let name = "saveNote"
    let description = "Saves a short note for the person. Use it when asked to save or write down a note."
    let ledger: NoteLedger

    @Generable
    struct Arguments {
        @Guide(description: "The note text")
        var text: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ledger.add(arguments.text)
        return "Saved the note: \(arguments.text)"
    }
}

private actor NoteLedger {
    private(set) var notes: [String] = []
    func add(_ text: String) { notes.append(text) }
}

/// Talks to the real on-device model. Opt in with `LIVE_FM=1 swift test --filter DurableSession`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIVE_FM"] == "1"), .serialized)
struct LiveDurableSession {
    @available(macOS 26, iOS 26, *)
    @Test func anApprovedToolRunsOnceAcrossARestart() async throws {
        guard FoundationModelsSupport.isAvailable() else {
            Issue.record("on-device model unavailable: \(FoundationModelsSupport.unavailableReason() ?? "")")
            return
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("durable-session-\(UUID().uuidString).sqlite").path
        let ledger = NoteLedger()
        let tool = DurableTool(SaveNote(ledger: ledger), effect: .external, requiresApproval: true, reconcile: { _, _ in .notDone })

        let first = try await DurableLanguageModelSession(
            store: try SQLiteEventStore(path: path),
            instructions: "You save notes with the saveNote tool when asked.",
            tools: [tool]
        )
        let asked = try await first.respond(to: "Save a note that says buy milk.")
        guard case .needsApproval(_, let token) = asked else {
            Issue.record("expected an approval, got \(asked)")
            return
        }
        #expect(await ledger.notes.isEmpty)
        // The app is closed while the approval is pending.
        await first.close()

        let second = try await DurableLanguageModelSession(
            store: try SQLiteEventStore(path: path),
            instructions: "You save notes with the saveNote tool when asked.",
            tools: [tool]
        )
        let pending = try await second.recover()
        guard case .needsApproval(_, let again) = pending else {
            Issue.record("the approval was lost on restart: \(String(describing: pending))")
            return
        }
        #expect(again == token)
        let done = try await second.approve(again)
        guard case .text(let reply) = done else {
            Issue.record("expected an answer, got \(done)")
            return
        }
        #expect(await ledger.notes.count == 1)
        #expect(await ledger.notes.first?.lowercased().contains("milk") == true)
        #expect(!reply.isEmpty)
        let log = try await second.transcript()
        #expect(log.contains { $0.role == "tool" && $0.text.contains("Saved the note") })
        await second.close()
    }
}
#endif
