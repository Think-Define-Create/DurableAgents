import SwiftUI

@main
struct EscrowAssistantApp: App {
    @State private var appModel: AppModel?
    @State private var launchError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let appModel {
                    RootView(app: appModel)
                } else if let launchError {
                    LaunchFailure(message: launchError)
                } else {
                    ProgressView("Opening the journal…")
                        .padding()
                }
            }
            .task {
                guard appModel == nil, launchError == nil else { return }
                do {
                    appModel = try await AppModel.launch()
                } catch {
                    launchError = String(describing: error)
                }
            }
        }
    }
}

private struct LaunchFailure: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The journal did not open")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
