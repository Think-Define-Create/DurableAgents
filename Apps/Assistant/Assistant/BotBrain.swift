import AgentAppKit
import DurableCore
import DurableIdentity
import DurableMemory
import DurableSkills
import Foundation

/// What every bot reads before it answers: the soul and other identity layers, saved memories,
/// and installed skills. The model step reads it without calling back into the app.
actor BotBrain {
    private var layers: [IdentityDocument] = []
    private var skills: [SkillManifest] = []
    private let memory: MemoryIndex

    init(memory: MemoryIndex) {
        self.memory = memory
    }

    func update(layers: [IdentityDocument]) {
        self.layers = layers
    }

    func update(skills: [SkillManifest]) {
        self.skills = skills
    }

    /// The text appended to a bot's instructions. Compact mode keeps the on-device prompt
    /// inside its 4,096-token window.
    func instructions(for turn: TurnContext, now: Date = Date()) async -> String {
        let limit = turn.compact ? 1_200 : 12_000
        var sections: [String] = []
        let zone = TimeZone.current
        sections.append("Now: \(ToolDates.describe(now, timeZone: zone)) (\(zone.identifier)). Write times for tools as local time like 2026-10-11T15:00.")

        for layer in Self.order {
            guard let document = layers.first(where: { $0.layer == layer }) else { continue }
            let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            sections.append("\(Self.heading(layer)):\n\(Self.clip(text, limit))")
        }

        let facts = await memories(for: turn.latestUserText, compact: turn.compact)
        if !facts.isEmpty {
            let lines = facts.map { "- \($0.text)" }.joined(separator: "\n")
            sections.append("What you remember about the person (saved memories):\n\(Self.clip(lines, limit))")
        }

        if !skills.isEmpty {
            let lines = skills.map { skill -> String in
                let body = skill.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if turn.compact || body.isEmpty {
                    return "- \(skill.name): \(skill.description)"
                }
                return "- \(skill.name): \(skill.description)\n\(Self.clip(body, 2_000))"
            }.joined(separator: "\n")
            sections.append("Skills you can follow (instructions only):\n\(Self.clip(lines, limit))")
        }

        sections.append("Only when the person tells you a new fact worth keeping, call memory.remember with that one short fact.")
        return sections.joined(separator: "\n\n")
    }

    private func memories(for query: String, compact: Bool) async -> [MemoryRecord] {
        let cap = compact ? 6 : 30
        guard let all = try? await memory.items(), !all.isEmpty else { return [] }
        if all.count <= cap {
            return all.sorted { $0.importance > $1.importance }
        }
        var picked = (try? await memory.search(query, limit: cap / 2)) ?? []
        for record in all.sorted(by: { $0.importance > $1.importance }) where picked.count < cap {
            if !picked.contains(where: { $0.id == record.id }) {
                picked.append(record)
            }
        }
        return picked
    }

    static let order: [IdentityLayer] = [.soul, .identity, .user, .rules, .memoryDigest]

    static func heading(_ layer: IdentityLayer) -> String {
        switch layer {
        case .soul: "Your soul (who you are and how you speak)"
        case .identity: "Your identity"
        case .user: "About the person you help"
        case .rules: "Rules you always follow"
        case .memoryDigest: "Memory digest"
        case .bootstrap: "Setup notes"
        }
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

enum MemoryTool {
    static let name = "memory.remember"

    /// Saves one fact through the journal. The memory index is rebuilt from the journal after the turn.
    static func make() -> Tool {
        Tool(
            name: name,
            effect: .transactional,
            summary: "Save one short fact about the person so every bot remembers it.",
            parametersJSON: #"{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}"#
        ) { arguments, context in
            let fact = arguments["fact"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !fact.isEmpty else {
                return ToolReturn(output: .object(["error": .string("fact is empty")]))
            }
            let id = "mem_" + String(ContentSHA256.hex(context.key.raw).prefix(24))
            return ToolReturn(
                output: .object(["saved": .string(fact)]),
                writes: [
                    StateWrite(namespace: "memory.item", key: id, value: .object([
                        "text": .string(MemoryRedaction.redact(fact)),
                        "kind": .string("fact"),
                        "conversationID": .string(context.conversationID.raw),
                        "importance": .double(0.6),
                    ])),
                ]
            )
        }
    }
}
