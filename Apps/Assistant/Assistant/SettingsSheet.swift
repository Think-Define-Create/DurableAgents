import AgentAppCore
import DurableCore
import SwiftUI

struct SettingsSheet: View {
    @Bindable var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = AppearanceChoice.system.rawValue
    @AppStorage("haptics") private var haptics = true
    @AppStorage(AssistantSpotlight.enabledKey) private var spotlight = true
    @State private var autoTimeZone = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "iphone")
                            .font(.title2)
                            .frame(width: 52, height: 52)
                            .background(Palette.card, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This iPhone").font(.headline)
                            Text("Bots, keys and the journal stay on this device.")
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                    NavigationLink { UsageView(model: model) } label: {
                        LabeledContent("Usage", value: "\(model.agents.count) bots")
                    }
                    NavigationLink { APIKeysView(model: model) } label: {
                        LabeledContent("API Keys", value: "\(model.savedKeys.count) saved")
                    }
                }

                Section {
                    NavigationLink { PluginsView(model: model) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Plugins")
                            Text("Tools and skills for your bots")
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                }

                Section("Bot") {
                    NavigationLink { ApprovalsView(model: model) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Auto-review")
                                Spacer()
                                if !model.inbox.isEmpty {
                                    Text("\(model.inbox.count) waiting")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                            }
                            Text("Risky tool, MCP and external actions always wait for your approval.")
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                    NavigationLink { RulesView() } label: {
                        LabeledContent("Auto-review Rules", value: "\(AutoReviewRule.all.count)")
                    }
                    Toggle(isOn: $autoTimeZone) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set Time Zone Automatically")
                            Text("Routines and quiet hours follow this device's time zone.")
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                    if autoTimeZone {
                        LabeledContent("Time Zone", value: model.host.timeZone)
                    } else {
                        TextField("Time Zone", text: $model.host.timeZone)
                            .onSubmit { Task { await model.saveSettings() } }
                    }
                    NavigationLink("Soul") { IdentityScreen(model: model) }
                    NavigationLink("Memory") { MemoryScreen(model: model) }
                    NavigationLink("Routines") { RoutinesScreen(model: model) }
                }

                Section {
                    NavigationLink { NotificationsView(model: model) } label: {
                        LabeledContent("Notifications", value: model.host.dailyCap == 0 ? "Off" : "Up to \(model.host.dailyCap) a day")
                    }
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceChoice.allCases) { choice in
                            Text(choice.title).tag(choice.rawValue)
                        }
                    }
                    Toggle("Haptics", isOn: $haptics)
                    Toggle("Show Bots in Spotlight", isOn: $spotlight)
                        .onChange(of: spotlight) { _, on in
                            if on {
                                AssistantSpotlight.update(agents: model.agents, previews: model.previews)
                            } else {
                                AssistantSpotlight.removeAll()
                            }
                        }
                    NavigationLink("Diagnostics") { DiagnosticsView(model: model) }
                }

                Section {
                    Toggle(isOn: onDeviceOnly) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("On-device only")
                            Text("Blocks cloud models and network MCP servers.")
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .onAppear {
            autoTimeZone = model.host.timeZone == TimeZone.current.identifier
        }
        .onChange(of: autoTimeZone) { _, auto in
            if auto {
                model.host.timeZone = TimeZone.current.identifier
                Task { await model.saveSettings() }
            }
        }
    }

    private var onDeviceOnly: Binding<Bool> {
        Binding(
            get: { model.settings.onDeviceOnly },
            set: { on in
                model.settings.onDeviceOnly = on
                Task { await model.saveSettings() }
            }
        )
    }
}

struct APIKeysView: View {
    var model: AssistantModel
    @State private var anthropic = ""
    @State private var openAI = ""

    var body: some View {
        Form {
            Section {
                SecureField(model.savedKeys.contains("ANTHROPIC_API_KEY") ? "Saved. Paste to replace." : "sk-ant-…", text: $anthropic)
                    .textContentType(.password)
                Button("Save Anthropic Key") {
                    model.saveKey(account: "ANTHROPIC_API_KEY", value: anthropic)
                    anthropic = ""
                }
                .disabled(anthropic.isEmpty)
                if model.savedKeys.contains("ANTHROPIC_API_KEY") {
                    Button("Remove Anthropic Key", role: .destructive) {
                        model.saveKey(account: "ANTHROPIC_API_KEY", value: "")
                    }
                }
            } header: {
                Text("Anthropic")
            } footer: {
                Text("Used by Claude bots. Create a key at console.anthropic.com.")
            }
            Section {
                SecureField(model.savedKeys.contains("OPENAI_API_KEY") ? "Saved. Paste to replace." : "sk-…", text: $openAI)
                    .textContentType(.password)
                Button("Save OpenAI Key") {
                    model.saveKey(account: "OPENAI_API_KEY", value: openAI)
                    openAI = ""
                }
                .disabled(openAI.isEmpty)
                if model.savedKeys.contains("OPENAI_API_KEY") {
                    Button("Remove OpenAI Key", role: .destructive) {
                        model.saveKey(account: "OPENAI_API_KEY", value: "")
                    }
                }
            } header: {
                Text("OpenAI")
            } footer: {
                Text("Keys are stored in the Keychain on this device only and never written to the journal.")
            }
        }
        .navigationTitle("API Keys")
        .inlineTitle()
    }
}

