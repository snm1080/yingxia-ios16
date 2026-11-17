import Foundation

/// Resolved channels are copied by catalog/history views. Keep the source's remaining choices with the
/// resolved URL, so choosing a quality still runs its parser and stream preparation when needed.
public enum PlaybackQualityRegistry {
    private struct Entry: Sendable { let client: CatalogClient; let plan: PlaybackPlan; let selected: Int }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [URL: Entry] = [:]
    nonisolated(unsafe) private static var order: [URL] = []

    static func register(_ url: URL, client: CatalogClient, plan: PlaybackPlan, selected: Int) {
        guard plan.choices.count > 1 else { return }
        lock.withLock {
            entries[url] = Entry(client: client, plan: plan, selected: selected)
            order.removeAll { $0 == url }; order.append(url)
            while order.count > 256 { entries[order.removeFirst()] = nil }
        }
    }
    public static func qualities(for url: URL) -> [StreamQuality] {
        guard let entry = lock.withLock({ entries[url] }) else { return [] }
        return entry.plan.choices.compactMap { choice in
            URL(string: choice.address).map { StreamQuality(id: choice.id, label: choice.name, url: $0) }
        }
    }
    public static func selected(for url: URL) -> Int? { lock.withLock { entries[url]?.selected } }
    public static func resolve(for url: URL, quality: Int?) async throws -> Channel? {
        guard let entry = lock.withLock({ entries[url] }),
              let choice = quality.flatMap({ id in entry.plan.choices.first { $0.id == id } }) ?? entry.plan.choices.first else { return nil }
        return try await entry.client.resolvePlayback(entry.plan, choice: choice)
    }
}
