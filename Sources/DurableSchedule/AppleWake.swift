import Foundation

#if canImport(BackgroundTasks) && canImport(UserNotifications) && !os(macOS)
import BackgroundTasks
import UserNotifications

/// Best-effort on-device wake. iOS does not promise the cadence. The journal is the source of truth
/// when the app next opens. On iOS 27 requests go through `submitTaskRequest`, which reports every
/// rejection. Earlier systems use `submit`.
public enum AppleRoutineWake {
    public static func scheduleRefresh(identifier: String, earliest: Date) async throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliest
        try await submit(request)
    }

    public static func scheduleProcessing(identifier: String, earliest: Date, needsNetwork: Bool = false) async throws {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliest
        request.requiresNetworkConnectivity = needsNetwork
        try await submit(request)
    }

    public static func submit(_ request: BGTaskRequest) async throws {
        if #available(iOS 27, tvOS 27, *) {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
        } else {
            try BGTaskScheduler.shared.submit(request)
        }
    }

    public static func notify(identifier: String, title: String, body: String, dedupeKey: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = dedupeKey
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
#endif
