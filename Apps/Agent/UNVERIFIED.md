# Apple-only code that was not compiled

`swift test` on Linux covers `AgentAppCore` and the rest of the package. Nothing in `Apps/Agent` was type-checked. The calls below are the ones most likely to fail in Xcode 26. They were chosen from current Apple docs, not invented names, but the signatures were not compiled here.

| Location | API | Why it might fail |
|---|---|---|
| `AppleServices.swift` | `BGContinuedProcessingTaskRequest(identifier:title:subtitle:)` and `request.strategy = .queue` | Documented for iOS 26 continued processing. `.queue` is the least certain symbol. |
| `AppleServices.swift` | `BGContinuedProcessingTask.updateTitle(_:subtitle:)` | Same task family. |
| `AppleServices.swift` | `LAContext.evaluatePolicy(_:localizedReason:)` as `async throws` | The completion-handler form is older and definitely exists. The async form is what this file calls. |
| `AppleServices.swift` | `Activity.request`, `ActivityContent`, `Activity.update` | ActivityKit. Live Activity attributes live in `AgentAppCore` behind `canImport(ActivityKit)`. |
| `LumenWidget.swift` | `ActivityConfiguration` and `DynamicIsland` | Widget extension, iOS only. |
| `RootView.swift`, `Screens.swift` | `buttonStyle(.glass)` and `.glassProminent` | iOS 26 / macOS 26 Liquid Glass button styles, gated with `#available`. |
| `AppleToolHosts.swift` | `EKEventStore.requestFullAccessToEvents()` and `requestFullAccessToReminders()` | iOS 17+ replacements for `requestAccess(to:)`. |
| `AppleToolHosts.swift` | `CNContactStore.requestAccess(for: .contacts)` | Long-standing Contacts API. Limited-access contacts on newer iOS may need a different request. |
| `AppleToolHosts.swift` | `VNRecognizeTextRequest` | Vision. The completion and `perform` can both fire; a double resume is guarded only for Speech, not for this request. |
| `Capture.swift` | `VNDocumentCameraViewController` | iOS VisionKit. |
| `AppleServices.swift` | `SFSpeechRecognizer` and `AVAudioEngine` tap | Speech. The four-second cutoff resumes the continuation once. |
| `LumenIntents.swift` | `AppShortcut` phrases with `\.applicationName`, `IntentDialog(stringLiteral:)` | App Intents. The dialog initializer is the most likely mismatch. |
| `KeychainSecretStore.swift` | `SecItemAdd` / `SecItemCopyMatching` | Standard Keychain. Not Secure Enclave. Conversation keys use `KeychainKeyProvider` in DurableSecurity, which is also a generic password, not an enclave key. |
| `AgentModel.swift` | `FoundationModelsProvider` | Compiled only when the Foundation Models framework is present and the OS is 26. Otherwise the offline demo is used. |
| Signing | App Group `group.dev.thinkdefinecreate.Lumen` | Automatic signing must register the group. There is no `aps-environment` entitlement on purpose. |
| `Sources/DurableSchedule/AppleWake.swift` | `BGAppRefreshTaskRequest`, `BGProcessingTaskRequest`, `BGTaskScheduler.submit`, `UNUserNotificationCenter.add` | Gated with `canImport(BackgroundTasks)` and `canImport(UserNotifications)`, so Linux does not compile it. iOS 27's `submitTaskRequest` is not called. |
| Retrieval | `NLContextualEmbedding` | Not called. Linux and the package use `HashEmbedder`. Do not assume a Natural Language embedding API. |
| `Apps/Assistant` | Same background, notification, Face ID, Keychain, and App Intents calls as the rows above | The Assistant target was not compiled on Linux. iOS 27 names `PrivateCloudComputeLanguageModel`, `submitTaskRequest`, `LongRunningIntent`, and Spotlight retrieval are not in that source. See `Apps/Assistant/UNVERIFIED.md`. |

Not implemented, on purpose:

- CloudKit sync.
- An OpenTelemetry exporter. Settings only stores the endpoint string.
- Secure Enclave wrapping of the conversation key. The key is a Keychain generic password.
- Remote push. Local notifications carry the approval actions.
- Partial token streaming from Foundation Models. One `respond` call is one checkpoint, same as `DurableFoundationModels`.
