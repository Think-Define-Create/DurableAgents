# Apple calls in Assistant that were not compiled here

`swift test` on Linux does not build `Apps/Assistant`. The symbols below are the ones this target calls. They are long-standing frameworks or match Apple's current docs. They were not type-checked in this environment.

| Location | API | Why it might fail |
|---|---|---|
| `AppleBridge.swift` | `BGAppRefreshTaskRequest`, `BGProcessingTaskRequest`, `BGContinuedProcessingTaskRequest`, `BGTaskScheduler.shared.register` | Gated with `canImport(BackgroundTasks)` and not macOS. Requests go through `AppleRoutineWake.submit`, which uses iOS 27 `submitTaskRequest` and falls back to `submit`. A reply is covered by a continued-processing task (`reply.*` in Info.plist) with the `.fail` strategy. Each `reply.<id>` is registered right before it is submitted: submitting without a handler for the exact identifier raises an assertion that ends the app (seen on RAM-2025). Registering only the wildcard was not enough. |
| `AppleBridge.swift` | `UNUserNotificationCenter.requestAuthorization` and `add` | UserNotifications. The async `add` is the form this file uses. |
| `AppleBridge.swift` | `LAContext.evaluatePolicy(_:localizedReason:)` as `async throws` | The completion-handler form is older. This file calls the async form. |
| `AppleBridge.swift` | `SecItemAdd` / `SecItemCopyMatching` | Generic password for API keys. Conversation keys use `SecureEnclaveKeyProvider`. |
| `AssistantIntents.swift` | `AppShortcut` phrases with `\.applicationName`, `IntentDialog(stringLiteral:)` | App Intents. The dialog initializer is the most likely mismatch. |
| `AssistantModel.swift` | `FoundationModelsProvider` | Compiled only when Foundation Models is present and the OS is 26. Otherwise the demo model is used. |

Newer Apple APIs this target now calls. They compile against the iOS 27 SDK. Settings → Diagnostics checks Private Cloud Compute, background scheduling, and sentence embeddings on a device. The intents and Spotlight are not checked there:

- `PrivateCloudComputeLanguageModel` through `FoundationModelsProvider(privateCloud: true)`. Off until Apple grants the managed `com.apple.developer.private-cloud-compute` entitlement and Info.plist sets `DurableAgentsPrivateCloudEntitled`. Without it the framework stops the app (seen on RAM-2025, 2026-10-10).
- `BGTaskScheduler.submitTaskRequest` (iOS 27) and `BGContinuedProcessingTaskRequest` with `SubmissionStrategy.fail` (iOS 26).
- `LongRunningIntent.performBackgroundTask` for Ask Assistant and Run routine now (iOS 27).
- `NLContextualEmbedding` through `ContextualEmbedder` in `DurableRetrieval`.
- `CSSearchableIndex` with `completeUntilFirstUserAuthentication` lists each bot's name and latest message in Spotlight. Settings has a switch that removes them.
