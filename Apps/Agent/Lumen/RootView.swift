import AgentAppCore
import DurableCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AgentModel
    @State private var showNew = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView(String(localized: "Opening the journal"))
                .accessibilityLabel(String(localized: "Opening the journal"))
        case .failed(let message):
            ContentUnavailableView(
                String(localized: "Lumen could not open"),
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .locked:
            LockView(model: model)
        case .onboarding:
            OnboardingView(model: model)
        case .ready:
            split
        }
    }

    private var split: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            AgentList(model: model, showNew: $showNew)
        } content: {
            ChatView(model: model)
        } detail: {
            InspectorView(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showNew) {
            NewAgentSheet(model: model)
        }
    }
}

struct AgentList: View {
    @Bindable var model: AgentModel
    @Binding var showNew: Bool

    var body: some View {
        List(selection: Binding(
            get: { model.selectedID },
            set: { id in
                if let id { Task { await model.select(id) } }
            }
        )) {
            if model.recovered {
                Text("Recovered unfinished work from the journal.")
                    .font(.callout)
                    .accessibilityIdentifier("banner.recovered")
            }
            if model.agents.isEmpty {
                ContentUnavailableView(
                    String(localized: "No agents yet"),
                    systemImage: "sparkles",
                    description: Text("Create one to start a durable conversation.")
                )
            }
            ForEach(model.agents) { agent in
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.title)
                        .font(.headline)
                    Text(agent.provider.kind.rawValue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .tag(agent.id)
                .accessibilityLabel(Text("\(agent.title), \(agent.provider.kind.rawValue)"))
            }
        }
        .navigationTitle("Lumen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(localized: "New agent"))
                .accessibilityIdentifier("agent.new")
            }
            ToolbarItem {
                NavigationLink {
                    ApprovalsView(model: model)
                } label: {
                    Image(systemName: "checkmark.shield")
                }
                .badge(model.inbox.count)
                .accessibilityLabel(String(localized: "Approvals"))
                .accessibilityIdentifier("inbox.open")
            }
        }
    }
}

struct ChatView: View {
    @Bindable var model: AgentModel
    @State private var draft = ""
    @State private var showEvents = false
    @State private var showMCP = false

    var body: some View {
        Group {
            if model.selectedID == nil {
                ContentUnavailableView(
                    String(localized: "Choose an agent"),
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Each agent is one durable run. It resumes after a relaunch.")
                )
            } else {
                VStack(spacing: 0) {
                    if let banner = model.banner {
                        Text(banner)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .accessibilityIdentifier("banner.status")
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.messages, id: \.messageID) { message in
                                messageRow(message)
                            }
                            if model.isSending, !model.liveText.isEmpty {
                                Text(model.liveText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .accessibilityLabel(String(localized: "Live reply"))
                                    .accessibilityIdentifier("chat.live")
                            }
                        }
                        .padding()
                    }
                    composer
                }
            }
        }
        .navigationTitle(model.agents.first { $0.id == model.selectedID }?.title ?? "Chat")
        .toolbar {
            ToolbarItemGroup {
                Button(String(localized: "Fork")) { Task { await model.forkSelected() } }
                    .disabled(model.selectedID == nil)
                Button(String(localized: "Archive")) { Task { await model.archiveSelected() } }
                    .disabled(model.selectedID == nil)
                Button(String(localized: "Events")) { showEvents = true }
                Button(String(localized: "MCP")) { showMCP = true }
            }
        }
        .sheet(isPresented: $showEvents) { EventLogView(model: model) }
        .sheet(isPresented: $showMCP) { MCPServersView(model: model) }
    }

    private func messageRow(_ message: TranscriptMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role).font(.caption).foregroundStyle(.secondary)
            Text(message.text).font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(message.role == "user" ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var composer: some View {
        HStack(alignment: .bottom) {
            TextField(String(localized: "Message"), text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("composer.field")
            Button(String(localized: "Send")) {
                let text = draft
                draft = ""
                Task { await model.send(text) }
            }
            .accessibilityIdentifier("composer.send")
            .modifier(PrimaryGlass())
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
            VoiceButton(model: model)
            DocumentButton(model: model)
        }
        .padding()
    }
}

private struct PrimaryGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

struct InspectorView: View {
    @Bindable var model: AgentModel

    var body: some View {
        List {
            Section(String(localized: "Usage")) {
                Text(model.usageDollars, format: .currency(code: "USD"))
                Text(model.usageNote).font(.footnote).foregroundStyle(.secondary)
            }
            Section(String(localized: "Waiting")) {
                if model.inbox.isEmpty {
                    Text("Nothing is waiting on you.")
                } else {
                    ForEach(model.inbox) { item in
                        Text(item.prompt)
                    }
                }
            }
            Section {
                NavigationLink(String(localized: "Privacy")) { PrivacyView(model: model) }
                NavigationLink(String(localized: "Settings")) { SettingsView(model: model) }
            }
        }
        .navigationTitle("Status")
    }
}

struct NewAgentSheet: View {
    @Bindable var model: AgentModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind: ProviderKind = .scripted
    @State private var modelName = "lumen-demo"
    @State private var baseURL = "http://127.0.0.1:11434/v1"

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "Name"), text: $title)
                    .accessibilityIdentifier("agent.title")
                Picker(String(localized: "Model"), selection: $kind) {
                    Text("Offline demo").tag(ProviderKind.scripted)
                    Text("Apple on-device").tag(ProviderKind.apple)
                    Text("Anthropic").tag(ProviderKind.anthropic)
                    Text("OpenAI").tag(ProviderKind.openai)
                    Text("OpenAI-compatible").tag(ProviderKind.compatible)
                }
                TextField(String(localized: "Model id"), text: $modelName)
                if kind == .compatible {
                    TextField(String(localized: "Base URL"), text: $baseURL)
                    Text("Presets: xAI, Groq, OpenRouter, Ollama. Paste the /v1 root.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Create")) {
                        let choice = ProviderChoice(
                            kind: kind,
                            model: modelName,
                            baseURL: kind == .compatible ? baseURL : nil,
                            secretAccount: secretAccount
                        )
                        Task {
                            await model.create(title: title, provider: choice)
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("agent.create")
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var secretAccount: String? {
        switch kind {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openai, .compatible: "OPENAI_API_KEY"
        case .scripted, .apple: nil
        }
    }
}
