import AgentAppKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AssistantModel
    @AppStorage("appearance") private var appearance = AppearanceChoice.system.rawValue

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView("Opening the journal")
            case .failed(let message):
                ContentUnavailableView("Could not open Assistant", systemImage: "exclamationmark.triangle", description: Text(message))
            case .ready:
                HomeView(model: model)
            }
        }
        .preferredColorScheme(AppearanceChoice(rawValue: appearance)?.scheme)
    }
}

struct HomeView: View {
    @Bindable var model: AssistantModel
    @State private var path: [String] = []
    @State private var showSettings = false
    @State private var showNewBot = false
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    if !searching, let featured = model.featured {
                        FeaturedBot(model: model, agent: featured) { open(featured.id) }
                            .padding(.top, 8)
                            .padding(.bottom, 20)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { agent in
                            BotRow(model: model, agent: agent) { open(agent.id) }
                        }
                    }
                    if searching, rows.isEmpty {
                        Text("No bots match \u{201C}\(query)\u{201D}.")
                            .foregroundStyle(Palette.secondaryText)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background)
            .safeAreaInset(edge: .top) { header }
            .hidesNavigationBar()
            .navigationDestination(for: String.self) { id in
                ChatView(model: model, agentID: id)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(model: model)
        }
        .sheet(isPresented: $showNewBot) {
            NewBotSheet(model: model) { agent in
                showNewBot = false
                open(agent.id)
            }
        }
        .task { await model.reload() }
        .onChange(of: model.openRequest, initial: true) { _, id in
            guard let id else { return }
            model.openRequest = nil
            open(id)
        }
    }

    private var rows: [AgentProfile] {
        let all = model.sortedAgents.filter { searching || $0.id != model.featured?.id }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard searching, !needle.isEmpty else { return all }
        return all.filter { agent in
            agent.title.lowercased().contains(needle)
                || (model.previews[agent.id]?.text.lowercased().contains(needle) ?? false)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if searching {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondaryText)
                    TextField("Search bots", text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                }
                .padding(.horizontal, 16)
                .frame(height: 46)
                .modifier(GlassCapsule())
                RoundButton(action: closeSearch) { Image(systemName: "xmark") }
                    .accessibilityLabel("Close search")
            } else {
                RoundButton(action: { showSettings = true }) {
                    Image(systemName: "person.crop.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 26))
                        .overlay(alignment: .bottomTrailing) {
                            if !model.inbox.isEmpty {
                                Circle().fill(.blue).frame(width: 11, height: 11)
                                    .overlay(Circle().stroke(Palette.background, lineWidth: 2))
                            }
                        }
                }
                .accessibilityLabel(model.inbox.isEmpty ? "Settings" : "Settings, \(model.inbox.count) waiting for approval")
                Spacer()
                RoundButton(action: openSearch) { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Search")
                RoundButton(action: { showNewBot = true }) { Image(systemName: "plus") }
                    .accessibilityLabel("New bot")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private func open(_ id: String) {
        Task {
            await model.select(id)
            path = [id]
        }
    }

    private func openSearch() {
        searching = true
        searchFocused = true
    }

    private func closeSearch() {
        searching = false
        query = ""
        searchFocused = false
    }
}

private struct FeaturedBot: View {
    var model: AssistantModel
    var agent: AgentProfile
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                BlobAvatar(look: model.look(for: agent.id), size: 112)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(model.look(for: agent.id).color, in: Circle())
                            .overlay(Circle().stroke(Palette.background, lineWidth: 3))
                            .offset(x: 4, y: 2)
                    }
                Text(agent.title)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(agent.title), featured bot")
        .accessibilityIdentifier("bot.\(agent.title)")
    }
}

private struct BotRow: View {
    var model: AssistantModel
    var agent: AgentProfile
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                BlobAvatar(look: model.look(for: agent.id), size: 50)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(agent.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let preview = model.previews[agent.id] {
                            Text(DayLabel.text(for: preview.at))
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bot.\(agent.title)")
        .contextMenu {
            Button(role: .destructive) {
                Task { await model.archive(agent.id) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    private var subtitle: String {
        if !model.pendingApprovals(for: agent.id).isEmpty {
            return String(localized: "Waiting for your approval")
        }
        return model.previews[agent.id]?.text ?? String(localized: "No messages yet")
    }
}

struct NewBotSheet: View {
    var model: AssistantModel
    var onCreate: (AgentProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var look = BotLook(tint: Int.random(in: 0..<BotLook.tints.count), shape: Int.random(in: 0..<BotLook.shapeCount))
    @State private var choice = ProviderChoice.apple
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        BlobAvatar(look: look, size: 96)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    TextField("Name", text: $title)
                        .font(.title3)
                }
                Section("Color") {
                    LookPicker(look: $look)
                }
                ModelPicker(model: model, choice: $choice)
                if OnDevicePolicy.blocksCloud(choice), model.settings.onDeviceOnly {
                    Section {
                        Text("Creating this bot turns off On-device only, so cloud bots can reach the network.")
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
            }
            .navigationTitle("New Bot")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(trimmedTitle.isEmpty || creating || model.needsKey(choice: choice))
                }
            }
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        creating = true
        Task {
            if let agent = await model.createBot(title: trimmedTitle, look: look, choice: choice) {
                onCreate(agent)
            }
            creating = false
        }
    }
}

struct LookPicker: View {
    @Binding var look: BotLook

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ForEach(BotLook.tints.indices, id: \.self) { index in
                    Button {
                        look.tint = index
                    } label: {
                        Circle()
                            .fill(BotLook.tints[index])
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(.primary, lineWidth: look.tint == index ? 2 : 0).padding(-4))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Color \(index + 1)")
                    .accessibilityAddTraits(look.tint == index ? .isSelected : [])
                }
            }
            HStack(spacing: 16) {
                ForEach(0..<BotLook.shapeCount, id: \.self) { shape in
                    Button {
                        look.shape = shape
                    } label: {
                        BlobAvatar(look: BotLook(tint: look.tint, shape: shape), size: 40)
                            .opacity(look.shape == shape ? 1 : 0.35)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Shape \(shape + 1)")
                    .accessibilityAddTraits(look.shape == shape ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
