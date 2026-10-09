import Foundation
import LocalAuthentication

#if canImport(Speech)
import Speech
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(ActivityKit)
import ActivityKit
import AgentAppCore
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

enum DeviceAuth {
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch {
            return false
        }
    }
}

#if canImport(Speech) && canImport(AVFoundation)
private final class SpeechBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func finish(_ continuation: CheckedContinuation<String, Error>, result: Result<String, Error>) {
        lock.lock()
        let first = !resumed
        resumed = true
        lock.unlock()
        guard first else { return }
        continuation.resume(with: result)
    }
}

@MainActor
final class SpeechCapture {
    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?

    func transcribeOnce() async throws -> String {
        let granted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard granted else { return "" }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true)
        #endif
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        let box = SpeechBox()
        let text: String = try await withCheckedThrowingContinuation { continuation in
            task = recognizer?.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    box.finish(continuation, result: .success(result.bestTranscription.formattedString))
                } else if let error {
                    box.finish(continuation, result: .failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(4))
                request.endAudio()
                box.finish(continuation, result: .success(""))
            }
        }
        engine.stop()
        input.removeTap(onBus: 0)
        return text
    }
}
#endif

#if canImport(ActivityKit)
enum LumenActivityCenter {
    static func sync(inbox: [InboxItem], agents: [AgentProfile]) async {
        if #available(iOS 16.2, macOS 26.0, *) {
            let status = inbox.isEmpty ? "Running" : "Needs approval"
            let title = inbox.first?.agentTitle ?? agents.first?.title ?? "Lumen"
            let state = LumenActivityAttributes.ContentState(status: status, title: title)
            let content = ActivityContent(state: state, staleDate: nil)
            if let current = Activity<LumenActivityAttributes>.activities.first {
                await current.update(content)
            } else if !inbox.isEmpty {
                _ = try? Activity.request(
                    attributes: LumenActivityAttributes(agentTitle: title),
                    content: content,
                    pushType: nil
                )
            }
        }
    }
}
#endif

enum AppleBackground {
    static let refreshID = "dev.thinkdefinecreate.Lumen.refresh"
    static let continueID = "dev.thinkdefinecreate.Lumen.continue"

    static func register() {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            handleRefresh(task)
        }
        if #available(iOS 26, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: continueID, using: nil) { task in
                handleContinued(task)
            }
        }
        #endif
    }

    static func submitContinued(title: String) {
        #if canImport(BackgroundTasks)
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)
        if #available(iOS 26, *) {
            let request = BGContinuedProcessingTaskRequest(identifier: continueID, title: "Lumen", subtitle: title)
            request.strategy = .queue
            try? BGTaskScheduler.shared.submit(request)
        }
        #endif
    }

    #if canImport(BackgroundTasks)
    private static func handleRefresh(_ task: BGTask) {
        let refresh = task as? BGAppRefreshTask
        Task { @MainActor in
            await LumenRuntime.model?.reload()
            refresh?.setTaskCompleted(success: true)
            #if canImport(UserNotifications)
            await postWake()
            #endif
        }
    }

    private static func handleContinued(_ task: BGTask) {
        guard #available(iOS 26, *), let continued = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        continued.expirationHandler = {
            continued.setTaskCompleted(success: false)
        }
        continued.progress.totalUnitCount = 1
        continued.updateTitle("Lumen", subtitle: "Continuing")
        Task { @MainActor in
            await LumenRuntime.model?.reload()
            continued.progress.completedUnitCount = 1
            continued.setTaskCompleted(success: true)
            #if canImport(UserNotifications)
            await postWake()
            #endif
        }
    }
    #endif

    #if canImport(UserNotifications)
    private static func postWake() async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Lumen woke up")
        content.body = String(localized: "A timer or suspended run was checked.")
        let request = UNNotificationRequest(identifier: "lumen.wake", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
    #endif
}
