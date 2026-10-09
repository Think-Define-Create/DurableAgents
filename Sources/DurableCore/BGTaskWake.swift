import Foundation

public enum BackgroundWakeSupport {
    #if canImport(BackgroundTasks)
    public static let appleSchedulerCompiled = true
    #else
    public static let appleSchedulerCompiled = false
    #endif
}

#if canImport(BackgroundTasks)
import BackgroundTasks

/// Submits a `BGAppRefreshTaskRequest` so iOS can wake the app around a journaled timer.
/// The engine still decides what is due by reading `timer.requested` / `timer.fired`.
@available(iOS 13.0, *)
public struct BGTaskSchedulerWake: BackgroundWakeScheduling {
    public var taskIdentifier: String

    public init(taskIdentifier: String) {
        self.taskIdentifier = taskIdentifier
    }

    public func scheduleBackgroundWake(earliest date: Date, identifier: String) async {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = date
        try? BGTaskScheduler.shared.submit(request)
        _ = identifier
    }
}
#endif
