import DurableCore
import Foundation

/// A parsed `SKILL.md`. Parsing is lenient: problems become warnings, and scripts are never executed.
public struct SkillManifest: Sendable, Equatable {
    public var name: String
    public var description: String
    public var license: String?
    public var compatibility: String?
    public var metadata: [String: String]
    public var allowedTools: [String]?
    public var body: String
    public var warnings: [String]
    public var contentSHA256: String
    public var scripts: [String]
    public var resources: [String: String]
    /// Always false. This package does not run `scripts/` on any platform.
    public var executable: Bool { false }

    public var version: Int
    public var approvedByUser: Bool

    /// Intersection with the tools the host already registered. A skill cannot add a tool.
    public func narrowed(_ registered: [String]) -> [String] {
        guard let allowedTools else { return registered.sorted() }
        let allow = Set(allowedTools)
        return registered.filter { allow.contains($0) }.sorted()
    }
}

public struct SkillProposal: Sendable, Equatable {
    public var id: String
    public var name: String
    public var markdown: String
    public var files: [String: String]
    public var author: String
}

public enum SkillError: Error, Equatable, Sendable {
    case emptyActor
    case missingSkill(String)
    case missingResource(String, String)
    case rateLimited(String)
    case unknownProposal(String)
    case unknownVersion(String, Int)
    case notMarkdown
}

public enum SkillParser {
    public static func parse(directoryName: String, markdown: String, files: [String: String] = [:]) -> SkillManifest {
        var warnings: [String] = []
        let split = splitFrontmatter(markdown, warnings: &warnings)
        var fields: [String: String] = [:]
        var metadata: [String: String] = [:]
        var inMetadata = false
        for line in split.frontmatter.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("  "), inMetadata {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    metadata[parts[0]] = unquote(parts[1])
                }
                continue
            }
            inMetadata = false
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = unquote(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            if key == "metadata" && value.isEmpty {
                inMetadata = true
                continue
            }
            fields[key] = value
        }
        let name = fields["name"] ?? directoryName
        if name.count > 64 || name.range(of: "^[a-z0-9-]+$", options: .regularExpression) == nil {
            warnings.append("name \(name) is not a 1-64 character [a-z0-9-] slug")
        }
        if name != directoryName {
            warnings.append("name \(name) does not match directory \(directoryName)")
        }
        let description = fields["description"] ?? ""
        if description.count > 1024 {
            warnings.append("description is longer than 1024 characters")
        }
        if let compatibility = fields["compatibility"], compatibility.count > 500 {
            warnings.append("compatibility is longer than 500 characters")
        }
        let allowed = fields["allowed-tools"].map { raw -> [String] in
            raw.replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
        }
        let scripts = files.keys.filter { $0.hasPrefix("scripts/") }.sorted()
        if !scripts.isEmpty {
            warnings.append("scripts are instruction-only and will not be executed")
        }
        var resources: [String: String] = [:]
        for (path, text) in files where !path.hasPrefix("scripts/") && path != "SKILL.md" {
            resources[path] = text
        }
        return SkillManifest(
            name: name,
            description: description,
            license: fields["license"],
            compatibility: fields["compatibility"],
            metadata: metadata,
            allowedTools: allowed,
            body: split.body.trimmingCharacters(in: .whitespacesAndNewlines),
            warnings: warnings,
            contentSHA256: ContentSHA256.hex(markdown),
            scripts: scripts,
            resources: resources,
            version: 1,
            approvedByUser: false
        )
    }

    private static func splitFrontmatter(_ markdown: String, warnings: inout [String]) -> (frontmatter: String, body: String) {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            warnings.append("SKILL.md has no YAML frontmatter")
            return ("", markdown)
        }
        var end = 1
        while end < lines.count && lines[end].trimmingCharacters(in: .whitespaces) != "---" {
            end += 1
        }
        if end >= lines.count {
            warnings.append("SKILL.md frontmatter is not closed")
            return (lines.dropFirst().joined(separator: "\n"), "")
        }
        let front = lines[1..<end].joined(separator: "\n")
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (front, body)
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

