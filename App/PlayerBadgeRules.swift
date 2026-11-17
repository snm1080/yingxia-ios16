import Foundation
#if canImport(TVCore)
import TVCore
#endif

/// Ordered rules and artwork are copied from the installed MacCat. One match per group,
/// with probed media fields taking priority over release-name guesses.
struct PlayerBadgeRules {
    struct Row: Codable, Identifiable, Sendable {
        let id: String
        let name: String
        let pattern: String
        let groupId: String
        let imageURL: String
        let isEnabled: Bool
        let flags: String?
    }
    struct Document: Decodable { let filters: [Row] }
    struct Compiled {
        let row: Row
        let expression: NSRegularExpression
    }
    /// A catalog owns a small result cache shared by its value-type copies.
    /// Only cache bookkeeping is locked; Foundation matching runs outside it.
    private final class MatchCache: @unchecked Sendable {
        private struct Entry {
            let title: String
            let overrides: [String: String]
            let rows: [Row]
            func matches(title: String, overrides: [String: String]) -> Bool {
                // Swift String equality folds canonical Unicode equivalents,
                // while a regex can distinguish their actual code units.
                self.title.utf8.elementsEqual(title.utf8) && self.overrides.count == overrides.count
                    && self.overrides.allSatisfy { key, value in
                        overrides[key].map { value.utf8.elementsEqual($0.utf8) } ?? false
                    }
            }
        }
        private let lock = NSLock()
        private var entries: [Entry] = []
        func rows(title: String, overrides: [String: String]) -> [Row]? {
            lock.lock(); defer { lock.unlock() }
            guard let index = entries.firstIndex(where: { $0.matches(title: title, overrides: overrides) }) else { return nil }
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            return entry.rows
        }
        func store(_ rows: [Row], title: String, overrides: [String: String]) {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll { $0.matches(title: title, overrides: overrides) }
            entries.insert(Entry(title: title, overrides: overrides, rows: rows), at: 0)
            if entries.count > 16 { entries.removeLast(entries.count - 16) }
        }
    }
    private let matchCache = MatchCache()
    let rules: [Compiled]
    init(data: Data) throws {
        rules = try JSONDecoder().decode(Document.self, from: data).filters.compactMap { row in
            guard row.isEnabled, let image = URL(string: row.imageURL), ["https", "http"].contains(image.scheme?.lowercased() ?? ""), image.host != nil else { return nil }
            var options: NSRegularExpression.Options = []
            if row.flags?.contains("i") == true { options.insert(.caseInsensitive) }
            if row.flags?.contains("s") == true { options.insert(.dotMatchesLineSeparators) }
            guard let expression = try? NSRegularExpression(pattern: row.pattern, options: options) else { return nil }
            return Compiled(row: row, expression: expression)
        }
    }
    func matches(title: String, overrides: [String: String]) -> [Row] {
        let title = String(title.prefix(4096))
        if let cached = matchCache.rows(title: title, overrides: overrides) { return cached }
        var groups = Set<String>()
        let rows: [Row] = rules.compactMap { rule in
            guard !groups.contains(rule.row.groupId) else { return nil }
            let text = overrides[rule.row.groupId] ?? title
            guard rule.expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return nil }
            groups.insert(rule.row.groupId)
            return rule.row
        }
        matchCache.store(rows, title: title, overrides: overrides)
        return rows
    }
}

/// Pure queue filtering keeps displayed order independent of the source episode identity.
enum PlayerQueueFilter {
    static func visibleIndices(names: [String], query: String, group: Int, descending: Bool, defaultSeason: Int? = nil) -> [Int] {
        let search = query.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let numeric = number(search, query: true)
        let searchSeason = season(search)
        let result = names.indices.filter { index in
            if search.isEmpty { return names.count <= 100 || group == 0 || index / 100 + 1 == group }
            let name = names[index].precomposedStringWithCompatibilityMapping.lowercased()
            if let numeric {
                guard let candidate = number(name, query: false) else { return false }
                return numeric == candidate && (searchSeason == nil || searchSeason == (season(name) ?? defaultSeason))
            }
            return name.contains(search)
        }
        return descending ? result.reversed() : result
    }
    static func season(_ name: String) -> Int? { LocalDetailEpisodeNumbers.numbers(name).season }
    static func number(_ text: String, query: Bool) -> Int? {
        if query {
            let pattern = #"^(?:第\s*)?[0-9零〇一二两兩三四五六七八九十百千万萬]+\s*[集话話期回章节節]?$|^(?:s[ ._-]*\d+[ ._-]*)?e(?:p(?:isode)?s?)?[ ._:#-]*\d+$|^第[零〇一二两兩三四五六七八九十百千万萬0-9]+季[ ._-]*第?[零〇一二两兩三四五六七八九十百千万萬0-9]+[集话話期回章节節]$"#
            guard text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        } else if LocalDetailEpisodeNumbers.isExtra(text) { return nil }
        return LocalDetailEpisodeNumbers.numbers(text).episode
    }
}
