@testable import DurableSecurity
import Foundation
import Testing

/// Stands in for the Keychain so the wrapping rules run on Linux and on Macs without an enclave.
private final class MemoryKeyItems: KeyItemStore {
    var items: [String: Data] = [:]
    var unavailable: Set<String> = []

    func read(_ scope: String) throws -> Data? {
        if unavailable.contains(scope) { throw SecurityError.keyUnavailable(scope, -25308) }
        return items[scope]
    }

    func add(_ scope: String, _ data: Data) throws {
        guard items[scope] == nil else { throw SecurityError.keyUnavailable(scope, -25299) }
        items[scope] = data
    }

    func replace(_ scope: String, _ data: Data) throws {
        guard items[scope] != nil else { throw SecurityError.keyUnavailable(scope, -25300) }
        items[scope] = data
    }

    func delete(_ scope: String) {
        items.removeValue(forKey: scope)
    }

    func scopes() throws -> [String] {
        Array(items.keys)
    }
}

private func randomKey() -> Data {
    Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) })
}

private func store(_ items: MemoryKeyItems, _ key: (any KeyAgreementKey)?, wraps: Bool = true) -> WrappingKeyStore {
    WrappingKeyStore(items: items, wrapper: { _ in key }, wrapsKeys: wraps)
}

@Test func aWrappedKeyOpensOnlyWithTheSameEnclaveKeyAndScope() throws {
    let enclave = softwareWrappingKey()
    let key = randomKey()
    let wrapped = try KeyWrap.wrap(key, scope: "conv-a", to: enclave.publicKey)

    #expect(wrapped.count == 129)
    #expect(KeyWrap.isWrapped(wrapped))
    #expect(!KeyWrap.isWrapped(key))
    #expect(!wrapped.contains(key))
    #expect(try KeyWrap.unwrap(wrapped, scope: "conv-a", with: enclave) == key)
    // Each wrap uses a new ephemeral key.
    #expect(try KeyWrap.wrap(key, scope: "conv-a", to: enclave.publicKey) != wrapped)

    #expect(throws: (any Error).self) { try KeyWrap.unwrap(wrapped, scope: "conv-b", with: enclave) }
    #expect(throws: (any Error).self) { try KeyWrap.unwrap(wrapped, scope: "conv-a", with: softwareWrappingKey()) }
    var tampered = wrapped
    tampered[tampered.count - 1] ^= 0x01
    #expect(throws: (any Error).self) { try KeyWrap.unwrap(tampered, scope: "conv-a", with: enclave) }
    var header = wrapped
    header[10] ^= 0x01
    #expect(throws: (any Error).self) { try KeyWrap.unwrap(header, scope: "conv-a", with: enclave) }
}

@Test func newKeysAreStoredWrapped() throws {
    let items = MemoryKeyItems()
    let enclave = softwareWrappingKey()
    let key = try store(items, enclave).fetchOrCreate("conv-new")

    let stored = try #require(items.items["conv-new"])
    #expect(KeyWrap.isWrapped(stored))
    #expect(try store(items, enclave).fetchOrCreate("conv-new") == key)
}

@Test func aPlainKeyIsWrappedInPlaceWithTheSameBytes() throws {
    let items = MemoryKeyItems()
    let original = randomKey()
    items.items["conv-old"] = original
    let enclave = softwareWrappingKey()

    #expect(try store(items, enclave).fetchOrCreate("conv-old") == original)
    let stored = try #require(items.items["conv-old"])
    #expect(KeyWrap.isWrapped(stored))
    #expect(try KeyWrap.unwrap(stored, scope: "conv-old", with: enclave) == original)
    // A later launch reads the wrapped item and gets the same key.
    #expect(try store(items, enclave).fetchOrCreate("conv-old") == original)
    // The plain provider on the same service still opens it.
    #expect(try store(items, enclave, wraps: false).fetchOrCreate("conv-old") == original)
}

@Test func wrapAllWrapsConversationsThatWereNotOpened() throws {
    let items = MemoryKeyItems()
    let originals = (0 ..< 5).map { _ in randomKey() }
    for (index, key) in originals.enumerated() {
        items.items["conv-\(index)"] = key
    }
    let enclave = softwareWrappingKey()

    #expect(try store(items, enclave).wrapAll() == 5)
    #expect(items.items.values.allSatisfy(KeyWrap.isWrapped))
    for (index, key) in originals.enumerated() {
        #expect(try store(items, enclave).fetchOrCreate("conv-\(index)") == key)
    }
    #expect(try store(items, enclave).wrapAll() == 0)
}

@Test func withoutAnEnclaveKeysStayPlainLikeTheKeychainProvider() throws {
    let items = MemoryKeyItems()
    let plain = randomKey()
    items.items["conv-old"] = plain

    #expect(try store(items, nil).fetchOrCreate("conv-old") == plain)
    #expect(items.items["conv-old"] == plain)
    let created = try store(items, nil).fetchOrCreate("conv-new")
    #expect(items.items["conv-new"] == created)
    #expect(try store(items, nil).wrapAll() == 0)
}

@Test func aWrongEnclaveKeyIsUnavailableAndNeverMakesANewKey() throws {
    let items = MemoryKeyItems()
    let enclave = softwareWrappingKey()
    _ = try store(items, enclave).fetchOrCreate("conv-a")
    let before = try #require(items.items["conv-a"])

    #expect(throws: SecurityError.keyUnavailable("conv-a", KeyWrap.Status.unwrapFailed)) {
        try store(items, softwareWrappingKey()).fetchOrCreate("conv-a")
    }
    #expect(throws: SecurityError.keyUnavailable("conv-a", KeyWrap.Status.noWrappingKey)) {
        try store(items, nil).fetchOrCreate("conv-a")
    }
    #expect(items.items["conv-a"] == before)
}

@Test func aLockedKeychainIsUnavailableAndNeverMakesANewKey() throws {
    let items = MemoryKeyItems()
    items.items["conv-a"] = randomKey()
    items.unavailable = ["conv-a"]
    let enclave = softwareWrappingKey()

    #expect(throws: SecurityError.keyUnavailable("conv-a", -25308)) {
        try store(items, enclave).fetchOrCreate("conv-a")
    }
    let unavailableWrapper = WrappingKeyStore(
        items: items,
        wrapper: { _ in throw SecurityError.keyUnavailable("wrapping key", -25308) },
        wrapsKeys: true
    )
    #expect(throws: SecurityError.keyUnavailable("conv-new", -25308)) {
        try unavailableWrapper.fetchOrCreate("conv-new")
    }
    #expect(items.items["conv-new"] == nil)
}

@Test func shreddingAWrappedKeyLeavesItsCiphertextUnreadable() throws {
    let items = MemoryKeyItems()
    let enclave = softwareWrappingKey()
    let keys = store(items, enclave)
    let key = try keys.fetchOrCreate("conv-gone")
    let sealed = try AESGCM.seal(Data("secret".utf8), key: key)

    keys.delete("conv-gone")
    #expect(items.items["conv-gone"] == nil)
    // A later read makes a different key, so the old ciphertext reads as shredded.
    let fresh = try keys.fetchOrCreate("conv-gone")
    #expect(fresh != key)
    #expect(throws: SecurityError.shredded("conv-gone")) {
        try AESGCM.open(sealed, key: fresh, scope: "conv-gone")
    }
}
