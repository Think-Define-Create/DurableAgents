import SwiftUI

/// Settings → Diagnostics. Runs one check per DurableAgents module on this device.
struct DiagnosticsView: View {
    var model: AssistantModel
    @State private var diagnostics = Diagnostics()
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            Section {
                Button {
                    Task { await diagnostics.run(model) }
                } label: {
                    HStack {
                        Text(diagnostics.running ? "Running…" : "Run All Checks")
                        Spacer()
                        if diagnostics.running { ProgressView() }
                    }
                }
                .disabled(diagnostics.running)
                if diagnostics.running, !diagnostics.current.isEmpty {
                    Text(diagnostics.current)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
                Toggle("Include Reminders and Calendar writes", isOn: $diagnostics.includeWrites)
                Toggle("Include paid cloud replies", isOn: $diagnostics.includeCloud)
            } footer: {
                Text("Checks use throwaway data. Writes create one test reminder and one test event, then delete them. Paid replies send one tiny request to each provider you have a key for.")
            }

            if let report = diagnostics.report {
                Section {
                    LabeledContent("Passed", value: "\(report.passed)")
                        .accessibilityIdentifier("diagnostics.passed")
                        .accessibilityValue("\(report.passed)")
                    LabeledContent("Failed", value: "\(report.failed)")
                        .accessibilityIdentifier("diagnostics.failed")
                        .accessibilityValue("\(report.failed)")
                    LabeledContent("Skipped", value: "\(report.results.count - report.passed - report.failed)")
                    LabeledContent("Run", value: report.startedAt.formatted(date: .abbreviated, time: .shortened))
                }
                ForEach(modules(report), id: \.self) { module in
                    Section(module) {
                        ForEach(report.results.filter { $0.module == module }) { result in
                            row(result)
                        }
                    }
                }
            }

            Section {
                Button("Send Test Notification in 5 Seconds") {
                    Task { await diagnostics.sendTestNotification() }
                }
                Button("Check Again in the Background") {
                    diagnostics.armBackgroundCheck()
                }
                if let background = diagnostics.background {
                    ForEach(background.results) { result in row(result) }
                    Text("Last background check \(background.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
            } header: {
                Text("While Locked")
            } footer: {
                Text("Lock the phone after tapping. iOS decides when to wake the app, often within an hour. The result shows here next time.")
            }
        }
        .navigationTitle("Diagnostics")
    }

    private func modules(_ report: DiagnosticReport) -> [String] {
        var seen: [String] = []
        for result in report.results where !seen.contains(result.module) {
            seen.append(result.module)
        }
        return seen
    }

    private func row(_ result: DiagnosticResult) -> some View {
        Button {
            if expanded.contains(result.id) {
                expanded.remove(result.id)
            } else {
                expanded.insert(result.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(result.status))
                    .foregroundStyle(color(result.status))
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.name).foregroundStyle(.primary)
                    Text(result.detail)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(expanded.contains(result.id) ? nil : 2)
                }
                Spacer()
                Text(String(format: "%.1fs", result.seconds))
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ status: DiagnosticResult.Status) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        }
    }

    private func color(_ status: DiagnosticResult.Status) -> Color {
        switch status {
        case .passed: .green
        case .failed: .red
        case .skipped: .secondary
        }
    }
}
