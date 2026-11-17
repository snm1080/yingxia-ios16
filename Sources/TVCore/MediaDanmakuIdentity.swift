import Foundation

/// Matching metadata is separate from the provider's displayed title/file label.
/// Share titles contain release labels and file names carry their episode number.
public enum MediaDanmakuIdentity {
    public static func title(_ name: String) -> String {
        let cleaned = TMDBTitleMatching.query(name)
        guard !cleaned.isEmpty else { return name }
        if let season = TMDBTitleMatching.season(name), season > 1 { return "\(cleaned) 第\(season)季" }
        return cleaned
    }
    public static func episode(_ name: String) -> String {
        if let number = CatalogDanmakuMatcher.episodeNumber(name) { return "第\(number)集" }
        return name
    }
}
