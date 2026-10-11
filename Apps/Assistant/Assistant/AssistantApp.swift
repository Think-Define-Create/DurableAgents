import CoreSpotlight
import SwiftUI
import UserNotifications

@main
struct AssistantApp: App {
    @State private var model = AssistantModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    AssistantRuntime.model = model
                    await model.bootstrap()
                    #if DEBUG
                    if SelfTest.requested {
                        await SelfTest.run(model)
                    }
                    #endif
                    if Diagnostics.requested {
                        let diagnostics = Diagnostics()
                        diagnostics.includeWrites = ProcessInfo.processInfo.arguments.contains("-diagnostics-writes")
                        await diagnostics.run(model)
                    }
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    model.openRequest = AssistantSpotlight.botID(from: activity)
                }
        }
    }
}

@MainActor
enum AssistantRuntime {
    static weak var model: AssistantModel?
}
