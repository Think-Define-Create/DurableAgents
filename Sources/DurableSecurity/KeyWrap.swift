import Crypto
import Foundation

/// A P-256 key-agreement private key that wraps conversation keys.
/// On a device it is a Secure Enclave key. Tests use a software key.
protocol KeyAgreementKey {
    var publicKey: P256.KeyAgreement.PublicKey { get }
    func sharedSecretFromKeyAgreement(with publicKeyShare: P256.KeyAgreement.PublicKey) throws -> SharedSecret
}

extension P256.KeyAgreement.PrivateKey: KeyAgreementKey {}

/// A software key for tests on machines without a Secure Enclave.
func softwareWrappingKey() -> any KeyAgreementKey {
    P256.KeyAgreement.PrivateKey()
}

/// ECIES-style wrap of a 32-byte conversation key to a P-256 public key.
///
/// Layout: `DAK1` | ephemeral public key (X9.63, 65 bytes) | AES-GCM combined box (60 bytes).
/// The AES key is HKDF-SHA256 over the ECDH secret, salted with both public keys,
/// with the scope in the info, so a wrapped key cannot be moved to another conversation.
enum KeyWrap {
    static let magic = Data("DAK1".utf8)
    static let wrappedCount = 4 + 65 + 12 + 32 + 16

    /// `keyUnavailable` statuses that are not Keychain codes.
    enum Status {
        /// The stored key is wrapped and did not open with this device's wrapping key.
        static let unwrapFailed: Int32 = -1001
        /// The stored key is wrapped and this device has no wrapping key.
        static let noWrappingKey: Int32 = -1002
        /// The wrapping key item exists but the Secure Enclave would not load it.
        static let wrappingKeyUnreadable: Int32 = -1003
    }

    static func isWrapped(_ data: Data) -> Bool {
        data.count == wrappedCount && data.prefix(magic.count) == magic
    }

    static func wrap(_ key: Data, scope: String, to recipient: P256.KeyAgreement.PublicKey) throws -> Data {
        guard key.count == 32 else {
            throw SecurityError.malformedCiphertext("conversation key is \(key.count) bytes")
        }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let header = magic + ephemeral.publicKey.x963Representation
        let symmetric = derive(shared, ephemeral: ephemeral.publicKey, recipient: recipient, scope: scope)
        let sealed = try AES.GCM.seal(key, using: symmetric, authenticating: header)
        guard let combined = sealed.combined else {
            throw SecurityError.malformedCiphertext("wrap produced no combined box")
        }
        return header + combined
    }

    static func unwrap(_ blob: Data, scope: String, with key: any KeyAgreementKey) throws -> Data {
        guard isWrapped(blob) else {
            throw SecurityError.malformedCiphertext("not a wrapped key")
        }
        let bytes = Data([UInt8](blob))
        let header = bytes.prefix(4 + 65)
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: header.suffix(65))
        let shared = try key.sharedSecretFromKeyAgreement(with: ephemeral)
        let symmetric = derive(shared, ephemeral: ephemeral, recipient: key.publicKey, scope: scope)
        let box = try AES.GCM.SealedBox(combined: bytes.suffix(from: 4 + 65))
        return try AES.GCM.open(box, using: symmetric, authenticating: header)
    }

    private static func derive(
        _ shared: SharedSecret,
        ephemeral: P256.KeyAgreement.PublicKey,
        recipient: P256.KeyAgreement.PublicKey,
        scope: String
    ) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeral.x963Representation + recipient.x963Representation,
            sharedInfo: Data("DurableAgents.conversation-key.v1|\(scope)".utf8),
            outputByteCount: 32
        )
    }
}

/// One stored item per conversation scope: a raw 32-byte key, or a wrapped one.
protocol KeyItemStore: AnyObject {
    /// nil when the item does not exist. Any other failure throws `keyUnavailable`.
    func read(_ scope: String) throws -> Data?
    func add(_ scope: String, _ data: Data) throws
    func replace(_ scope: String, _ data: Data) throws
    func delete(_ scope: String)
    func scopes() throws -> [String]
}

