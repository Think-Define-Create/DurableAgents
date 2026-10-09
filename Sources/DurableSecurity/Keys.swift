import Crypto
import Foundation

public enum SecurityError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingKey(String)
    case shredded(String)
    case malformedCiphertext(String)

    public var description: String {
        switch self {
        case .missingKey(let id):
            return "missing key \(id)"
        case .shredded(let id):
            return "key shredded \(id)"
        case .malformedCiphertext(let detail):
            return "malformed ciphertext: \(detail)"
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
        if shredded.contains(scope) {
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
    }

    private func fileURL(_ scope: String) -> URL {
        let name = scope.map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        return directory.appendingPathComponent(String(name) + ".key")
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

    static func open(_ combined: Data, key: Data) throws -> Data {
        let symmetric = SymmetricKey(data: key)
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: symmetric)
    }
}

#if canImport(Security)
import Security

/// Keychain item per conversation scope. Not compiled on Linux.
public struct KeychainKeyProvider: ConversationKeyProvider {
    public var service: String

    public init(service: String = "DurableAgents.keys") {
        self.service = service
    }

    public func loadKey(for scope: String) async throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return data
        }
        let created = MemoryKeyProvider.randomKey()
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecValueData as String: created,
        ]
        let write = SecItemAdd(insert as CFDictionary, nil)
        guard write == errSecSuccess else {
            throw SecurityError.missingKey(scope)
        }
        return created
    }

    public func shred(_ scope: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif
