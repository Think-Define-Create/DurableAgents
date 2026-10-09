# Apple calls in Assistant that were not compiled here

`swift test` on Linux does not build `Apps/Assistant`. The symbols below are the ones this target calls. They match the calls already used by Lumen, or long-standing frameworks. They were not type-checked in this environment.

| Location | API | Why it might fail |
|---|---|---|
| `AppleBridge.swift` | `BGAppRefreshTaskRequest`, `BGProcessingTaskRequest`, `BGTaskScheduler.shared.register`, `BGTaskScheduler.shared.submit` | Gated with `canImport(BackgroundTasks)` and not macOS. iOS 27 `submitTaskRequest` is not called. |
| `AppleBridge.swift` | `UNUserNotificationCenter.requestAuthorization` and `add` | UserNotifications. The async `add` is the form this file uses. |
| `AppleBridge.swift` | `LAContext.evaluatePolicy(_:localizedReason:)` as `async throws` | The completion-handler form is older. This file calls the async form. |
| `AppleBridge.swift` | `SecItemAdd` / `SecItemCopyMatching` | Generic password. Not Secure Enclave. Conversation keys use `KeychainKeyProvider`. |
| `AssistantIntents.swift` | `AppShortcut` phrases with `\.applicationName`, `IntentDialog(stringLiteral:)` | App Intents. The dialog initializer is the most likely mismatch. |
| `AssistantModel.swift` | `FoundationModelsProvider` | Compiled only when Foundation Models is present and the OS is 26. Otherwise the demo model is used. |

These iOS 27 names are not referenced in source, so this target cannot fail by guessing them:

- `PrivateCloudComputeLanguageModel`
- `submitTaskRequest` and `SubmissionStrategy`
- `LongRunningIntent`
- `NLContextualEmbedding`
- Spotlight retrieval (`CSSearchableIndex` and related queries)

`NLContextualEmbedding` is also absent from `DurableRetrieval`. The embedder is `HashEmbedder`.
