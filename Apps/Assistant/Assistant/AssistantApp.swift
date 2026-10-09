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
                }
        }
    }
}

@MainActor
enum AssistantRuntime {
    static weak var model: AssistantModel?
}
