import Foundation
#if canImport(TVCore)
import TVCore
#endif

/// Presentation only. Playback, downloads and history always retain the source's Episode identity/order.
/// The grouping and filename rules follow MacCat's TmdbDetail and episode-numbers.mjs.
enum LocalCatalogDetailRules {
    static let groupSize = 30
    struct EpisodeKey {
        let index: Int
        let season: Int
        let number: Int?
        let extra: Bool
    }
    static func ordered(_ items: [EpisodeKey]) -> [EpisodeKey] {
        items.sorted { lhs, rhs in
            if lhs.extra != rhs.extra { return !lhs.extra }
            if (lhs.number == nil) != (rhs.number == nil) { return lhs.number != nil }
            if let left = lhs.number, let right = rhs.number {
                if lhs.season != rhs.season { return lhs.season < rhs.season }
                if left != right { return left < right }
            }
            return lhs.index < rhs.index
        }
    }
    static func page(_ items: [EpisodeKey], group: Int, descending: Bool) -> [EpisodeKey] {
        guard !items.isEmpty else { return [] }
        let start = min(max(0, group), (items.count - 1) / groupSize) * groupSize
        let selected = Array(items[start..<min(start + groupSize, items.count)])
        return descending ? selected.filter { !$0.extra }.reversed() + selected.filter(\.extra) : selected
    }
    static func episodeRange(_ numbers: [Int]) -> String {
        let sorted = Set(numbers).sorted()
        guard let first = sorted.first, let last = sorted.last else { return "" }
        if sorted.count > 1 && last - first == sorted.count - 1 { return "\(first)–\(last)" }
        return sorted.map(String.init).joined(separator: "、")
    }
    static func date(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let components = value.split(separator: "-").compactMap { Int($0) }
        let calendar = Calendar(identifier: .gregorian)
        guard components.count == 3,
              let date = calendar.date(from: DateComponents(year: components[0], month: components[1], day: components[2], hour: 12)),
              dateKey(date) == value else { return nil }
        return date
    }
    static func dateKey(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    static func numbers(_ name: String) -> (season: Int?, episode: Int?) { LocalDetailEpisodeNumbers.numbers(name) }
    static func isExtra(_ name: String) -> Bool { LocalDetailEpisodeNumbers.isExtra(name) }
}
