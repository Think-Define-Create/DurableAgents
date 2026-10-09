import AgentAppCore
import SwiftUI
import WidgetKit

struct LumenEntry: TimelineEntry {
    let date: Date
    let pending: Int
    let running: Int
    let prompt: String
}

struct LumenProvider: TimelineProvider {
    func placeholder(in context: Context) -> LumenEntry {
        LumenEntry(date: Date(), pending: 1, running: 1, prompt: "Waiting for approval")
    }

    func getSnapshot(in context: Context, completion: @escaping (LumenEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LumenEntry>) -> Void) {
        let entry = load()
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func load() -> LumenEntry {
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.thinkdefinecreate.Lumen")?
            .appendingPathComponent("lumen-widget.json")
        if let url, let snapshot = try? WidgetSnapshot.read(from: url) {
            return LumenEntry(
                date: Date(),
                pending: snapshot.pendingApprovals,
                running: snapshot.runningAgents,
                prompt: snapshot.prompts.first ?? "Nothing is waiting"
            )
        }
        return LumenEntry(date: Date(), pending: 0, running: 0, prompt: "Open Lumen to refresh")
    }
}

struct LumenStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LumenStatus", provider: LumenProvider()) { entry in
            VStack(alignment: .leading, spacing: 6) {
                Text("Lumen").font(.headline)
                Text("\(entry.pending) waiting · \(entry.running) active")
                Text(entry.prompt).font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
            .accessibilityElement(children: .combine)
        }
        .configurationDisplayName("Lumen")
        .description("Pending approvals and agents that are still running.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#if os(iOS)
struct LumenLiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LumenActivityAttributes.self) { context in
            VStack(alignment: .leading) {
                Text(context.attributes.agentTitle).font(.headline)
                Text(context.state.status)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.agentTitle)
                    Text(context.state.status)
                }
            } compactLeading: {
                Image(systemName: "sparkles")
            } compactTrailing: {
                Text(context.state.status).lineLimit(1)
            } minimal: {
                Image(systemName: "sparkles")
            }
        }
    }
}
#endif

@main
struct LumenWidgetBundle: WidgetBundle {
    var body: some Widget {
        LumenStatusWidget()
        #if os(iOS)
        LumenLiveWidget()
        #endif
    }
}
