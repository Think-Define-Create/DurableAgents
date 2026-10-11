import AgentAppCore
import DurableFoundationModels
import Foundation
import ModelKit
import SwiftUI

/// One model a provider offers, as its models endpoint lists it.
struct RemoteModel: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
}

/// The providers a bot can use. Cloud providers use the person's own key from the Keychain.
enum BotProvider: String, CaseIterable, Identifiable, Sendable {
    case apple
    case anthropic
    case openAI

    var id: String { rawValue }

    init(_ kind: ProviderKind) {
        switch kind {
        case .anthropic: self = .anthropic
        case .openai, .compatible: self = .openAI
        case .apple, .scripted: self = .apple
        }
    }

    var kind: ProviderKind {
        switch self {
        case .apple: .apple
        case .anthropic: .anthropic
        case .openAI: .openai
        }
    }

    var title: String {
        switch self {
        case .apple: "Apple"
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        }
    }

    var keyAccount: String? {
        switch self {
        case .apple: nil
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openAI: "OPENAI_API_KEY"
        }
    }

    var keyHint: String {
        switch self {
        case .apple: ""
        case .anthropic: "sk-ant-…"
        case .openAI: "sk-…"
        }
    }

    func choice(model: String) -> ProviderChoice {
        switch self {
        case .apple: model == ProviderChoice.applePrivateCloud.model ? .applePrivateCloud : .apple
        case .anthropic: .anthropic(model: model)
        case .openAI: .openAI(model: model)
        }
    }
}

/// Lists the models a key can use, newest first.
enum ModelDirectory {
    static func fetch(_ provider: BotProvider, key: String, session: URLSession = .shared) async throws -> [RemoteModel] {
        switch provider {
        case .apple:
            return appleModels()
        case .anthropic:
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let json = try await load(request, session: session)
            return anthropicModels(json)
        case .openAI:
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let json = try await load(request, session: session)
            return openAIModels(json)
        }
    }

    static func appleModels() -> [RemoteModel] {
        var models = [RemoteModel(id: ProviderChoice.apple.model, name: "On-device")]
        if FoundationModelsSupport.privateCloudAvailable {
            models.append(RemoteModel(id: ProviderChoice.applePrivateCloud.model, name: "Private Cloud Compute"))
        }
        return models
    }

    /// The list is already newest first.
    static func anthropicModels(_ json: [String: Any]) -> [RemoteModel] {
        let rows = json["data"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return RemoteModel(id: id, name: row["display_name"] as? String ?? id)
        }
    }

    /// Keeps text models that the Responses API can chat with.
    static func openAIModels(_ json: [String: Any]) -> [RemoteModel] {
        let rows = json["data"] as? [[String: Any]] ?? []
        let skip = ["audio", "realtime", "tts", "transcribe", "image", "embedding", "search", "moderation", "dall-e", "whisper", "instruct", "babbage", "davinci", "codex"]
        let kept = rows.compactMap { row -> (RemoteModel, Double)? in
            guard let id = row["id"] as? String else { return nil }
            let lower = id.lowercased()
            let chat = lower.hasPrefix("gpt-") || lower.hasPrefix("chatgpt") || lower.range(of: #"^o\d"#, options: .regularExpression) != nil
            guard chat, !skip.contains(where: lower.contains) else { return nil }
            let created = (row["created"] as? NSNumber)?.doubleValue ?? 0
            return (RemoteModel(id: id, name: id), created)
        }
        return kept.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private static func load(_ request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String
            throw ModelDirectoryError.http(status, message ?? String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return json
    }
}

enum ModelDirectoryError: Error, CustomStringConvertible {
    case http(Int, String)

    var description: String {
        switch self {
        case .http(401, _), .http(403, _): "The provider rejected this API key."
        case .http(let status, let message): "The provider answered \(status). \(message)"
        }
    }
}

/// Provider first, then a model from that provider's live list.
struct ModelPicker: View {
    var model: AssistantModel
    @Binding var choice: ProviderChoice
    @State private var key = ""

    var body: some View {
        Section {
            Picker("Provider", selection: provider) {
                ForEach(BotProvider.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            Text(footer)
        }

        let current = BotProvider(choice.kind)
        if current == .apple {
            let options = ModelDirectory.appleModels()
            if options.count > 1 {
                Section("Apple models") {
                    ForEach(options) { option in
                        modelRow(option, provider: current)
                    }
                }
            }
        } else {
            if let account = current.keyAccount, !model.savedKeys.contains(account) {
                Section("\(current.title) API key") {
                    SecureField(current.keyHint, text: $key)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    Button("Save Key") {
                        model.saveKey(account: account, value: key)
                        key = ""
                        Task { await model.loadCatalog(current, force: true) }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Section {
                    if model.catalogLoading.contains(current) {
                        HStack {
                            ProgressView()
                            Text("Loading models…").foregroundStyle(Palette.secondaryText)
                        }
                    } else if let error = model.catalogError[current] {
                        Text(error).foregroundStyle(.orange)
                    }
                    ForEach(models(for: current)) { option in
                        modelRow(option, provider: current)
                    }
                } header: {
                    HStack {
                        Text("\(current.title) models")
                        Spacer()
                        Button("Refresh") { Task { await model.loadCatalog(current, force: true) } }
                            .font(.caption)
                    }
                }
                .task(id: current) { await model.loadCatalog(current) }
            }
        }
    }

    private func modelRow(_ option: RemoteModel, provider current: BotProvider) -> some View {
        Button {
            choice = current.choice(model: option.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name).foregroundStyle(.primary)
                    if option.name != option.id, current != .apple {
                        Text(option.id)
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                Spacer()
                if choice.model == option.id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choice.model == option.id ? .isSelected : [])
    }

    private var footer: String {
        switch BotProvider(choice.kind) {
        case .apple where choice.model == ProviderChoice.applePrivateCloud.model:
            "Runs on Apple's Private Cloud Compute. A larger context than on-device. Apple does not keep the request, but it does leave this iPhone."
        case .apple: "Runs on this iPhone. Private and offline, with a small context and no web knowledge."
        case .anthropic: "Claude models, using your Anthropic key."
        case .openAI: "OpenAI models, using your OpenAI key."
        }
    }

    /// The live list, plus the current model when the list does not include it.
    private func models(for provider: BotProvider) -> [RemoteModel] {
        var list = model.catalog[provider] ?? []
        if BotProvider(choice.kind) == provider, !choice.model.isEmpty, !list.contains(where: { $0.id == choice.model }) {
            list.insert(RemoteModel(id: choice.model, name: choice.model), at: 0)
        }
        return list
    }

    private var provider: Binding<BotProvider> {
        Binding(
            get: { BotProvider(choice.kind) },
            set: { next in
                guard next != BotProvider(choice.kind) else { return }
                choice = next.choice(model: model.catalog[next]?.first?.id ?? model.defaultModel(for: next))
            }
        )
    }
}