/// Key lookup shared by the Keychain providers and the tests.
struct WrappingKeyStore {
    let items: any KeyItemStore
    /// The wrapping key, or nil when the device has none. `create` is false on reads,
    /// so a provider that only unwraps never makes one.
    let wrapper: (_ create: Bool) throws -> (any KeyAgreementKey)?
    /// Wrap new keys, and wrap plain keys in place when they are read.
    let wrapsKeys: Bool

    func fetchOrCreate(_ scope: String) throws -> Data {
        if let stored = try items.read(scope) {
            return try open(stored, scope: scope)
        }
        let created = MemoryKeyProvider.randomKey()
        if wrapsKeys, let key = try wrappingKey(create: true, scope: scope) {
            try items.add(scope, KeyWrap.wrap(created, scope: scope, to: key.publicKey))
        } else {
            try items.add(scope, created)
        }
        return created
    }

    /// Wraps every plain key now, including conversations not opened this launch.
    /// Returns how many were wrapped.
    @discardableResult
    func wrapAll() throws -> Int {
        guard wrapsKeys, try wrappingKey(create: true, scope: "") != nil else { return 0 }
        var wrapped = 0
        for scope in try items.scopes() {
            guard let stored = try? items.read(scope), stored.count == 32 else { continue }
            if (try? open(stored, scope: scope)) != nil,
               let after = try? items.read(scope), KeyWrap.isWrapped(after)
            {
                wrapped += 1
            }
        }
        return wrapped
    }

    func delete(_ scope: String) {
        items.delete(scope)
    }

    private func open(_ stored: Data, scope: String) throws -> Data {
        if KeyWrap.isWrapped(stored) {
            // Never make a new key here. The conversation would read as shredded.
            guard let key = try wrappingKey(create: false, scope: scope) else {
                throw SecurityError.keyUnavailable(scope, KeyWrap.Status.noWrappingKey)
            }
            do {
                return try KeyWrap.unwrap(stored, scope: scope, with: key)
            } catch {
                throw SecurityError.keyUnavailable(scope, KeyWrap.Status.unwrapFailed)
            }
        }
        guard stored.count == 32 else {
            throw SecurityError.keyUnavailable(scope, 0)
        }
        if wrapsKeys {
            migrate(stored, scope: scope)
        }
        return stored
    }

    /// Replaces a plain key with the same bytes, wrapped. A failure leaves the plain key,
    /// which is tried again on the next read.
    private func migrate(_ plain: Data, scope: String) {
        guard let key = try? wrappingKey(create: true, scope: scope),
              let sealed = try? KeyWrap.wrap(plain, scope: scope, to: key.publicKey),
              (try? KeyWrap.unwrap(sealed, scope: scope, with: key)) == plain
        else { return }
        try? items.replace(scope, sealed)
    }

    private func wrappingKey(create: Bool, scope: String) throws -> (any KeyAgreementKey)? {
        do {
            return try wrapper(create)
        } catch SecurityError.keyUnavailable(_, let status) {
            throw SecurityError.keyUnavailable(scope, status)
        }
    }
}

/// How a provider's stored keys are protected. For diagnostics.
public struct KeyInventory: Sendable, Equatable {
    public var total: Int
    /// Wrapped by the Secure Enclave key.
    public var wrapped: Int
    /// Raw 32-byte keys, readable by anyone who can read the Keychain item.
    public var plain: Int
    /// Items readable while locked after the first unlock, so background wakes can decrypt.
    public var readableAfterFirstUnlock: Int
    /// The device has a Secure Enclave and the provider wraps keys with it.
    public var secureEnclave: Bool

    public init(total: Int, wrapped: Int, plain: Int, readableAfterFirstUnlock: Int, secureEnclave: Bool) {
        self.total = total
        self.wrapped = wrapped
        self.plain = plain
        self.readableAfterFirstUnlock = readableAfterFirstUnlock
        self.secureEnclave = secureEnclave
    }
}