/// Journaled skill registry. Agent edits are proposals. `scripts/` is recorded and never run.
public actor SkillLibrary {
    public static let proposalsPerHour = 5

    private let engine: Engine
    private let store: any EventStore
    private let clock: any DurableClock

    public init(engine: Engine, store: any EventStore, clock: any DurableClock) {
        self.engine = engine
        self.store = store
        self.clock = clock
    }

    public func install(directoryName: String, markdown: String, files: [String: String] = [:], editor: String) async throws -> SkillManifest {
        try requireActor(editor)
        var manifest = SkillParser.parse(directoryName: directoryName, markdown: markdown, files: files)
        let state = try await load()
        manifest.version = (state.current[manifest.name]?.version ?? 0) + 1
        manifest.approvedByUser = true
        try await engine.record([
            definedDraft(manifest, markdown: markdown, files: files, editor: editor),
        ], stream: SkillStream.id)
        return manifest
    }

    public func importDirectory(_ url: URL, editor: String) async throws -> SkillManifest {
        let markdownURL = url.appendingPathComponent("SKILL.md")
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        let files = Self.supportingFiles(in: url)
        return try await install(directoryName: url.lastPathComponent, markdown: markdown, files: files, editor: editor)
    }

    /// Synchronous because Darwin's directory enumerator cannot be iterated in an async context.
    private static func supportingFiles(in url: URL) -> [String: String] {
        var files: [String: String] = [:]
        let root = url.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return files
        }
        for case let file as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            let relative = String(file.standardizedFileURL.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative == "SKILL.md" { continue }
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                files[relative] = text
            }
        }
        return files
    }

    public func propose(directoryName: String, markdown: String, files: [String: String] = [:], author: String) async throws -> SkillProposal {
        try requireActor(author)
        let parsed = SkillParser.parse(directoryName: directoryName, markdown: markdown, files: files)
        let state = try await load()
        let recent = state.proposalTimes[parsed.name, default: []].filter { clock.now().timeIntervalSince($0) < 3600 }
        if recent.count >= Self.proposalsPerHour {
            throw SkillError.rateLimited(parsed.name)
        }
        let proposal = SkillProposal(
            id: "skill_" + UUID().uuidString.lowercased(),
            name: parsed.name,
            markdown: markdown,
            files: files,
            author: author
        )
        try await engine.record([
            EventDraft(
                type: EventType.skillProposed,
                payload: .object([
                    "proposalID": .string(proposal.id),
                    "name": .string(parsed.name),
                    "directory": .string(directoryName),
                    "markdown": .string(markdown),
                    "author": .string(author),
                    "files": filesJSON(files),
                ]),
                recordedAt: clock.now()
            ),
        ], stream: SkillStream.id)
        return proposal
    }

    public func decide(proposalID: String, approved: Bool, approver: String) async throws -> SkillManifest? {
        try requireActor(approver)
        let state = try await load()
        guard let proposal = state.pending[proposalID] else { throw SkillError.unknownProposal(proposalID) }
        var drafts = [
            EventDraft(
                type: EventType.skillResolved,
                payload: .object([
                    "proposalID": .string(proposalID),
                    "approved": .bool(approved),
                    "approver": .string(approver),
                ]),
                recordedAt: clock.now()
            ),
        ]
        var manifest: SkillManifest?
        if approved {
            let files = proposal.files.isEmpty ? (state.stored[proposal.name]?.files ?? [:]) : proposal.files
            var parsed = SkillParser.parse(directoryName: proposal.name, markdown: proposal.markdown, files: files)
            parsed.version = (state.current[proposal.name]?.version ?? 0) + 1
            parsed.approvedByUser = true
            drafts.append(definedDraft(parsed, markdown: proposal.markdown, files: files, editor: approver))
            manifest = parsed
        }
        try await engine.record(drafts, stream: SkillStream.id)
        return manifest
    }

    public func revert(name: String, toVersion: Int, editor: String) async throws -> SkillManifest {
        try requireActor(editor)
        let state = try await load()
        guard let prior = state.history[name, default: []].first(where: { $0.manifest.version == toVersion }) else {
            throw SkillError.unknownVersion(name, toVersion)
        }
        var manifest = prior.manifest
        manifest.version = (state.current[name]?.version ?? 0) + 1
        manifest.approvedByUser = true
        try await engine.record([
            definedDraft(manifest, markdown: prior.markdown, files: prior.files, editor: editor),
        ], stream: SkillStream.id)
        return manifest
    }

    public func list() async throws -> [SkillManifest] {
        try await load().current.values.sorted { $0.name < $1.name }
    }

    public func pending() async throws -> [SkillProposal] {
        try await load().pending.values.sorted { $0.id < $1.id }
    }

    /// Level 1. Names and descriptions only.
    public func metadataBlock() async throws -> String {
        let skills = try await list()
        if skills.isEmpty { return "Skills:\n(none)" }
        return "Skills:\n" + skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    }

    /// Level 2. Journals `skill.activated`. Does not run scripts.
    public func activate(_ name: String) async throws -> SkillManifest {
        let manifest = try await require(name)
        try await engine.record([
            EventDraft(
                type: EventType.skillActivated,
                payload: .object([
                    "name": .string(name),
                    "version": .int(Int64(manifest.version)),
                    "sha256": .string(manifest.contentSHA256),
                    "executable": .bool(false),
                ]),
                recordedAt: clock.now()
            ),
        ], stream: SkillStream.id)
        return manifest
    }

    /// Level 3. Returns file text. Script paths stay `executable: false`.
    public func readResource(_ name: String, path: String) async throws -> (text: String, executable: Bool) {
        let stored = try await requireStored(name)
        guard let text = stored.files[path] ?? (path == "SKILL.md" ? stored.markdown : nil) else {
            throw SkillError.missingResource(name, path)
        }
        try await engine.record([
            EventDraft(
                type: EventType.skillResource,
                payload: .object([
                    "name": .string(name),
                    "path": .string(path),
                    "executable": .bool(false),
                ]),
                recordedAt: clock.now()
            ),
        ], stream: SkillStream.id)
        return (text, false)
    }

    public func exportFolder(_ name: String) async throws -> [String: String] {
        let stored = try await requireStored(name)
        var files = stored.files
        files["SKILL.md"] = stored.markdown
        return files
    }

    /// Tools the model may call. They read the journal and do not call back into the engine.
    public nonisolated func tools() -> [Tool] {
        let library = self
        return [
            Tool(
                name: "skill.activate",
                effect: .pure,
                summary: "Load a skill's instructions. Scripts in the skill are not executed.",
                parametersJSON: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#
            ) { input, _ in
                let name = input["name"]?.stringValue ?? ""
                let manifest = try await library.manifest(name)
                return ToolReturn(output: .object([
                    "name": .string(manifest.name),
                    "body": .string(manifest.body),
                    "sha256": .string(manifest.contentSHA256),
                    "executable": .bool(false),
                    "allowedTools": .array((manifest.allowedTools ?? []).map(JSONValue.string)),
                ]))
            },
            Tool(
                name: "skill.read_resource",
                effect: .pure,
                summary: "Read a skill reference or script as text. Nothing is executed.",
                parametersJSON: #"{"type":"object","properties":{"name":{"type":"string"},"path":{"type":"string"}},"required":["name","path"]}"#
            ) { input, _ in
                let name = input["name"]?.stringValue ?? ""
                let path = input["path"]?.stringValue ?? ""
                let stored = try await library.storedFiles(name)
                guard let text = stored[path] else { throw SkillError.missingResource(name, path) }
                return ToolReturn(output: .object([
                    "path": .string(path),
                    "text": .string(text),
                    "executable": .bool(false),
                ]))
            },
        ]
    }

    public func manifest(_ name: String) async throws -> SkillManifest {
        try await require(name)
    }

    public func storedFiles(_ name: String) async throws -> [String: String] {
        try await requireStored(name).files
    }

    private func require(_ name: String) async throws -> SkillManifest {
        guard let manifest = try await load().current[name] else { throw SkillError.missingSkill(name) }
        return manifest
    }

    private func requireStored(_ name: String) async throws -> StoredSkill {
        guard let stored = try await load().stored[name] else { throw SkillError.missingSkill(name) }
        return stored
    }

    private func requireActor(_ name: String) throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SkillError.emptyActor
        }
    }

    private func definedDraft(_ manifest: SkillManifest, markdown: String, files: [String: String], editor: String) -> EventDraft {
        EventDraft(
            type: EventType.skillDefined,
            payload: .object([
                "name": .string(manifest.name),
                "version": .int(Int64(manifest.version)),
                "markdown": .string(markdown),
                "sha256": .string(manifest.contentSHA256),
                "editor": .string(editor),
                "description": .string(manifest.description),
                "body": .string(manifest.body),
                "warnings": .array(manifest.warnings.map(JSONValue.string)),
                "scripts": .array(manifest.scripts.map(JSONValue.string)),
                "allowedTools": manifest.allowedTools.map { .array($0.map(JSONValue.string)) } ?? .null,
                "license": manifest.license.map(JSONValue.string) ?? .null,
                "compatibility": manifest.compatibility.map(JSONValue.string) ?? .null,
                "metadata": .object(manifest.metadata.mapValues(JSONValue.string)),
                "files": filesJSON(files),
                "approvedByUser": .bool(true),
            ]),
            recordedAt: clock.now()
        )
    }

    private func filesJSON(_ files: [String: String]) -> JSONValue {
        .object(files.mapValues(JSONValue.string))
    }

    private struct StoredSkill {
        var manifest: SkillManifest
        var markdown: String
        var files: [String: String]
    }

    private struct State {
        var current: [String: SkillManifest] = [:]
        var stored: [String: StoredSkill] = [:]
        var history: [String: [StoredSkill]] = [:]
        var pending: [String: SkillProposal] = [:]
        var proposalTimes: [String: [Date]] = [:]
    }

    private func load() async throws -> State {
        var state = State()
        for event in try await store.readAll() {
            switch event.type {
            case EventType.skillDefined:
                guard let name = event.payload["name"]?.stringValue,
                      let markdown = event.payload["markdown"]?.stringValue,
                      let version = event.payload["version"]?.intValue
                else { continue }
                let files = stringMap(event.payload["files"])
                var manifest = SkillParser.parse(directoryName: name, markdown: markdown, files: files)
                manifest.version = Int(version)
                manifest.approvedByUser = true
                let stored = StoredSkill(manifest: manifest, markdown: markdown, files: files)
                state.history[name, default: []].append(stored)
                state.current[name] = manifest
                state.stored[name] = stored
            case EventType.skillProposed:
                guard let id = event.payload["proposalID"]?.stringValue,
                      let name = event.payload["name"]?.stringValue,
                      let markdown = event.payload["markdown"]?.stringValue,
                      let author = event.payload["author"]?.stringValue
                else { continue }
                state.pending[id] = SkillProposal(
                    id: id,
                    name: name,
                    markdown: markdown,
                    files: stringMap(event.payload["files"]),
                    author: author
                )
                state.proposalTimes[name, default: []].append(event.recordedAt)
            case EventType.skillResolved:
                if let id = event.payload["proposalID"]?.stringValue {
                    state.pending.removeValue(forKey: id)
                }
            default:
                break
            }
        }
        return state
    }

    private func stringMap(_ value: JSONValue?) -> [String: String] {
        guard let fields = value?.objectValue else { return [:] }
        var map: [String: String] = [:]
        for (key, item) in fields {
            if let text = item.stringValue {
                map[key] = text
            }
        }
        return map
    }
}

enum SkillStream {
    static let id = StreamID("skills")
}