struct UsageView: View {
    var model: AssistantModel
    @State private var rows: [(agent: AgentProfile, usage: UsageSummary)] = []

    var body: some View {
        Form {
            Section {
                LabeledContent("Input tokens", value: total(\.inputTokens).formatted())
                LabeledContent("Output tokens", value: total(\.outputTokens).formatted())
                LabeledContent("Estimated cost", value: rows.reduce(0) { $0 + $1.usage.estimatedUSD }.formatted(.currency(code: "USD")))
            } footer: {
                Text(UsageLedger.note)
            }
            Section("By bot") {
                ForEach(rows, id: \.agent.id) { row in
                    HStack(spacing: 12) {
                        BlobAvatar(look: model.look(for: row.agent.id), size: 28)
                        Text(row.agent.title)
                        Spacer()
                        Text((row.usage.inputTokens + row.usage.outputTokens).formatted())
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
            }
        }
        .navigationTitle("Usage")
        .inlineTitle()
        .task { rows = await model.usageTotals() }
    }

    private func total(_ key: KeyPath<UsageSummary, Int>) -> Int {
        rows.reduce(0) { $0 + $1.usage[keyPath: key] }
    }
}

struct ApprovalsView: View {
    var model: AssistantModel

    var body: some View {
        Group {
            if model.inbox.isEmpty {
                ContentUnavailableView(
                    "Nothing is waiting",
                    systemImage: "checkmark.shield",
                    description: Text("When a bot wants to run a risky tool, it stops here until you decide.")
                )
            } else {
                List(model.inbox) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.agentTitle).font(.headline)
                        Text(item.prompt)
                        Text(item.risk == "high" ? "High risk · needs Face ID" : "Standard risk")
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                        HStack {
                            Button("Approve") { Task { await model.decide(token: item.token, approved: true, highRisk: item.risk == "high") } }
                            Button("Deny", role: .destructive) { Task { await model.decide(token: item.token, approved: false, highRisk: item.risk == "high") } }
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Auto-review")
        .inlineTitle()
    }
}

/// The approval rules the engine applies. They are fixed in this build.
struct AutoReviewRule: Identifiable {
    var id: String
    var title: String
    var detail: String

    static let all = [
        AutoReviewRule(id: "allow-pure", title: "Read-only tools run", detail: "Calendar and contact lookups, document text, and web pages on your allowed sites run without asking."),
        AutoReviewRule(id: "ask-external", title: "External actions ask first", detail: "Creating reminders or calendar events, and MCP server tools, wait for your approval."),
        AutoReviewRule(id: "high-risk-auth", title: "High risk needs Face ID", detail: "High-risk approvals need Face ID or your passcode, and background catch-up never approves them."),
    ]
}

struct RulesView: View {
    var body: some View {
        List(AutoReviewRule.all) { rule in
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.title).font(.headline)
                Text(rule.detail)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Auto-review Rules")
        .inlineTitle()
    }
}

struct NotificationsView: View {
    @Bindable var model: AssistantModel

    var body: some View {
        Form {
            Section {
                Toggle("Notifications", isOn: enabled)
                if model.host.dailyCap > 0 {
                    Stepper("Up to \(model.host.dailyCap) a day", value: $model.host.dailyCap, in: 1...20)
                }
            } footer: {
                Text("Routines can notify you. Approvals in a chat always show in the app.")
            }
            if model.host.dailyCap > 0 {
                Section("Allowed hours") {
                    TextField("From", text: $model.host.quietStart)
                    TextField("Until", text: $model.host.quietEnd)
                }
            }
        }
        .navigationTitle("Notifications")
        .inlineTitle()
        .onDisappear { Task { await model.saveSettings() } }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.host.dailyCap > 0 },
            set: { on in
                model.host.dailyCap = on ? 3 : 0
                if on { Task { await AssistantNotifications.requestPermission() } }
            }
        )
    }
}
