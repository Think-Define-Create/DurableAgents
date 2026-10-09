import DurableCore
import Foundation

public enum IdentityLayer: String, Sendable, Equatable, Codable, CaseIterable {
    case soul
    case identity
    case user
    case rules
    case memoryDigest
    case bootstrap
}

public struct IdentityDocument: Sendable, Equatable, Codable {
    public var layer: IdentityLayer
    public var text: String
    public var version: Int
    public var updatedBy: String

    public init(layer: IdentityLayer, text: String, version: Int, updatedBy: String) {
        self.layer = layer
        self.text = text
        self.version = version
        self.updatedBy = updatedBy
    }
}

public struct IdentityProposal: Sendable, Equatable {
    public var id: String
    public var layer: IdentityLayer
    public var baseVersion: Int
    public var text: String
    public var author: String
}

public struct ContextBudget: Sendable, Equatable {
    public var maxTokens: Int

    public init(maxTokens: Int) {
        self.maxTokens = maxTokens
    }
}

public struct PromptPart: Sendable, Equatable {
    public var layer: IdentityLayer
    public var version: Int
    public var text: String
    public var tokens: Int
    public var truncated: Bool
}

public struct AssembledPrompt: Sendable, Equatable {
    public var system: String
    public var parts: [PromptPart]
    /// Layer versions that went into `system`. A host can journal this next to `model.step.planned`.
    public var audit: JSONValue
}

public struct DiffLine: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case same
        case remove
        case add
    }

    public var kind: Kind
    public var text: String
}

public enum IdentityError: Error, Equatable, Sendable {
    case emptyActor
    case rateLimited(IdentityLayer)
    case unknownProposal(String)
    case unknownVersion(IdentityLayer, Int)
    case unknownFile(String)
}

public enum IdentityFiles {
    public static let soul = "SOUL.md"
    public static let identity = "IDENTITY.md"
    public static let user = "USER.md"
    public static let rules = "AGENTS.md"
    public static let memory = "MEMORY.md"

    public static func layer(for filename: String) -> IdentityLayer? {
        switch filename {
        case soul: return .soul
        case identity: return .identity
        case user: return .user
        case rules: return .rules
        case memory: return .memoryDigest
        default: return nil
        }
    }

    public static func filename(for layer: IdentityLayer) -> String? {
        switch layer {
        case .soul: return soul
        case .identity: return identity
        case .user: return user
        case .rules: return rules
        case .memoryDigest: return memory
        case .bootstrap: return nil
        }
    }
}

enum IdentityStream {
    static let id = StreamID("identity")
}

