import Crypto
import Foundation

public enum SecurityError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingKey(String)
    case shredded(String)
    case malformedCiphertext(String)
    /// The key exists but cannot be read right now, for example before the first unlock after a restart.
    case keyUnavailable(String, Int32)

    public var description: String {
        switch self {
        case .missingKey(let id):
            return "missing key \(id)"
        case .shredded(let id):
            return "key shredded \(id)"
        case .malformedCiphertext(let detail):
            return "malformed ciphertext: \(detail)"
        case .keyUnavailable(let id, let status):
            return "key \(id) is unavailable right now (status \(status))"
        }
    }
}

public enum KeyStorageSupport {
    #if canImport(Security)
    public static let keychainCompiled = true
    #else
    public static let keychainCompiled = false
    #endif
}

/// 32-byte AES-GCM keys. The key bytes never go into the event log.
public protocol ConversationKeyProvider: Sendable {
    func loadKey(for scope: String) async throws -> Data
    func shred(_ scope: String) async throws
}

public actor MemoryKeyProvider: ConversationKeyProvider {
    private var keys: [String: Data] = [:]
    private var shredded: Set<String> = []

    public init() {}

    public func loadKey(for scope: String) async throws -> Data {
        if shredded.contains(scope) {
            throw SecurityError.shredded(scope)
        }
        if let existing = keys[scope] {
            return existing
        }
        let created = Self.randomKey()
        keys[scope] = created
        return created
    }

    public func shred(_ scope: String) async throws {
        keys.removeValue(forKey: scope)
        shredded.insert(scope)
    }

    static func randomKey() -> Data {
        var bytes = Data(count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return bytes
    }
}

/// One file per scope under `directory`. Deleting the file is the Linux shred.
public actor FileKeyProvider: ConversationKeyProvider {
    public let directory: URL
    private var shredded: Set<String> = []

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    public func loadKey(for scope: String) async throws -> Data {
        if shredded.contains(scope) || FileManager.default.fileExists(atPath: tombstoneURL(scope).path) {
            throw SecurityError.shredded(scope)
        }
        let url = fileURL(scope)
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count == 32 else {
                throw SecurityError.malformedCiphertext("key file \(scope) is \(data.count) bytes")
            }
            return data
        }
        let created = MemoryKeyProvider.randomKey()
        try created.write(to: url, options: .atomic)
        return created
    }

    public func shred(_ scope: String) async throws {
        shredded.insert(scope)
        let url = fileURL(scope)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try Data().write(to: tombstoneURL(scope), options: .atomic)
    }

    private func tombstoneURL(_ scope: String) -> URL {
        directory.appendingPathComponent(fileName(scope) + ".shredded")
    }

    private func fileURL(_ scope: String) -> URL {
        directory.appendingPathComponent(fileName(scope) + ".key")
    }

    private func fileName(_ scope: String) -> String {
        String(scope.map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        })
    }
}

enum AESGCM {
    static func seal(_ plaintext: Data, key: Data) throws -> Data {
        let symmetric = SymmetricKey(data: key)
        let sealed = try AES.GCM.seal(plaintext, using: symmetric)
        guard let combined = sealed.combined else {
            throw SecurityError.malformedCiphertext("seal produced no combined box")
        }
        return combined
    }

    static func open(_ combined: Data, key: Data, scope: String = "") throws -> Data {
        let symmetric = SymmetricKey(data: key)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw SecurityError.malformedCiphertext("sealed box: \(error)")
        }
        do {
            return try AES.GCM.open(box, using: symmetric)
        } catch {
            // A provider that makes a fresh key for a missing scope (the Keychain does) hands back
            // a key the ciphertext was not sealed with. The original key is gone, so this is a shred.
            throw SecurityError.shredded(scope)
        }
    }
}

