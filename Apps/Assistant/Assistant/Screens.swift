import AgentAppCore
import DurableIdentity
import DurableMCP
import DurableMemory
import DurableSchedule
import DurableSkills
import SwiftUI

extension MemoryEdge {
    var rowID: String { "\(from)|\(relation)|\(to)" }
}

struct RootView: View {
    @Bindable var model: AssistantModel

    var body: some View {
        NavigationSplitView {
            List(AssistantScreen.allCases, selection: $model.screen) { screen in
                Text(screen.title).tag(screen)
            }
            .navigationTitle("Assistant")
        } detail: {
            Group {
                switch model.phase {
                case .loading:
                    ProgressView("Opening the journal")
                case .failed(let message):
                    ContentUnavailableView("Could not open Assistant", systemImage: "exclamationmark.triangle", description: Text(message))
                case .ready:
                    screen
                }
            }
            .navigationTitle(model.screen.title)
            .safeAreaInset(edge: .top) {
                if !model.banner.isEmpty {
                    Text(model.banner)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary)
                }
            }
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch model.screen {
        case .chat: ChatScreen(model: model)
        case .identity: IdentityScreen(model: model)
        case .skills: SkillsScreen(model: model)
        case .memory: MemoryScreen(model: model)
        case .routines: RoutinesScreen(model: model)
        case .mcp: MCPScreen(model: model)
        case .approvals: ApprovalsScreen(model: model)
        case .settings: SettingsScreen(model: model)
        }
    }
}

struct ChatScreen: View {
    @Bindable var model: AssistantModel

    var body: some View {
        VStack(spacing: 0) {
            if model.messages.isEmpty {
                ContentUnavailableView("No messages yet", systemImage: "bubble.left", description: Text("Ask something. The demo model answers on this device without a network."))
            } else {
                List(model.messages, id: \.messageID) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.role).font(.caption).foregroundStyle(.secondary)
                        Text(message.text)
                    }
                }
            }
            HStack {
                TextField("Message", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button("Send") { Task { await model.send() } }
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
    }
}

struct IdentityScreen: View {
    @Bindable var model: AssistantModel

    var body: some View {
        Form {
            Picker("Layer", selection: $model.identityLayer) {
                ForEach(IdentityLayer.allCases, id: \.self) { layer in
                    Text(layer.rawValue).tag(layer)
                }
            }
            TextEditor(text: $model.identityDraft)
                .frame(minHeight: 160)
            HStack {
                Button("Save") { Task { await model.saveIdentity(asPerson: true) } }
                Button("Propose") { Task { await model.saveIdentity(asPerson: false) } }
                Button("Diff") { Task { await model.showIdentityDiff() } }
                Button("Revert") { Task { await model.revertIdentity() } }
            }
            if !model.identityDiff.isEmpty {
                Text(model.identityDiff).font(.caption.monospaced())
            }
            if model.identityProposals.isEmpty {
                Text("No proposals. An agent edit stays here until you approve it.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.identityProposals, id: \.id) { proposal in
                    VStack(alignment: .leading) {
                        Text("\(proposal.layer.rawValue) by \(proposal.author)")
                        Text(proposal.text).lineLimit(4)
                        HStack {
                            Button("Approve") { Task { await model.decideIdentity(proposal.id, approved: true) } }
                            Button("Reject") { Task { await model.decideIdentity(proposal.id, approved: false) } }
                        }
                    }
                }
            }
        }
    }
}

struct SkillsScreen: View {
    @Bindable var model: AssistantModel

