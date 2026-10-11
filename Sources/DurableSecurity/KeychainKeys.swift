#if canImport(Security)
import Crypto
import Foundation
import Security
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Keychain item per conversation scope. Not compiled on Linux.
/// Keys are cached after the first lookup, because every event read or written needs one
/// and each Keychain query is a round trip to the security daemon.
///
/// Stores raw keys. It also opens keys that `SecureEnclaveKeyProvider` wrapped on this
/// device, so both providers can read the same service.
public actor KeychainKeyProvider: ConversationKeyProvider {
    public let service: String
    private let store: WrappingKeyStore
    private let items: KeychainKeyItems
    private var cache: [String: Data] = [:]

    public init(service: String = "DurableAgents.keys") {
        self.service = service
        let items = KeychainKeyItems(service: service)
        let enclave = EnclaveWrappingKey(service: service)
        self.items = items
        self.store = WrappingKeyStore(items: items, wrapper: { _ in try enclave.key(create: false) }, wrapsKeys: false)
    }

    public func loadKey(for scope: String) async throws -> Data {
        if let cached = cache[scope] {
            return cached
        }
        let key = try store.fetchOrCreate(scope)
        cache[scope] = key
        return key
    }

    public func shred(_ scope: String) async throws {
        cache.removeValue(forKey: scope)
        store.delete(scope)
    }

    public func inventory() throws -> KeyInventory {
        try items.inventory(secureEnclave: false)
    }
}

/// Like `KeychainKeyProvider`, but each conversation key is stored wrapped by a P-256 key
/// that lives in the Secure Enclave. Copying the Keychain item off the device does not
/// reveal the key.
///
/// The enclave key needs no user presence, so routines can decrypt while the phone is locked
/// after its first unlock. Plain keys made earlier are wrapped in place on first read, with
/// the same key bytes, or all at once with `wrapExistingKeys()`.
///
/// Where `SecureEnclave.isAvailable` is false (the simulator, Linux, older Macs) this
/// behaves exactly like `KeychainKeyProvider`.
public actor SecureEnclaveKeyProvider: ConversationKeyProvider {
    public let service: String
    /// True when keys are wrapped on this device.
    public nonisolated let usesSecureEnclave: Bool
    private let store: WrappingKeyStore
    private let items: KeychainKeyItems
    private var cache: [String: Data] = [:]

    public init(service: String = "DurableAgents.keys") {
        self.service = service
        let items = KeychainKeyItems(service: service)
        let enclave = EnclaveWrappingKey(service: service)
        self.items = items
        self.usesSecureEnclave = EnclaveWrappingKey.available
        self.store = WrappingKeyStore(items: items, wrapper: { create in try enclave.key(create: create) }, wrapsKeys: true)
    }

    public func loadKey(for scope: String) async throws -> Data {
        if let cached = cache[scope] {
            return cached
        }
        let key = try store.fetchOrCreate(scope)
        cache[scope] = key
        return key
    }

    /// Shred deletes the wrapped item. The enclave key stays, because other conversations use it.
    public func shred(_ scope: String) async throws {
        cache.removeValue(forKey: scope)
        store.delete(scope)
    }

    /// Wraps every plain key of the service now. Returns how many were wrapped.
    @discardableResult
    public func wrapExistingKeys() throws -> Int {
        try store.wrapAll()
    }

    public func inventory() throws -> KeyInventory {
        try items.inventory(secureEnclave: usesSecureEnclave)
    }
}

/// The one Secure Enclave key for a service, stored as its opaque data representation.
/// The blob is useless off this device.
final class EnclaveWrappingKey {
    let service: String
    let account = "secure-enclave-p256-wrapping-key"
    #if canImport(CryptoKit)
    private var cached: SecureEnclave.P256.KeyAgreement.PrivateKey?
    #endif

    init(service: String) {
        self.service = service + ".wrapping"
    }

    static var available: Bool {
        #if canImport(CryptoKit)
        SecureEnclave.isAvailable
        #else
        false
        #endif
    }

    /// nil when the device has no Secure Enclave, or when `create` is false and there is no key yet.
    /// An existing item that fails to load throws. It is never replaced, because every wrapped
    /// conversation key depends on it.
    func key(create: Bool) throws -> (any KeyAgreementKey)? {
        #if canImport(CryptoKit)
        guard Self.available else { return nil }
        if let cached { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            do {
                let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data)
                cached = key
                return key
            } catch {
                throw SecurityError.keyUnavailable("wrapping key", KeyWrap.Status.wrappingKeyUnreadable)
            }
        }
        guard status == errSecItemNotFound else {
            throw SecurityError.keyUnavailable("wrapping key", status)
        }
        guard create else { return nil }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            &accessError
        ) else {
            throw SecurityError.keyUnavailable("wrapping key", KeyWrap.Status.wrappingKeyUnreadable)
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.dataRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let write = SecItemAdd(insert as CFDictionary, nil)
        if write == errSecDuplicateItem {
            // Another provider instance made it first. Use that one.
            return try self.key(create: false)
        }
        guard write == errSecSuccess else {
            throw SecurityError.keyUnavailable("wrapping key", write)
        }
        cached = key
        return key
        #else
        return nil
        #endif
    }
}

#if canImport(CryptoKit)
extension SecureEnclave.P256.KeyAgreement.PrivateKey: KeyAgreementKey {}
#endif

/// Generic-password items, one per scope, readable after the first unlock.
final class KeychainKeyItems: KeyItemStore {
    let service: String
    private var relaxed = false

    init(service: String) {
        self.service = service
    }

    func read(_ scope: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        // Any other failure, such as a locked device, must not look like a missing key,
        // or a new key would be made and the conversation would read as shredded.
        guard status == errSecSuccess, let data = item as? Data else {
            throw SecurityError.keyUnavailable(scope, status)
        }
        relaxAccessOnce()
        return data
    }

    func add(_ scope: String, _ data: Data) throws {
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let write = SecItemAdd(insert as CFDictionary, nil)
        guard write == errSecSuccess else {
            throw SecurityError.keyUnavailable(scope, write)
        }
    }

    func replace(_ scope: String, _ data: Data) throws {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
        ]
        let change: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(match as CFDictionary, change as CFDictionary)
        guard status == errSecSuccess else {
            throw SecurityError.keyUnavailable(scope, status)
        }
    }

    func delete(_ scope: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func scopes() throws -> [String] {
        try rows().compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func inventory(secureEnclave: Bool) throws -> KeyInventory {
        let rows = try rows()
        let wanted = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        var inventory = KeyInventory(total: rows.count, wrapped: 0, plain: 0, readableAfterFirstUnlock: 0, secureEnclave: secureEnclave)
        for row in rows {
            if (row[kSecAttrAccessible as String] as? String) == wanted {
                inventory.readableAfterFirstUnlock += 1
            }
            guard let scope = row[kSecAttrAccount as String] as? String,
                  let data = try? read(scope)
            else { continue }
            if KeyWrap.isWrapped(data) {
                inventory.wrapped += 1
            } else if data.count == 32 {
                inventory.plain += 1
            }
        }
        return inventory
    }

    private func rows() throws -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let rows = items as? [[String: Any]] else {
            throw SecurityError.keyUnavailable(service, status)
        }
        return rows
    }

    /// Keys made before this setting were readable only while unlocked, so background wakes
    /// (routines, notifications) could not read conversations while the phone was locked.
    /// Updates every key of the service once, including conversations not opened this launch.
    private func relaxAccessOnce() {
        guard !relaxed else { return }
        relaxed = true
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let change: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemUpdate(match as CFDictionary, change as CFDictionary)
    }
}
#endif
