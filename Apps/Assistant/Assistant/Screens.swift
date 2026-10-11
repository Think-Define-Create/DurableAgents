import AgentAppKit
import DurableIdentity
import DurableMCP
import DurableMemory
import DurableSchedule
import DurableSkills
import SwiftUI

extension MemoryEdge {
    var rowID: String { "\(from)|\(relation)|\(to)" }
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
            .buttonStyle(.borderless)
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
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle("Soul")
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
            .buttonStyle(.borderless)
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
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle("Skills")
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
        .navigationTitle("Memory")
    }
}

struct RoutinesScreen: View {
    @Bindable var model: AssistantModel

    private var routineBot: Binding<String> {
        Binding(
            get: { model.routineAgentID ?? model.featured?.id ?? "" },
            set: { model.routineAgentID = $0 }
        )
    }

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
            Section("New routine") {
                Picker("Bot", selection: routineBot) {
                    ForEach(model.agents) { agent in
                        Text(agent.title).tag(agent.id)
                    }
                }
                TextField("Id", text: $model.routineID)
                Stepper("Every \(model.routineMinutes) minutes", value: $model.routineMinutes, in: 15...1440, step: 15)
                TextField("Checklist", text: $model.routineChecklist, axis: .vertical)
                Button("Save and run once") { Task { await model.defineRoutine() } }
            }
            if model.routines.isEmpty {
                Text("No routines.")
                    .foregroundStyle(.secondary)
            } else {
                Section("Routines") {
                    ForEach(model.routines, id: \.id) { routine in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(routine.id.rawValue).font(.headline)
                                Spacer()
                                Text(model.agents.first { $0.id == routine.agentID }?.title ?? "No bot")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text(routine.checklist).lineLimit(3)
                            if let result = model.routineResults[routine.id.rawValue] {
                                Text(result)
                                    .font(.callout)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            Button("Run now") { Task { await model.runRoutineNow(routine.id.rawValue) } }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Routines")
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
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle("MCP servers")
    }
}
