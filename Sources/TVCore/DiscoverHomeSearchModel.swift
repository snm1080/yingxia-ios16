import Foundation
import Perception

/// Home catalog search owns its history and requests independently of subscription/source searches.
@MainActor @Perceptible public final class DiscoverHomeSearchModel {
    public private(set) var submittedQuery = ""
    public private(set) var items: [TMDBCatalog.Item] = []
    public private(set) var suggestions: [String] = []
    public private(set) var history: [String]
    public private(set) var loading = false
    public private(set) var suggesting = false
    public private(set) var error: String?
    private let defaults: UserDefaults
    private let historyKey = "local.home.search.history.v1"
    private var generation = 0
    private var suggestionGeneration = 0
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = Array((defaults.stringArray(forKey: historyKey) ?? []).filter { !$0.isEmpty }.prefix(10))
    }

    public static func search(_ query: String) async throws -> [TMDBCatalog.Item] {
        async let movies = TMDBCatalog.search(query: query, kind: .movie)
        async let series = TMDBCatalog.search(query: query, kind: .tv)
        let pages = try await [movies, series]
        // Keep each provider's relevance order while mixing movies and series; exact titles come first.
        var values: [TMDBCatalog.Item] = [], seen = Set<String>()
        for index in 0..<(pages.map { $0.items.count }.max() ?? 0) {
            for page in pages where index < page.items.count {
                let item = page.items[index]
                if seen.insert(item.key).inserted { values.append(item) }
            }
        }
        return Array((values.filter { $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame }
            + values.filter { $0.name.localizedCaseInsensitiveCompare(query) != .orderedSame }).prefix(30))
    }

    public func suggest(_ query: String, using read: @escaping @Sendable (String) async throws -> [TMDBCatalog.Item] = DiscoverHomeSearchModel.search) async {
        suggestionGeneration += 1
        let own = suggestionGeneration, value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestions = []; suggesting = false
        guard !value.isEmpty, value != submittedQuery else { return }
        do {
            try await Task.sleep(for: .milliseconds(220))
            guard own == suggestionGeneration, !Task.isCancelled else { return }
            suggesting = true
            let answer = try await read(value)
            guard own == suggestionGeneration, !Task.isCancelled else { return }
            var seen = Set<String>()
            suggestions = Array(answer.map(\.name).filter { seen.insert($0).inserted }.prefix(8))
        } catch { /* A suggestion failure leaves explicit search available. */ }
        if own == suggestionGeneration { suggesting = false }
    }

    public func submit(_ query: String, using read: @escaping @Sendable (String) async throws -> [TMDBCatalog.Item] = DiscoverHomeSearchModel.search) async {
        let value = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !value.isEmpty else { return }
        generation += 1; suggestionGeneration += 1
        let own = generation
        submittedQuery = value; suggestions = []; suggesting = false; loading = true; error = nil; items = []
        history.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        history.insert(value, at: 0); history = Array(history.prefix(10)); saveHistory()
        defer { if own == generation { loading = false } }
        do {
            let answer = try await read(value)
            guard own == generation, !Task.isCancelled else { return }
            items = answer
        } catch { if own == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }

    public func removeHistory(_ query: String) { history.removeAll { $0 == query }; saveHistory() }
    public func clearHistory() { history = []; saveHistory() }
    public func cancel() { generation += 1; suggestionGeneration += 1; loading = false; suggesting = false }
    private func saveHistory() { defaults.set(history, forKey: historyKey) }
}
