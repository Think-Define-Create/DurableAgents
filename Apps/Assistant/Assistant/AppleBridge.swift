import DurableCore
import Foundation
import ModelKit
import Security

#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

struct AssistantKeychain: SecretStore, Sendable {
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
        guard status == errSecSuccess else {
            throw ModelKitError.missingSecret(account)
        }
    }
}

enum DeviceAuth {
    static func authenticate(reason: String) async -> AuthenticationLevel? {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        let biometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let policy: LAPolicy = biometrics ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        do {
            let ok = try await context.evaluatePolicy(policy, localizedReason: reason)
            guard ok else { return nil }
            return biometrics ? .biometric : .devicePasscode
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

enum AssistantNotifications {
    static func requestPermission() async {
        #if canImport(UserNotifications)
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        #endif
    }

    static func post(identifier: String, title: String, body: String, collapseID: String) async {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = collapseID
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
        #endif
    }
}

enum AssistantBackground {
    static let refreshID = "dev.thinkdefinecreate.Assistant.refresh"
    static let processingID = "dev.thinkdefinecreate.Assistant.processing"

    static func register() {
        #if canImport(BackgroundTasks) && !os(macOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            finish(task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { task in
            finish(task)
        }
        #endif
    }

    static func scheduleNext() {
        #if canImport(BackgroundTasks) && !os(macOS)
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(refresh)
        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        processing.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(processing)
        #endif
    }

    #if canImport(BackgroundTasks) && !os(macOS)
    private static func finish(_ task: BGTask) {
        nonisolated(unsafe) let work = task
        Task { @MainActor in
            await AssistantRuntime.model?.catchUp()
            work.setTaskCompleted(success: true)
            scheduleNext()
        }
    }
    #endif
}
