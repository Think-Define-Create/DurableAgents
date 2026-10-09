import DurableCore
import DurableKit
import SwiftUI

struct RootView: View {
    @Bindable var app: AppModel

    var body: some View {
        NavigationStack {
            ChatScreen(
                app: app,
                messages: app.conversation.messages,
                status: app.conversation.status,
                pending: app.conversation.pendingApproval,
                failure: app.conversation.failure
            )
            .navigationTitle("Escrow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        EventLogView(events: app.conversation.events)
                    } label: {
                        Text("Event log")
                    }
                    .accessibilityIdentifier("eventLog")
                }
            }
        }
    }
}

private struct ChatScreen: View {
    @Bindable var app: AppModel
    let messages: [TranscriptMessage]
    let status: ConversationRunStatus
    let pending: PendingApprovalInfo?
    let failure: String?
    @State private var draft = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if app.showsRecovery {
                recoveryBanner
            }
            if let pending {
                approvalBanner(pending)
            }
            messageList
            composer
        }
        .background(colorScheme == .dark ? Color.black : Color(red: 0.96, green: 0.95, blue: 0.92))
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(statusTitle)
                .font(.subheadline.weight(.semibold))
            Text(app.conversation.backendLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Menu(app.provider.title) {
                ForEach(EscrowProvider.allCases) { provider in
                    Button(provider.title) {
                        Task { await app.select(provider) }
                    }
                }
            }
            .font(.caption)
            .accessibilityIdentifier("providerPicker")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusTitle: String {
        switch status {
        case .idle: "Ready"
        case .running: "Working"
        case .suspendedForApproval: "Waiting for approval"
        case .failed: "Failed"
        case .done: "Done"
        }
    }

    private var recoveryBanner: some View {
        Text("Recovered the email from the outbox. It was not sent twice.")
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(red: 0.86, green: 0.93, blue: 0.86))
            .foregroundStyle(Color(red: 0.1, green: 0.28, blue: 0.16))
            .accessibilityIdentifier("recoveryBanner")
    }

    private func approvalBanner(_ pending: PendingApprovalInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pending.prompt)
                .font(.subheadline.weight(.semibold))
            Text(
                pending.risk == .high
                    ? "This is high-risk. Face ID or a device passcode is required. A notification has the same actions."
                    : "The run is suspended until you approve or reject. A notification has the same actions."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Approve") {
                    Task { await app.approve() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("approveButton")
                Button("Reject") {
                    Task { await app.reject() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("rejectButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(red: 0.98, green: 0.93, blue: 0.82))
        .foregroundStyle(Color(red: 0.25, green: 0.16, blue: 0.08))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        emptyState
                    }
                    ForEach(messages, id: \.messageID) { message in
                        MessageRow(message: message)
                            .id(message.messageID)
                    }
                    if let failure, status == .failed {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let errorMessage = app.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last?.messageID {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about a file, send the buyer a note, or put a closing on the calendar.")
                .font(.body)
            Text("Try one of these. They hit fake in-app services only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    suggestion("Look up 14 Harbor Lane", id: "suggestLookup")
                    suggestion("Send the buyer an email", id: "suggestEmail")
                    suggestion("Schedule Friday's closing", id: "suggestClosing")
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, prompt: Text("Ask about 14 Harbor Lane"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("messageField")
                    .submitLabel(.send)
                    .onSubmit { Task { await sendDraft() } }
                Button("Send") {
                    Task { await sendDraft() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status == .running)
                .accessibilityIdentifier("sendButton")
            }
            Button("Crash now") {
                Task { await app.crashNow() }
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(status == .running || status == .suspendedForApproval)
            .accessibilityIdentifier("crashNow")
            Text("Arms a crash inside the next email tool, after the intent is journaled and the fake outbox is written. Relaunch should show one send.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.bar)
    }

    private func suggestion(_ title: String, id: String) -> some View {
        Button(title) {
            draft = title
            Task { await sendDraft() }
        }
        .buttonStyle(.bordered)
        .font(.caption)
        .disabled(status == .running)
        .accessibilityIdentifier(id)
    }

    private func sendDraft() async {
        let text = draft
        draft = ""
        await app.send(text)
        if app.errorMessage != nil {
            draft = text
        }
    }
}

private struct MessageRow: View {
    let message: TranscriptMessage

    var body: some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(10)
                .background(bubble)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
        .accessibilityIdentifier(message.text.contains("buyer@example.com") ? "emailReceipt" : "message-\(message.messageID)")
    }

    private var label: String {
        switch message.role {
        case "user": "You"
        case "assistant": "Assistant"
        case "tool": "Tool"
        case "system": "System"
        default: message.role
        }
    }

    private var bubble: Color {
        switch message.role {
        case "user": Color(red: 0.16, green: 0.27, blue: 0.36).opacity(0.16)
        case "tool": Color(red: 0.55, green: 0.32, blue: 0.18).opacity(0.14)
        default: Color.primary.opacity(0.06)
        }
    }
}

struct EventLogView: View {
    let events: [EventEnvelope]

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView(
                    "No events yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Send a message and the journal will fill in here.")
                )
            } else {
                List(events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(event.globalSeq)  \(event.type)")
                            .font(.subheadline.monospaced().weight(.semibold))
                        Text(event.recordedAt.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(event.payload.canonicalJSON())
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Event log")
        .accessibilityIdentifier("eventLogScreen")
    }
}
