import DurableCore
import DurableSchedule
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

    func has(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
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
    /// Continued-processing requests use `reply.<id>`, each registered just before it is submitted.
    /// Info.plist permits `reply.*`.
    static let replyPrefix = "dev.thinkdefinecreate.Assistant.reply"
    /// The last scheduling failure, shown in Diagnostics. Cleared after a request is accepted.
    static let submitErrorKey = "background.lastSubmitError"

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
        Task.detached {
            do {
                try await AppleRoutineWake.scheduleRefresh(identifier: refreshID, earliest: Date(timeIntervalSinceNow: 30 * 60))
                try await AppleRoutineWake.scheduleProcessing(identifier: processingID, earliest: Date(timeIntervalSinceNow: 60 * 60))
                UserDefaults.standard.removeObject(forKey: submitErrorKey)
            } catch {
                UserDefaults.standard.set(String(describing: error), forKey: submitErrorKey)
            }
        }
        #endif
    }

    #if canImport(BackgroundTasks) && !os(macOS)
    private static func finish(_ task: BGTask) {
        nonisolated(unsafe) let work = task
        let job = Task { @MainActor in
            await Diagnostics.backgroundProbe(support: AssistantRuntime.model?.diagnosticsSupportURL ?? Diagnostics.supportURL())
            await AssistantRuntime.model?.catchUp()
            guard !Task.isCancelled else { return }
            work.setTaskCompleted(success: true)
            scheduleNext()
        }
        // iOS ends the window without warning otherwise. The journal keeps whatever finished.
        work.expirationHandler = {
            job.cancel()
            work.setTaskCompleted(success: false)
            scheduleNext()
        }
    }
    #endif
}

/// Keeps a reply running after the person leaves the app, with the system's progress UI (iOS 26).
/// The run itself already goes through the journal, so if iOS still stops it, recovery finishes it on
/// the next launch. This only asks for the time to finish now.
final class ReplyKeepAlive: @unchecked Sendable {
    static let shared = ReplyKeepAlive()
    private let lock = NSLock()
    private var finished: Set<String> = []
    #if canImport(BackgroundTasks) && !os(macOS)
    private var running: [String: BGTask] = [:]
    #endif

    /// Runs `work`, covered by a continued-processing task when the system allows one.
    @MainActor
    func run<T>(title: String, subtitle: String, _ work: @MainActor () async -> T) async -> T {
        #if canImport(BackgroundTasks) && !os(macOS)
        guard #available(iOS 26, *) else { return await work() }
        let identifier = AssistantBackground.replyPrefix + "." + UUID().uuidString
        // iOS asserts (and ends the app) when a request is submitted without a handler for its exact
        // identifier, so register this one first. Continued-processing tasks may register after launch.
        guard register(identifier) else {
            Trace.log("keepalive: register failed")
            return await work()
        }
        Trace.log("keepalive: registered, submitting")
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Fail rather than queue: a reply that waits in a queue would start after it is no longer needed.
        request.strategy = .fail
        let submitted = (try? await AppleRoutineWake.submit(request)) != nil
        Trace.log("keepalive: submitted=\(submitted)")
        let value = await work()
        if submitted { complete(identifier) }
        return value
        #else
        return await work()
        #endif
    }

    #if canImport(BackgroundTasks) && !os(macOS)
    /// Not on the main actor: iOS calls the handler on its own queue, and a main-actor closure
    /// there fails Swift's isolation check and ends the app.
    private nonisolated func register(_ identifier: String) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            ReplyKeepAlive.shared.attach(task)
        }
    }

    func attach(_ task: BGTask) {
        let id = task.identifier
        lock.lock()
        let done = finished.remove(id) != nil
        if !done { running[id] = task }
        lock.unlock()
        if #available(iOS 26, *), let continued = task as? BGContinuedProcessingTask {
            continued.progress.totalUnitCount = 1
            continued.progress.completedUnitCount = done ? 1 : 0
        }
        if done {
            task.setTaskCompleted(success: true)
            return
        }
        task.expirationHandler = { [weak self] in
            self?.lock.lock()
            self?.running[id] = nil
            self?.lock.unlock()
            task.setTaskCompleted(success: false)
        }
    }

    private func complete(_ id: String) {
        lock.lock()
        let task = running.removeValue(forKey: id)
        if task == nil { finished.insert(id) }
        lock.unlock()
        guard let task else { return }
        if #available(iOS 26, *), let continued = task as? BGContinuedProcessingTask {
            continued.progress.completedUnitCount = 1
        }
        task.setTaskCompleted(success: true)
    }
    #endif
}