/// Layered soul, identity, user, and rules. Agent edits are proposals until a person approves them.
/// Nothing in this type applies text that arrived inside a tool result.
public actor IdentityStore {
    public static let proposalsPerHour = 5

    private let engine: Engine
    private let store: any EventStore
    private let clock: any DurableClock

    public init(engine: Engine, store: any EventStore, clock: any DurableClock) {
        self.engine = engine
        self.store = store
        self.clock = clock
    }

    public func replace(layer: IdentityLayer, text: String, editor: String) async throws -> IdentityDocument {
        try requireActor(editor)
        let state = try await load()
        let version = (state.current[layer]?.version ?? 0) + 1
        let document = IdentityDocument(layer: layer, text: text, version: version, updatedBy: editor)
        try await append(document)
        return document
    }

    public func propose(layer: IdentityLayer, text: String, author: String) async throws -> IdentityProposal {
        try requireActor(author)
        let state = try await load()
        let recent = state.proposalTimes[layer, default: []].filter { clock.now().timeIntervalSince($0) < 3600 }
        if recent.count >= Self.proposalsPerHour {
            throw IdentityError.rateLimited(layer)
        }
        let proposal = IdentityProposal(
            id: "prop_" + UUID().uuidString.lowercased(),
            layer: layer,
            baseVersion: state.current[layer]?.version ?? 0,
            text: text,
            author: author
        )
        try await engine.record([
            EventDraft(
                type: EventType.identityProposed,
                payload: .object([
                    "proposalID": .string(proposal.id),
                    "layer": .string(layer.rawValue),
                    "baseVersion": .int(Int64(proposal.baseVersion)),
                    "text": .string(text),
                    "author": .string(author),
                ]),
                recordedAt: clock.now()
            ),
        ], stream: IdentityStream.id)
        return proposal
    }

    /// Applies or rejects a proposal. Approval is explicit. There is no path that promotes a proposal on its own.
    public func decide(proposalID: String, approved: Bool, approver: String) async throws -> IdentityDocument? {
        try requireActor(approver)
        let state = try await load()
        guard let proposal = state.pending[proposalID] else {
            throw IdentityError.unknownProposal(proposalID)
        }
        var drafts = [
            EventDraft(
                type: EventType.identityResolved,
                payload: .object([
                    "proposalID": .string(proposalID),
                    "approved": .bool(approved),
                    "approver": .string(approver),
                ]),
                recordedAt: clock.now()
            ),
        ]
        var document: IdentityDocument?
        if approved {
            let version = (state.current[proposal.layer]?.version ?? 0) + 1
            document = IdentityDocument(layer: proposal.layer, text: proposal.text, version: version, updatedBy: approver)
            drafts.append(setDraft(document!))
        }
        try await engine.record(drafts, stream: IdentityStream.id)
        return document
    }

    public func revert(layer: IdentityLayer, toVersion: Int, editor: String) async throws -> IdentityDocument {
        try requireActor(editor)
        let state = try await load()
        guard let prior = state.history[layer, default: []].first(where: { $0.version == toVersion }) else {
            throw IdentityError.unknownVersion(layer, toVersion)
        }
        let version = (state.current[layer]?.version ?? 0) + 1
        let document = IdentityDocument(layer: layer, text: prior.text, version: version, updatedBy: editor)
        try await append(document)
        return document
    }

    public func current() async throws -> [IdentityDocument] {
        let state = try await load()
        return IdentityLayer.allCases.compactMap { state.current[$0] }
    }

    public func history(_ layer: IdentityLayer) async throws -> [IdentityDocument] {
        try await load().history[layer, default: []]
    }

    public func pending() async throws -> [IdentityProposal] {
        try await load().pending.values.sorted { $0.id < $1.id }
    }

    public func diff(layer: IdentityLayer, from older: Int, to newer: Int) async throws -> [DiffLine] {
        let state = try await load()
        let versions = state.history[layer, default: []]
        guard let before = versions.first(where: { $0.version == older }) else {
            throw IdentityError.unknownVersion(layer, older)
        }
        guard let after = versions.first(where: { $0.version == newer }) else {
            throw IdentityError.unknownVersion(layer, newer)
        }
        return Self.diff(before: before.text, after: after.text)
    }

    public func exportMarkdown() async throws -> [String: String] {
        var files: [String: String] = [:]
        for document in try await current() {
            if let name = IdentityFiles.filename(for: document.layer) {
                files[name] = document.text
            }
        }
        return files
    }

    public func importMarkdown(_ files: [String: String], editor: String) async throws {
        try requireActor(editor)
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            guard let layer = IdentityFiles.layer(for: name) else {
                throw IdentityError.unknownFile(name)
            }
            _ = try await replace(layer: layer, text: text, editor: editor)
        }
    }

    public func assemble(budget: ContextBudget, lightContext: Bool, record: Bool = false) async throws -> AssembledPrompt {
        let state = try await load()
        var remaining = max(0, budget.maxTokens)
        var parts: [PromptPart] = []
        for layer in IdentityLayer.allCases {
            if lightContext && layer == .bootstrap { continue }
            guard let document = state.current[layer] else { continue }
            let body = "# \(layer.rawValue) v\(document.version)\n" + document.text
            let cost = Self.tokens(of: body)
            if remaining <= 0 {
                break
            }
            if cost <= remaining {
                parts.append(PromptPart(layer: layer, version: document.version, text: body, tokens: cost, truncated: false))
                remaining -= cost
            } else {
                let clipped = Self.clip(body, tokens: remaining)
                parts.append(PromptPart(
                    layer: layer,
                    version: document.version,
                    text: clipped,
                    tokens: Self.tokens(of: clipped),
                    truncated: true
                ))
                remaining = 0
            }
        }
        let system = parts.map(\.text).joined(separator: "\n\n")
        let audit: JSONValue = .array(parts.map { part in
            .object([
                "layer": .string(part.layer.rawValue),
                "version": .int(Int64(part.version)),
                "tokens": .int(Int64(part.tokens)),
                "truncated": .bool(part.truncated),
            ])
        })
        if record {
            try await engine.record([
                EventDraft(type: EventType.identityAssembled, payload: audit, recordedAt: clock.now()),
            ], stream: IdentityStream.id)
        }
        return AssembledPrompt(system: system, parts: parts, audit: audit)
    }

    public static func diff(before: String, after: String) -> [DiffLine] {
        let old = before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        var j = 0
        var lines: [DiffLine] = []
        while i < old.count && j < new.count {
            if old[i] == new[j] {
                lines.append(DiffLine(kind: .same, text: old[i]))
                i += 1
                j += 1
            } else if j + 1 < new.count && old[i] == new[j + 1] {
                lines.append(DiffLine(kind: .add, text: new[j]))
                j += 1
            } else if i + 1 < old.count && old[i + 1] == new[j] {
                lines.append(DiffLine(kind: .remove, text: old[i]))
                i += 1
            } else {
                lines.append(DiffLine(kind: .remove, text: old[i]))
                lines.append(DiffLine(kind: .add, text: new[j]))
                i += 1
                j += 1
            }
        }
        while i < old.count {
            lines.append(DiffLine(kind: .remove, text: old[i]))
            i += 1
        }
        while j < new.count {
            lines.append(DiffLine(kind: .add, text: new[j]))
            j += 1
        }
        return lines
    }

    private func append(_ document: IdentityDocument) async throws {
        try await engine.record([setDraft(document)], stream: IdentityStream.id)
    }

    private func setDraft(_ document: IdentityDocument) -> EventDraft {
        EventDraft(
            type: EventType.identitySet,
            payload: .object([
                "layer": .string(document.layer.rawValue),
                "version": .int(Int64(document.version)),
                "text": .string(document.text),
                "updatedBy": .string(document.updatedBy),
            ]),
            recordedAt: clock.now()
        )
    }

    private func requireActor(_ name: String) throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IdentityError.emptyActor
        }
    }

    private struct State {
        var current: [IdentityLayer: IdentityDocument] = [:]
        var history: [IdentityLayer: [IdentityDocument]] = [:]
        var pending: [String: IdentityProposal] = [:]
        var proposalTimes: [IdentityLayer: [Date]] = [:]
    }

    private func load() async throws -> State {
        var state = State()
        for event in try await store.readAll() {
            switch event.type {
            case EventType.identitySet:
                guard let layer = event.payload["layer"]?.stringValue.flatMap(IdentityLayer.init(rawValue:)),
                      let version = event.payload["version"]?.intValue,
                      let text = event.payload["text"]?.stringValue,
                      let updatedBy = event.payload["updatedBy"]?.stringValue
                else { continue }
                let document = IdentityDocument(layer: layer, text: text, version: Int(version), updatedBy: updatedBy)
                state.history[layer, default: []].append(document)
                state.current[layer] = document
            case EventType.identityProposed:
                guard let id = event.payload["proposalID"]?.stringValue,
                      let layer = event.payload["layer"]?.stringValue.flatMap(IdentityLayer.init(rawValue:)),
                      let text = event.payload["text"]?.stringValue,
                      let author = event.payload["author"]?.stringValue
                else { continue }
                state.pending[id] = IdentityProposal(
                    id: id,
                    layer: layer,
                    baseVersion: Int(event.payload["baseVersion"]?.intValue ?? 0),
                    text: text,
                    author: author
                )
                state.proposalTimes[layer, default: []].append(event.recordedAt)
            case EventType.identityResolved:
                if let id = event.payload["proposalID"]?.stringValue {
                    state.pending.removeValue(forKey: id)
                }
            default:
                break
            }
        }
        return state
    }

    private static func tokens(of text: String) -> Int {
        let count = text.utf8.count
        if count == 0 { return 0 }
        return max(1, count / 4)
    }

    private static func clip(_ text: String, tokens: Int) -> String {
        let budget = max(0, tokens) * 4
        var bytes = Array(text.utf8.prefix(budget))
        while !bytes.isEmpty && String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        let clipped = String(bytes: bytes, encoding: .utf8) ?? ""
        return clipped + "\n[truncated]"
    }
}
