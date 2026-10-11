import DurableMCP
import Foundation
import ModelKit

/// In-memory stand-in for the Keychain. The app writes the real Keychain.
public actor MemorySecretStore: SecretStore {
    private var values: [String: String] = [:]

    public init(_ seed: [String: String] = [:]) {
        self.values = seed
    }

    public func secret(for reference: any SecretReference) async throws -> String {
        guard let value = values[reference.account] else {
            throw ModelKitError.missingSecret(reference.account)
        }
        return value
    }

    public func save(account: String, secret: String) {
        values[account] = secret
    }

    public func delete(account: String) {
        values[account] = nil
    }
}

struct MCPSecretBridge: MCPSecretStore {
    let store: any SecretStore

    func secret(account: String) async throws -> String? {
        do {
            return try await store.secret(for: NamedSecret(account: account))
        } catch {
            return nil
        }
    }
}
