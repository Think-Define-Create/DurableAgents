import AgentAppKit
import DurableMCP
import DurableSkills
import SwiftUI

/// Everything a bot can use. Only working tools are listed: built-in device tools, installed skills,
/// and MCP servers the person added.
struct PluginsView: View {
    @Bindable var model: AssistantModel
    @State private var query = ""
    @State private var showWebSites = false

    var body: some View {
        List {
            if !filteredBuiltins.isEmpty {
                Section("On this iPhone") {
                    ForEach(filteredBuiltins) { tool in
                        PluginRow(symbol: tool.symbol, tint: tool.tint, title: tool.title, detail: tool.detail) {
                            if tool.id == BuiltinToolID.webFetch {
                                Button(webSitesLabel) { showWebSites = true }
                                    .buttonStyle(PillButtonStyle(filled: model.settings.webAllowHosts.isEmpty))
                            } else {
                                Text("Added").pill(filled: false)
                            }
                        }
                    }
                }
            }

            Section {
                ForEach(filteredSkills, id: \.name) { skill in
                    PluginRow(symbol: "sparkles", tint: .purple, title: skill.name, detail: skill.description) {
                        Text("Added").pill(filled: false)
                    }
                }
                if !model.skillProposals.isEmpty {
                    NavigationLink { SkillsScreen(model: model) } label: {
                        Label("\(model.skillProposals.count) skill proposal\(model.skillProposals.count == 1 ? "" : "s") to review", systemImage: "tray")
                    }
                }
                NavigationLink { SkillsScreen(model: model) } label: {
                    Label("New skill", systemImage: "plus")
                }
            } header: {
                Text("Skills")
            } footer: {
                Text("Skills are instructions. Scripts are kept as text and never run.")
            }

            Section {
                ForEach(filteredServers, id: \.name) { server in
                    PluginRow(symbol: "server.rack", tint: .teal, title: server.name, detail: server.url ?? server.transport) {
                        if model.connectedServers.contains(server.name) {
                            Text("Added").pill(filled: false)
                        } else {
                            Button("Add") { Task { await model.connectServer(server) } }
                                .buttonStyle(PillButtonStyle(filled: true))
                        }
                    }
                }
                NavigationLink { MCPScreen(model: model) } label: {
                    Label("Add MCP server", systemImage: "plus")
                }
            } header: {
                Text("MCP servers")
            } footer: {
                if model.settings.onDeviceOnly {
                    Text("On-device only is on, so network servers cannot connect. Turn it off in Settings.")
                } else {
                    Text("A server's tools ask for approval before they act.")
                }
            }
        }
        .searchable(text: $query, prompt: "Search plugins")
        .navigationTitle("Plugins")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Text("\(installedCount) installed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .sheet(isPresented: $showWebSites) {
            NavigationStack { WebSitesView(model: model) }
        }
    }

    private var installedCount: Int {
        BuiltinPlugin.all.count + model.skills.count + model.connectedServers.count
    }

    private var webSitesLabel: String {
        let count = model.settings.webAllowHosts.count
        return count == 0 ? "Add" : "\(count) site\(count == 1 ? "" : "s")"
    }

    private func matches(_ text: String...) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || text.contains { $0.lowercased().contains(needle) }
    }

    private var filteredBuiltins: [BuiltinPlugin] {
        BuiltinPlugin.all.filter { matches($0.title, $0.detail) }
    }

    private var filteredSkills: [SkillManifest] {
        model.skills.filter { matches($0.name, $0.description) }
    }

    private var filteredServers: [MCPServerConfig] {
        model.servers.filter { matches($0.name, $0.url ?? "") }
    }
}

struct BuiltinPlugin: Identifiable {
    var id: String
    var symbol: String
    var tint: Color
    var title: String
    var detail: String

    static let all = [
        BuiltinPlugin(id: BuiltinToolID.reminder, symbol: "checklist", tint: .orange, title: "Reminders", detail: "Create reminders. Asks before each one."),
        BuiltinPlugin(id: BuiltinToolID.calendarRead, symbol: "calendar", tint: .red, title: "Calendar", detail: "Read upcoming events and add new ones with approval."),
        BuiltinPlugin(id: BuiltinToolID.contactsSearch, symbol: "person.crop.circle", tint: .gray, title: "Contacts", detail: "Find people by name."),
        BuiltinPlugin(id: BuiltinToolID.documentOCR, symbol: "doc.text.viewfinder", tint: .blue, title: "Document Text", detail: "Read text from photos and scans on device."),
        BuiltinPlugin(id: BuiltinToolID.webFetch, symbol: "globe", tint: .green, title: "Web Pages", detail: "Read pages from sites you allow."),
    ]
}

private struct PluginRow<Accessory: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 4)
    }
}

private struct PillButtonStyle: ButtonStyle {
    var filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pill(filled: filled)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private extension View {
    func pill(filled: Bool) -> some View {
        font(.subheadline.weight(.semibold))
            .foregroundStyle(filled ? Color.primary : Palette.secondaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Palette.card, in: Capsule())
    }
}

struct WebSitesView: View {
    @Bindable var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State private var newHost = ""

    var body: some View {
        Form {
            Section {
                ForEach(model.settings.webAllowHosts, id: \.self) { host in
                    Text(host)
                }
                .onDelete { offsets in
                    model.settings.webAllowHosts.remove(atOffsets: offsets)
                }
                HStack {
                    TextField("example.com", text: $newHost)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(cleanedHost.isEmpty)
                }
            } footer: {
                Text("Bots can read pages only from these sites, over HTTPS. On-device only blocks all of them.")
            }
        }
        .navigationTitle("Allowed Sites")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    Task {
                        await model.saveSettings()
                        dismiss()
                    }
                }
            }
        }
    }

    private var cleanedHost: String {
        var host = newHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        return host.split(separator: "/").first.map(String.init) ?? ""
    }

    private func add() {
        let host = cleanedHost
        guard !host.isEmpty, !model.settings.webAllowHosts.contains(host) else { return }
        model.settings.webAllowHosts.append(host)
        newHost = ""
    }
}
