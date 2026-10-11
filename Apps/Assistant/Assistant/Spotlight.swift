import AgentAppKit
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Lists each bot in Spotlight by name and its latest message, so a search on the phone opens that chat.
/// Only the name and one short preview leave the encrypted log. The person can turn it off in Settings,
/// which removes everything this app indexed.
enum AssistantSpotlight {
    static let enabledKey = "spotlight.enabled"
    static let domain = "bots"
    private static let prefix = "bot:"
    nonisolated(unsafe) private static var lastSignature = ""

    static var enabled: Bool {
        !AssistantModel.sandboxed && (UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true)
    }

    private static var index: CSSearchableIndex {
        CSSearchableIndex(name: "Assistant", protectionClass: .completeUntilFirstUserAuthentication)
    }

    /// Replaces the bot entries when a name or preview changed. Cheap to call after every reload.
    @MainActor
    static func update(agents: [AgentProfile], previews: [String: AgentPreview]) {
        guard enabled else { return }
        let visible = agents.filter { !$0.archived }
        let signature = visible.map { "\($0.id)|\($0.title)|\(previews[$0.id]?.text.prefix(140) ?? "")" }.joined(separator: "\n")
        guard signature != lastSignature else { return }
        lastSignature = signature
        let items = visible.map { agent -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = agent.title
            if let preview = previews[agent.id] {
                attributes.contentDescription = String(preview.text.prefix(140))
                attributes.contentModificationDate = preview.at
            }
            attributes.keywords = ["Assistant", "bot", "chat"]
            return CSSearchableItem(uniqueIdentifier: prefix + agent.id, domainIdentifier: domain, attributeSet: attributes)
        }
        let index = self.index
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items)
        }
    }

    static func removeAll() {
        lastSignature = ""
        index.deleteAllSearchableItems()
    }

    /// The bot id in a Spotlight result the person tapped.
    static func botID(from activity: NSUserActivity) -> String? {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              identifier.hasPrefix(prefix) else { return nil }
        return String(identifier.dropFirst(prefix.count))
    }
}
