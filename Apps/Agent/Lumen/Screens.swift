import AgentAppCore
import DurableMCP
import SwiftUI

struct ApprovalsView: View {
    @Bindable var model: AgentModel

    var body: some View {
        Group {
            if model.inbox.isEmpty {
                ContentUnavailableView(
                    String(localized: "No approvals waiting"),
                    systemImage: "checkmark.shield",
                    description: Text("High-risk requests ask for Face ID or a passcode before they continue.")
                )
            } else {
                List(model.inbox) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.agentTitle).font(.headline)
                        Text(item.prompt)
                        Text("Risk \(item.risk) · auth \(item.requiredAuth)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let escalate = item.escalateTo {
                            Text("Escalates to \(escalate)")
                                .font(.footnote)
                        }
                        if let expires = item.expiresAt {
                            Text("Expires \(expires.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote)
                        }
                        HStack {
                            Button(String(localized: "Approve")) {
                                Task { await model.decide(token: item.token, approved: true, highRisk: item.risk == "high") }
                            }
                            .accessibilityIdentifier("inbox.approve")
                            .modifier(ApproveGlass())
                            Button(String(localized: "Deny"), role: .destructive) {
                                Task { await model.decide(token: item.token, approved: false, highRisk: false) }
                            }
                            .accessibilityIdentifier("inbox.deny")
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Approvals")
    }
}

private struct ApproveGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

struct OnboardingView: View {
    @Bindable var model: AgentModel
    @State private var page = 0
    @State private var anthropic = ""
    @State private var openAI = ""
    @State private var hosts = "example.com"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Lumen").font(.largeTitle)
            Text("A personal agent that keeps working after you leave, and asks before it does something you cannot undo.")
                .font(.body)
            if page == 0 {
                Text("Keys stay in the Keychain under account names. You can skip them and use the offline demo.")
                    .foregroundStyle(.secondary)
                SecureField(String(localized: "Anthropic key"), text: $anthropic)
                    .accessibilityIdentifier("onboarding.anthropic")
                SecureField(String(localized: "OpenAI key"), text: $openAI)
                    .accessibilityIdentifier("onboarding.openai")
            } else {
                Text("Web fetch only calls hosts on this list. Separate them with commas. HTTP is limited to localhost.")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Allow hosts"), text: $hosts)
                    .accessibilityIdentifier("onboarding.hosts")
            }
            HStack {
                if page == 0 {
                    Button(String(localized: "Continue")) { page = 1 }
                        .accessibilityIdentifier("onboarding.continue")
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(String(localized: "Start")) {
                        Task { await model.finishOnboarding(anthropic: anthropic, openAI: openAI, hosts: hosts) }
                    }
                    .accessibilityIdentifier("onboarding.finish")
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LockView: View {
    var model: AgentModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text("Lumen is locked")
            Button(String(localized: "Unlock")) {
                Task { await model.unlock() }
            }
            .accessibilityIdentifier("lock.unlock")
            .buttonStyle(.borderedProminent)
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AgentModel

    var body: some View {
        Form {
            Toggle(String(localized: "On-device only"), isOn: $model.settings.onDeviceOnly)
            Text("Blocks Anthropic, OpenAI, compatible cloud models, web fetch, and HTTP MCP. Apple, the offline demo, local stdio MCP, calendar, reminders, and contacts stay available.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle(String(localized: "Lock with Face ID"), isOn: $model.settings.appLock)
            Stepper(value: $model.settings.retentionDays, in: 1...3650) {
                Text("Keep messages \(model.settings.retentionDays) days")
            }
            TextField(String(localized: "OpenTelemetry endpoint"), text: $model.settings.otelEndpoint)
            Text("Saved for a collector you run. Lumen does not ship an OTLP client.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Section(String(localized: "MCP server")) {
                Text(MCPListenSupport.available
                    ? "Expose this engine on loopback HTTP. stdio clients on iOS are not available."
                    : "Loopback MCP is a macOS feature.")
                Button(model.mcpPort == nil ? String(localized: "Start loopback") : String(localized: "Stop loopback")) {
                    Task { await model.exposeMCP(model.mcpPort == nil) }
                }
                .disabled(!MCPListenSupport.available)
                if let port = model.mcpPort {
                    Text("http://127.0.0.1:\(port)/mcp")
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
            Section(String(localized: "Follow-ups")) {
                Text("CloudKit sync is not in this build. Remote push is not required to sign the app; approvals use local notifications.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(String(localized: "Save settings")) {
                Task { await model.saveSettings() }
            }
            .accessibilityIdentifier("settings.save")
        }
        .navigationTitle("Settings")
    }
}

struct PrivacyView: View {
    @Bindable var model: AgentModel
    @State private var pattern = ""
    @State private var export = ""

    var body: some View {
        Form {
            Section(String(localized: "Redaction")) {
                Text("Built-in rules cover cards, SSNs, emails, and credentials before a payload is sealed. Extra patterns are regular expressions.")
                    .font(.footnote)
                TextField(String(localized: "Extra regex"), text: $pattern)
                Button(String(localized: "Add pattern")) {
                    if !pattern.isEmpty {
                        model.settings.extraRedaction.append(pattern)
                        pattern = ""
                    }
                }
                ForEach(model.settings.extraRedaction, id: \.self) { rule in
                    Text(rule).font(.footnote)
                }
            }
            Section(String(localized: "Retention")) {
                Button(String(localized: "Hold this conversation")) { Task { await model.setHold(true) } }
                Button(String(localized: "Release hold")) { Task { await model.setHold(false) } }
                Button(String(localized: "Purge old messages")) { Task { await model.purge() } }
            }
            Section(String(localized: "Crypto-shred")) {
                Text("Deleting the key leaves ciphertext that cannot be opened. Other conversations stay readable.")
                    .font(.footnote)
                Button(String(localized: "Delete conversation permanently"), role: .destructive) {
                    Task { await model.shred() }
                }
            }
            Section(String(localized: "Audit")) {
                Button(String(localized: "Build export")) {
                    Task { export = await model.exportAudit() ?? "" }
                }
                if !export.isEmpty {
                    ShareLink(item: export) {
                        Text("Share audit")
                    }
                    Text(export).font(.caption2).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Privacy")
    }
}

struct EventLogView: View {
    var model: AgentModel

    var body: some View {
        NavigationStack {
            List(model.events) { event in
                VStack(alignment: .leading) {
                    Text(event.type).font(.headline)
                    Text("#\(event.id)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .overlay {
                if model.events.isEmpty {
                    ContentUnavailableView(String(localized: "No events yet"), systemImage: "list.bullet")
                }
            }
            .navigationTitle("Event log")
        }
    }
}

struct MCPServersView: View {
    var model: AgentModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "tools"
    @State private var transport = "http"
    @State private var url = "http://127.0.0.1:8765/mcp"
    @State private var command = ""
    @State private var allow = ""
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "Server name"), text: $name)
                Picker(String(localized: "Transport"), selection: $transport) {
                    Text("HTTP").tag("http")
                    Text("stdio").tag("stdio")
                }
                if transport == "http" {
                    TextField(String(localized: "URL"), text: $url)
                } else {
                    TextField(String(localized: "Command"), text: $command)
                    Text("stdio launches a process. That is available on macOS, not on iOS.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextField(String(localized: "Allow tools, comma separated"), text: $allow)
                Text("An empty allowlist attaches nothing. Destructive tools still ask for approval.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(String(localized: "Connect and attach")) {
                    let config = MCPServerConfig(
                        name: name,
                        transport: transport,
                        command: transport == "stdio" ? command : nil,
                        url: transport == "http" ? url : nil,
                        allow: allow.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    )
                    Task { status = await model.connectMCP(config) }
                }
                if !status.isEmpty {
                    Text(status)
                }
            }
            .navigationTitle("MCP servers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) { dismiss() }
                }
            }
        }
    }
}
