import Foundation

public protocol SecretReference: Sendable {
    /// Keychain account or environment variable name. Never the secret itself.
    var account: String { get }
}

public struct NamedSecret: SecretReference, Sendable {
    public var account: String

    public init(account: String) {
        self.account = account
    }
}

public protocol SecretStore: Sendable {
    func secret(for reference: any SecretReference) async throws -> String
}

public enum SecretStoreSupport {
    #if canImport(Security)
    public static let keychainCompiled = true
    #else
    public static let keychainCompiled = false
    #endif
}

public struct EnvironmentSecretStore: SecretStore {
    public init() {}

    public func secret(for reference: any SecretReference) async throws -> String {
        let name = reference.account
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw ModelKitError.missingSecret(name)
        }
        return value
    }
}

/// Explicit empty credential for local OpenAI-compatible servers that do not use a key.
public struct EmptySecretStore: SecretStore {
    public init() {}

    public func secret(for reference: any SecretReference) async throws -> String {
        ""
    }
}

#if canImport(Security)
import Security

public struct KeychainSecretStore: SecretStore {
    public var service: String

    public init(service: String = "DurableAgents") {
        self.service = service
    }

    public func secret(for reference: any SecretReference) async throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw ModelKitError.missingSecret(reference.account)
        }
        return value
    }
}
#endif
