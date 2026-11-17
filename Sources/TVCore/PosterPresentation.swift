import Foundation

/// Artwork is independent of a playable address. Extensionless image endpoints remain valid,
/// while known share pages, video files and malformed provider placeholders do not reach the loader.
public enum PosterPresentation {
    /// A merged display key can acquire a different owner after subscription reordering.
    /// Matching for durable artwork uses the stable original catalog identity, with no old-key fallback.
    public static func matchSourceIdentity(origin: URL, sourceKey: String) -> String {
        let parts = [origin.absoluteString, sourceKey]
        return "catalog:" + parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
    public static func imageURL(_ candidate: URL?, excluding mediaAddresses: [String] = []) -> URL? {
        guard let candidate, ["http", "https"].contains(candidate.scheme?.lowercased() ?? ""),
              let host = candidate.host?.lowercased(), !host.isEmpty,
              candidate.user == nil, candidate.password == nil,
              !mediaAddresses.contains(candidate.absoluteString) else { return nil }
        let path = candidate.path.lowercased()
        let leaf = candidate.lastPathComponent.lowercased()
        guard !["null", "nil", "none", "undefined", "(null)"].contains(leaf),
              !["m3u8", "m3u", "mpd", "mp4", "mkv", "avi", "mov", "ts", "m2ts", "iso", "flv", "wmv", "mp3", "m4a", "flac"].contains(candidate.pathExtension.lowercased()) else { return nil }
        if MediaPush.requiresFiles(candidate.absoluteString),
           path.range(of: "^/(?:s|t|share|web/share|drive/s)(?:/|$)", options: .regularExpression) != nil { return nil }
        let decoded = candidate.absoluteString.removingPercentEncoding ?? candidate.absoluteString
        guard decoded.range(of: "[\\r\\n]", options: .regularExpression) == nil,
              decoded.range(of: "(?:@|\\|)(?:headers|cookie|referer|user-agent)=", options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        return candidate
    }

    public static func imageHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter {
            $0.key.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil &&
            $0.value.rangeOfCharacter(from: .newlines) == nil
        }
    }

    /// Some Python detail parsers return the first article image instead of the listed work's cover.
    /// The caller supplies the list item from the same source, including after a cached-page restore.
    public static func catalogDetail(_ detail: Video, listing: Video, preferListing: Bool) -> Video {
        let excluded = [detail.id] + detail.episodes.map(\.address)
        let direct = imageURL(detail.poster, excluding: excluded)
        let listed = listing.id == detail.id ? imageURL(listing.poster, excluding: excluded) : nil
        if let listed, preferListing || direct == nil {
            return replacing(listed, headers: listing.posterHeaders, in: detail)
        }
        return replacing(direct, headers: detail.posterHeaders, in: detail)
    }

    /// An already identified work may replace a provider's generic push image. Preserve every
    /// provider ID, episode, folder and metadata field; artwork never changes what will be played.
    public static func applying(_ poster: URL?, headers: [String: String] = [:], to video: Video) -> Video {
        guard let poster = imageURL(poster, excluding: [video.id] + video.episodes.map(\.address)) else { return video }
        return replacing(poster, headers: headers, in: video)
    }
    public static func replacing(_ poster: URL?, headers: [String: String] = [:], in video: Video) -> Video {
        let poster = imageURL(poster, excluding: [video.id] + video.episodes.map(\.address))
        return Video(id: video.id, name: video.name, poster: poster, posterHeaders: imageHeaders(headers), year: video.year,
                     remarks: video.remarks, synopsis: video.synopsis, episodes: video.episodes, category: video.category,
                     action: video.action, folderCategoryID: video.isFolder ? video.folderCategoryID : nil,
                     folderFilters: video.folderFilters, area: video.area, director: video.director, actor: video.actor)
    }
}

/// MacCat keeps the source's year/type above the art and splits resource remarks into separate
/// chips below it. Bound pasted metadata so a provider cannot cover the whole poster with text.
public struct SourcePosterBadges: Equatable, Sendable {
    public let top: [String]
    public let bottom: [String]
    public init(year: String?, category: String?, remarks: String) {
        func clean(_ value: String) -> String {
            value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.map(clean).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        let kinds = unique((category ?? "").components(separatedBy: CharacterSet(charactersIn: ",，")))
            .filter { !["folder", "file", "search", "subtitle"].contains($0.lowercased()) }
        top = unique([year ?? ""] + kinds).prefix(3).map { String($0.prefix(24)) }
        bottom = unique(remarks.components(separatedBy: CharacterSet(charactersIn: "·|｜")))
            .prefix(4).map { String($0.prefix(48)) }
    }
}
