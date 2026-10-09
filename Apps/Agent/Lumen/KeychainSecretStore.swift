import Foundation
import ModelKit
import Security

struct KeychainError: Error, CustomStringConvertible {
    var status: OSStatus
    var description: String { "Keychain status \(status)" }
}

/// Account name in, secret value out. Values are written with `SecItemAdd` and never logged.
struct KeychainSecretStore: SecretStore {
    var service: String

    func secret(for reference: any SecretReference) async throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw ModelKitError.missingSecret(reference.account)
        }
        return text
    }

    func save(account: String, secret: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var insert = base
        insert[kSecValueData as String] = Data(secret.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
