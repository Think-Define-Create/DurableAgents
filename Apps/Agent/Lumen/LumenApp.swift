import SwiftUI
import UserNotifications

@main
struct LumenApp: App {
    @State private var model = AgentModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    LumenRuntime.model = model
                    UNUserNotificationCenter.current().delegate = NotificationBridge.shared
                    await model.bootstrap()
                }
        }
    }
}

final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationBridge()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let token = response.notification.request.content.userInfo["token"] as? String ?? ""
        let risk = response.notification.request.content.userInfo["risk"] as? String
        let action = response.actionIdentifier
        guard action == "approve" || action == "deny" else {
            return
        }
        await Self.decide(token: token, approved: action == "approve", highRisk: risk == "high")
    }

    @MainActor
    private static func decide(token: String, approved: Bool, highRisk: Bool) async {
        await LumenRuntime.model?.decide(token: token, approved: approved, highRisk: highRisk)
    }
}
