import Foundation

public struct ConversationID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var raw: String

    public init(raw: String) {
        self.raw = raw
    }

    public static func generate() -> ConversationID {
        ConversationID(raw: "conv_" + UUID().uuidString.lowercased())
    }

    public var description: String { raw }
}

public struct RunID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var raw: String

    public init(raw: String) {
        self.raw = raw
    }

    public static func generate() -> RunID {
        RunID(raw: "run_" + UUID().uuidString.lowercased())
    }

    public var description: String { raw }
}

public struct CallID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public var description: String { raw }
}

/// Append-only stream. One conversation is one stream.
public struct StreamID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public static func conversation(_ id: ConversationID) -> StreamID {
        StreamID(id.raw)
    }

    public var description: String { raw }
}

/// Fencing token. A commit is admitted only when `epoch` is still the store's epoch.
public struct FenceToken: Hashable, Sendable, Codable, CustomStringConvertible {
    public var owner: UUID
    public var epoch: UInt64

    public init(owner: UUID, epoch: UInt64) {
        self.owner = owner
        self.epoch = epoch
    }

    public var description: String { "fence(\(owner.uuidString)#\(epoch))" }
}

public struct Lease: Sendable, Equatable {
    public var owner: UUID
    public var epoch: UInt64
    public var pid: Int32
    public var expiresAt: Date

    public init(owner: UUID, epoch: UInt64, pid: Int32, expiresAt: Date) {
        self.owner = owner
        self.epoch = epoch
        self.pid = pid
        self.expiresAt = expiresAt
    }

    public var fence: FenceToken {
        FenceToken(owner: owner, epoch: epoch)
    }
}

/// Stable idempotency key minted by the engine from the store, conversation, and call id.
public struct EffectKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public var raw: String

    public init(raw: String) {
        self.raw = raw
    }

    public static func derive(storeID: String, conversation: ConversationID, call: CallID) -> EffectKey {
        EffectKey(raw: "fx:\(storeID):\(conversation.raw):\(call.raw)")
    }

    /// Filename-safe form of `raw` for hosts that journal an external receipt on disk.
    public var fileToken: String {
        String(raw.map { character in
            if character.isASCII, character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "_"
        })
    }

    public var description: String { raw }
}

/// Durable handle that resumes a suspended approval after the process is gone.
public struct ResumeToken: Hashable, Sendable, Codable, CustomStringConvertible {
    public var raw: String
    public var conversationID: ConversationID
    public var approvalID: String

    public init(conversationID: ConversationID, approvalID: String) {
        self.conversationID = conversationID
        self.approvalID = approvalID
        self.raw = "resume:\(conversationID.raw):\(approvalID)"
    }

    public init?(raw: String) {
        let prefix = "resume:"
        guard raw.hasPrefix(prefix) else { return nil }
        let rest = raw.dropFirst(prefix.count)
        guard let split = rest.firstIndex(of: ":") else { return nil }
        let conversation = String(rest[..<split])
        let approval = String(rest[rest.index(after: split)...])
        guard !conversation.isEmpty, !approval.isEmpty else { return nil }
        self.conversationID = ConversationID(raw: conversation)
        self.approvalID = approval
        self.raw = raw
    }

    public var description: String { raw }
}
