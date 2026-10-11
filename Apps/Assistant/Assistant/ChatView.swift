import AgentAppCore
import DurableCore
import PhotosUI
import SwiftUI

struct ChatView: View {
    @Bindable var model: AssistantModel
    var agentID: String
    @Environment(\.dismiss) private var dismiss
    @State private var showBotSettings = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if model.messages.isEmpty, !model.isSending {
                        EmptyChat(model: model, agent: agent)
                    }
                    ForEach(visibleMessages, id: \.messageID) { message in
                        if message.role == "tool", let exchange = message.callID.flatMap({ model.exchanges[$0] }) {
                            BotExchangeCard(model: model, exchange: exchange, reply: message.text)
                        } else if message.role == "tool" {
                            ToolChip(message: message)
                        } else if message.role == "user", let incoming = BotMessage.decode(message.text) {
                            IncomingBotBubble(model: model, fromID: incoming.from, text: incoming.text)
                        } else {
                            MessageBubble(message: message)
                        }
                    }
                    if model.isSending {
                        LiveBubble(text: model.liveText)
                    }
                    ForEach(model.pendingApprovals(for: agentID)) { item in
                        ApprovalCard(model: model, item: item)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.count) { scrollDown(proxy) }
            .onChange(of: model.liveText) { scrollDown(proxy) }
        }
        .background(Palette.background)
        .safeAreaInset(edge: .top) { header }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if model.needsKey(agentID) {
                    KeyNotice(model: model, agentID: agentID)
                }
                if !model.banner.isEmpty {
                    Text(model.banner)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                }
                Composer(model: model, placeholder: "Ask \(agent?.title ?? "your bot")")
            }
        }
        .hidesNavigationBar()
        .onChange(of: agent == nil) { _, gone in
            if gone { dismiss() }
        }
        .sheet(isPresented: $showBotSettings) {
            BotSettingsSheet(model: model, agentID: agentID)
        }
    }

    private let bottomID = "bottom"

    private var agent: AgentProfile? {
        model.agents.first { $0.id == agentID }
    }

    /// Tool results show as small chips, so the person can see what a bot looked up.
    private var visibleMessages: [TranscriptMessage] {
        model.messages.filter { $0.role == "user" || $0.role == "tool" || ($0.role == "assistant" && !$0.text.isEmpty) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundButton(action: { dismiss() }) { Image(systemName: "chevron.left") }
                .accessibilityLabel("Back")
            Spacer(minLength: 0)
            Button { showBotSettings = true } label: {
                HStack(spacing: 10) {
                    BlobAvatar(look: model.look(for: agentID), size: 30)
                    Text(agent?.title ?? "")
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 18)
                .frame(height: 46)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .modifier(GlassCapsule())
            .accessibilityLabel("\(agent?.title ?? "Bot") settings")
            Spacer(minLength: 0)
            RoundButton(action: { showBotSettings = true }) { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("Bot settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

private struct MessageBubble: View {
    var message: TranscriptMessage

    var body: some View {
        let mine = message.role == "user"
        HStack {
            if mine { Spacer(minLength: 48) }
            Text(message.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.body)
                .foregroundStyle(mine ? Palette.userText : .primary)
                .textSelection(.enabled)
                .padding(.horizontal, mine ? 18 : 16)
                .padding(.vertical, mine ? 11 : 14)
                .background(
                    mine ? Palette.userBubble : Palette.card,
                    in: RoundedRectangle(cornerRadius: mine ? 24 : 22, style: .continuous)
                )
            if !mine { Spacer(minLength: 32) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mine ? "You: \(message.text)" : message.text)
        .accessibilityIdentifier(mine ? "message.user" : "message.reply")
    }
}

/// A message another bot sent to this bot. This bot's reply follows as a normal bubble.
private struct IncomingBotBubble: View {
    var model: AssistantModel
    var fromID: String
    var text: String

    var body: some View {
        let name = model.agents.first { $0.id == fromID }?.title ?? "Another bot"
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                BlobAvatar(look: model.look(for: fromID), size: 18)
                Text("\(name) asked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
            }
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Palette.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Palette.secondaryText.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) asked: \(text)")
        .accessibilityIdentifier("incoming")
    }
}

/// This bot asked another bot something. Shows the question and the other bot's answer.
private struct BotExchangeCard: View {
    var model: AssistantModel
    var exchange: BotExchange
    var reply: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let id = exchange.toAgentID {
                    BlobAvatar(look: model.look(for: id), size: 18)
                }
                Text("Asked \(exchange.toName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
            }
            Text(exchange.message)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
            Divider()
            Text(reply)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.trailing, 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Asked \(exchange.toName): \(exchange.message). \(exchange.toName) replied: \(reply)")
        .accessibilityIdentifier("exchange")
    }
}

private struct ToolChip: View {
    var message: TranscriptMessage
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                Label(open ? "Hide tool result" : "Used a tool", systemImage: "wrench.and.screwdriver")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            .buttonStyle(.plain)
            if open {
                Text(message.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(Palette.secondaryText)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
    }
}

private struct LiveBubble: View {
    var text: String

    var body: some View {
        HStack {
            Group {
                if text.isEmpty {
                    TypingDots()
                } else {
                    Text(text)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Spacer(minLength: 32)
        }
        .accessibilityLabel(text.isEmpty ? "Thinking" : text)
        .accessibilityIdentifier("live")
    }
}

private struct TypingDots: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Palette.secondaryText)
                    .frame(width: 7, height: 7)
                    .opacity(phase ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2), value: phase)
            }
        }
        .frame(height: 20)
        .onAppear { phase = true }
    }
}

private struct EmptyChat: View {
    var model: AssistantModel
    var agent: AgentProfile?

    var body: some View {
        VStack(spacing: 12) {
            BlobAvatar(look: model.look(for: agent?.id ?? ""), size: 80)
            Text(agent?.title ?? "")
                .font(.title2.weight(.semibold))
            Text(model.modelTitle(for: agent?.provider ?? .apple))
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(.top, 80)
    }
}

private struct ApprovalCard: View {
    var model: AssistantModel
    var item: InboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(item.risk == "high" ? "High-risk action" : "Needs your approval", systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))
            Text(item.prompt)
            HStack(spacing: 10) {
                Button("Approve") {
                    Task { await model.decide(token: item.token, approved: true, highRisk: item.risk == "high") }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.userBubble)
                Button("Deny", role: .destructive) {
                    Task { await model.decide(token: item.token, approved: false, highRisk: item.risk == "high") }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct KeyNotice: View {
    var model: AssistantModel
    var agentID: String
    @State private var showKeys = false

    var body: some View {
        Button { showKeys = true } label: {
            Label("Add your \(BotProvider(model.choice(for: agentID).kind).title) API key so this bot can answer.", systemImage: "key")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .sheet(isPresented: $showKeys) {
            NavigationStack { APIKeysView(model: model) }
        }
    }
}

struct Composer: View {
    @Bindable var model: AssistantModel
    var placeholder: String
    @State private var dictation = Dictation()
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var reading = false
    @State private var sent = 0
    @AppStorage("haptics") private var haptics = true
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Menu {
                Button { showPhotos = true } label: { Label("Attach Image", systemImage: "photo.on.rectangle") }
                #if os(iOS)
                if CameraPicker.isAvailable {
                    Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                }
                #endif
                Button { showFiles = true } label: { Label("Choose File", systemImage: "folder") }
            } label: {
                Group {
                    if reading {
                        ProgressView()
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
            }
            .modifier(GlassCircle())
            .accessibilityLabel("Attach")

            HStack(alignment: .bottom, spacing: 6) {
                TextField(placeholder, text: $model.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .accessibilityIdentifier("composer")
                    .focused($focused)
                    .padding(.vertical, 15)
                    .padding(.leading, 20)
                Button(action: toggleDictation) {
                    Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic")
                        .font(.system(size: 19))
                        .foregroundStyle(dictation.isListening ? .red : Palette.secondaryText)
                        .frame(width: 36, height: 52)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dictation.isListening ? "Stop dictation" : "Dictate")
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Palette.userText)
                        .frame(width: 42, height: 42)
                        .background(Palette.userBubble.opacity(canSend ? 1 : 0.25), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.bottom, 5)
                .padding(.trailing, 5)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("send")
            }
            .modifier(GlassComposer())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            read(label: "image") {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return "" }
                return await AttachmentReader.text(fromImage: data)
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: AttachmentReader.fileTypes) { result in
            guard case .success(let url) = result else { return }
            read(label: url.lastPathComponent) { await AttachmentReader.text(fromFile: url) }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                read(label: "photo") { await AttachmentReader.text(fromImage: data) }
            }
            .ignoresSafeArea()
        }
        #endif
        .onChange(of: dictation.text) { _, text in
            if dictation.isListening { model.draft = text }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sent) { _, _ in haptics }
    }

    private var canSend: Bool {
        !model.isSending && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        dictation.stop()
        let text = model.draft
        model.draft = ""
        sent += 1
        Task {
            // The keyboard can commit a pending autocorrection after the field was cleared,
            // which puts the sent text back. Clear it again once that has happened.
            try? await Task.sleep(for: .milliseconds(150))
            if model.draft == text { model.draft = "" }
        }
        Task { await model.send(text) }
    }

    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
            return
        }
        Task {
            if !(await dictation.start()) {
                model.banner = "Dictation needs microphone and speech recognition access in Settings."
            }
        }
    }

    private func read(label: String, _ work: @escaping @MainActor () async -> String) {
        reading = true
        Task {
            let text = await work()
            model.attach(text, label: label)
            reading = false
            focused = true
        }
    }
}

private struct GlassComposer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}

struct BotSettingsSheet: View {
    var model: AssistantModel
    var agentID: String
    @Environment(\.dismiss) private var dismiss
    @State private var look = BotLook(tint: 0, shape: 0)
    @State private var confirmArchive = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            BlobAvatar(look: look, size: 88)
                            Text(agent?.title ?? "").font(.title3.weight(.semibold))
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Color") {
                    LookPicker(look: $look)
                }
                ModelPicker(model: model, choice: choice)
                Section {
                    Button("Archive Bot", role: .destructive) { confirmArchive = true }
                } footer: {
                    Text("Archiving hides the bot. Its journal stays on this device.")
                }
            }
            .navigationTitle("Bot")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Archive \(agent?.title ?? "this bot")?", isPresented: $confirmArchive, titleVisibility: .visible) {
                Button("Archive", role: .destructive) {
                    Task {
                        await model.archive(agentID)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { look = model.look(for: agentID) }
        .onChange(of: look) { _, newLook in model.setLook(newLook, for: agentID) }
    }

    private var agent: AgentProfile? {
        model.agents.first { $0.id == agentID }
    }

    private var choice: Binding<ProviderChoice> {
        Binding(
            get: { model.choice(for: agentID) },
            set: { next in Task { await model.setChoice(next, for: agentID) } }
        )
    }
}
