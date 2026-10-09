import Foundation

#if canImport(BackgroundTasks) && canImport(UserNotifications)
import BackgroundTasks
import UserNotifications

/// Best-effort on-device wake. iOS does not promise the cadence. The journal is the source of truth
/// when the app next opens. `BGTaskScheduler.submit` is the iOS 26 call. iOS 27 deprecates it
/// in favor of `submitTaskRequest`, which this file does not call.
public enum AppleRoutineWake {
    public static func scheduleRefresh(identifier: String, earliest: Date) throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliest
        try BGTaskScheduler.shared.submit(request)
    }

    public static func scheduleProcessing(identifier: String, earliest: Date) throws {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliest
        request.requiresNetworkConnectivity = false
        try BGTaskScheduler.shared.submit(request)
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