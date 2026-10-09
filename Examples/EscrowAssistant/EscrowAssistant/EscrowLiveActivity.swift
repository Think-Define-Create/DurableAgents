import ActivityKit
import Foundation

/// Live Activity for a pending escrow approval. ActivityKit is Apple-only and was not compiled in this environment.
@available(iOS 16.2, *)
struct EscrowActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var detail: String
    }

    var title: String
}

@available(iOS 16.2, *)
@MainActor
enum EscrowLiveActivity {
    private static var current: Activity<EscrowActivityAttributes>?

    static func showPending(prompt: String) {
        let attributes = EscrowActivityAttributes(title: "Escrow")
        let state = EscrowActivityAttributes.ContentState(phase: "approval", detail: prompt)
        let content = ActivityContent(state: state, staleDate: nil)
        if let current {
            Task { await current.update(content) }
            return
        }
        current = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    static func showProgress(_ detail: String) {
        guard let current else { return }
        let state = EscrowActivityAttributes.ContentState(phase: "working", detail: detail)
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await current.update(content) }
    }

    static func end(detail: String) {
        guard let current else { return }
        let state = EscrowActivityAttributes.ContentState(phase: "done", detail: detail)
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            await current.end(content, dismissalPolicy: .default)
        }
        self.current = nil
    }
}