    var body: some View {
        Form {
            Text("Scripts are stored as text and are never executed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextEditor(text: $model.skillDraft)
                .frame(minHeight: 160)
            HStack {
                Button("Install") { Task { await model.installSkill(proposed: false) } }
                Button("Propose") { Task { await model.installSkill(proposed: true) } }
            }
            if model.skills.isEmpty {
                Text("No skills installed.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.skills, id: \.name) { skill in
                    VStack(alignment: .leading) {
                        Text(skill.name).font(.headline)
                        Text(skill.description)
                        if !skill.warnings.isEmpty {
                            Text(skill.warnings.joined(separator: " "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if model.skillProposals.isEmpty {
                Text("No skill proposals.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.skillProposals, id: \.id) { proposal in
                    VStack(alignment: .leading) {
                        Text("Proposal \(proposal.name) by \(proposal.author)")
                        HStack {
                            Button("Approve") { Task { await model.decideSkill(proposal.id, approved: true) } }
                            Button("Reject") { Task { await model.decideSkill(proposal.id, approved: false) } }
                        }
                    }
                }
            }
        }
    }
}

struct MemoryScreen: View {
    @Bindable var model: AssistantModel

    var body: some View {
        Form {
            TextField("Remember", text: $model.memoryDraft, axis: .vertical)
            Button("Save fact") { Task { await model.remember() } }
                .disabled(model.memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            TextField("Search", text: $model.memoryQuery)
            Button("Search") { Task { await model.searchMemory() } }
            if model.memories.isEmpty && model.graphNodes.isEmpty {
                Text("Nothing stored yet. Facts are redacted before they are written, and the search index is rebuilt from the journal.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.memories, id: \.id) { record in
                VStack(alignment: .leading) {
                    Text(record.text)
                    Button("Forget") { Task { await model.forget(record.id) } }
                }
            }
            ForEach(model.graphNodes, id: \.name) { node in
                Text("\(node.name) · \(node.type)")
            }
            ForEach(model.graphEdges, id: \.rowID) { edge in
                Text("\(edge.from) \(edge.relation) \(edge.to)")
            }
        }
    }
}

struct RoutinesScreen: View {
    @Bindable var model: AssistantModel

    var body: some View {
        Form {
            Text(model.lastCatchUp)
            if let next = model.nextWake {
                Text("Next best-effort wake \(next.formatted(date: .abbreviated, time: .shortened)). iOS may delay or skip it. Opening the app catches up from the journal.")
            } else {
                Text("No routine is scheduled. A saved routine still depends on the system allowing a background wake.")
                    .foregroundStyle(.secondary)
            }
            Button("Catch up now") { Task { await model.catchUp() } }
            TextField("Id", text: $model.routineID)
            Stepper("Every \(model.routineMinutes) minutes", value: $model.routineMinutes, in: 15...1440, step: 15)
            TextField("Checklist", text: $model.routineChecklist, axis: .vertical)
            Button("Save routine") { Task { await model.defineRoutine() } }
            if model.routines.isEmpty {
                Text("No routines.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.routines, id: \.id) { routine in
                    VStack(alignment: .leading) {
                        Text(routine.id.rawValue).font(.headline)
                        Text(routine.checklist).lineLimit(3)
                    }
                }
            }
        }
    }
}

struct MCPScreen: View {
    @Bindable var model: AssistantModel

    var body: some View {
        Form {
            Text("stdio is not available on iOS. On-device mode blocks network servers. Secrets stay in the Keychain under account names, not in this list.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Name", text: $model.serverName)
            TextField("URL", text: $model.serverURL)
            TextField("Allow tools, comma separated", text: $model.serverAllow)
            Button("Save server") { Task { await model.addServer() } }
            if model.servers.isEmpty {
                Text("No MCP servers.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.servers, id: \.name) { server in
                    VStack(alignment: .leading) {
                        Text(server.name).font(.headline)
                        Text(server.url ?? server.transport)
                        HStack {
                            Button("Connect") { Task { await model.connectServer(server) } }
                            Button("Remove") { Task { await model.removeServer(server.name) } }
                        }
                    }
                }
            }
        }
    }
}

struct ApprovalsScreen: View {
    @Bindable var model: AssistantModel

    var body: some View {
        Group {
            if model.inbox.isEmpty {
                ContentUnavailableView("Nothing is waiting", systemImage: "checkmark.shield", description: Text("External effects and high-risk tools stop here. Unattended catch-up does not approve them."))
            } else {
                List(model.inbox) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.prompt)
                        Text("\(item.agentTitle) · \(item.risk)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Approve") { Task { await model.decide(token: item.token, approved: true, highRisk: item.risk == "high") } }
                            Button("Deny") { Task { await model.decide(token: item.token, approved: false, highRisk: item.risk == "high") } }
                        }
                    }
                }
            }
        }
    }
}

struct SettingsScreen: View {
    @Bindable var model: AssistantModel

    var body: some View {
        Form {
            Toggle("On device only", isOn: $model.settings.onDeviceOnly)
            Toggle("Unattended catch-up", isOn: $model.host.unattended)
            Text("Unattended mode never auto-approves an external effect. Quiet hours are when a notification is allowed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Allowed from", text: $model.host.quietStart)
            TextField("Allowed until", text: $model.host.quietEnd)
            TextField("Time zone", text: $model.host.timeZone)
            Stepper("At most \(model.host.dailyCap) notifications a day", value: $model.host.dailyCap, in: 0...20)
            Button("Use on-device model") { Task { await model.useOnDeviceModel() } }
            Button("Save settings") { Task { await model.saveSettings() } }
        }
    }
}
