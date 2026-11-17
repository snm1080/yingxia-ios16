import Foundation
import Perception

/// Settings → Watch Now: History and Continue Watching add the file's size and picture quality to an episode's
/// number, read from its file name ("第1集 · 5.4GB · 2160p", #595). Off by default.
public enum HistoryFileDetails {
    public static let key = "showsHistoryFileDetails"
}

public enum PlaybackResumeMode: Sendable { case resume, beginning }

/// Reading uses zero-based page indices, never the video's seconds fields. Optional on the
/// context so existing video histories and backups decode without a migration.
public struct ReadingHistoryProgress: Codable, Hashable, Sendable {
    public let page: Int
    public let totalPages: Int
    public init(page: Int, totalPages: Int) { self.page = page; self.totalPages = totalPages }
    public var isValid: Bool { totalPages > 0 && page >= 0 && page < totalPages }
}

/// Catalog identity only: an expiring stream URL or its authorization headers must
/// never become the address used to resume a saved episode.
public struct PlaybackHistoryContext: Codable, Hashable, Sendable {
    public let origin: URL
    public let sourceKey: String
    public let sourceName: String
    public let videoID: String
    public let videoName: String
    public private(set) var poster: URL?
    public let episodeID: String
    public let episodeName: String
    public let episodeFlag: String
    public var year: String?
    /// Only validated public official pages are retained, never signed stream addresses.
    public var officialPage: URL?
    public var posterHeaders: [String: String]?
    /// A home work identity or confirmed TMDB match supplied this image, rather than a push placeholder.
    public var posterIsConfirmed: Bool?
    public var posterConfirmedAt: Date?
    /// The subscription selected when playback began. Empty means the standalone library.
    /// Older records infer their owner from their catalog origin without rewriting or deleting them.
    public var historyScope: String?
    public var readingProgress: ReadingHistoryProgress?
    public var libraryScope: String? {
        if let historyScope { return historyScope.isEmpty ? nil : historyScope }
        return LocalMediaLibrary.isLocalSource(sourceKey) || sourceKey == CloudFiles.sourceKey ? nil : origin.absoluteString
    }
    public var historyIdentity: String {
        let source = Self.sourceIdentity(origin)
        let catalog = source == origin ? id : EpisodeSkipSettings.scope(origin: source, source: sourceKey, video: videoID)
        let parts = [libraryScope ?? "", catalog, episodeFlag, episodeID]
        return parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
    public var id: String { EpisodeSkipSettings.scope(origin: origin, source: sourceKey, video: videoID) }

    /// App-owned code updates use new version paths. The record ID remains the provider identity;
    /// keep the original origin on each context for resolving relative assets and recovering covers.
    public static func sourceIdentity(_ origin: URL) -> URL {
        guard origin.scheme?.lowercased() == "https", origin.host()?.lowercased() == "sources.yingxia.invalid" else { return origin }
        let parts = origin.pathComponents.filter { $0 != "/" }
        guard let record = parts.first, record.count == 64, record.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              (parts.count == 2 && parts[1] == "subscription") ||
              (parts.count >= 3 && parts[1].count == 64 && parts[1].allSatisfy({ $0.isASCII && $0.isHexDigit })) else { return origin }
        return URL(string: "https://sources.yingxia.invalid/\(record)/subscription")!
    }

    /// A title's reading/playback history follows its provider across imported code updates.
    /// The caller filters the selected subscription before matching list and detail video IDs.
    public func matchesVideo(origin: URL, sourceKey: String, videoIDs: Set<String>) -> Bool {
        Self.sourceIdentity(self.origin) == Self.sourceIdentity(origin) && self.sourceKey == sourceKey && videoIDs.contains(videoID)
    }

    public init(origin: URL, sourceKey: String, sourceName: String, videoID: String, videoName: String,
                poster: URL? = nil, episodeID: String, episodeName: String, episodeFlag: String) {
        self.origin = origin; self.sourceKey = sourceKey; self.sourceName = sourceName
        self.videoID = videoID; self.videoName = videoName
        self.poster = PosterPresentation.imageURL(poster, excluding: [origin.absoluteString, videoID, episodeID])
        self.episodeID = episodeID; self.episodeName = episodeName; self.episodeFlag = episodeFlag
    }

    public init(origin: URL, site: Site, video: Video, episode: Episode) {
        self.init(origin: site.origin(or: origin), sourceKey: site.sourceKey, sourceName: site.name, videoID: video.id,
                  videoName: video.name, poster: video.poster, episodeID: episode.id,
                  episodeName: episode.name, episodeFlag: episode.flag)
        year = video.year
        posterHeaders = video.posterHeaders.isEmpty ? nil : video.posterHeaders
        officialPage = OfficialVideoPage.validated(episode.address)
        if let artwork = PushMediaLibrary.shared.record(origin: self.origin, sourceKey: sourceKey, videoID: videoID)?.artwork {
            self = replacingPoster(artwork.poster, headers: artwork.headers, confirmed: artwork.isConfirmed ?? true,
                                   confirmedAt: artwork.confirmedAt ?? .distantPast)
        }
    }

    public func replacingPoster(_ poster: URL?, headers: [String: String] = [:], confirmed: Bool = false,
                                confirmedAt: Date? = nil) -> Self {
        var result = self
        result.poster = PosterPresentation.imageURL(poster, excluding: [origin.absoluteString, videoID, episodeID])
        let clean = result.poster == nil ? [:] : PosterPresentation.imageHeaders(headers)
        result.posterHeaders = clean.isEmpty ? nil : clean
        result.posterIsConfirmed = confirmed || confirmedAt != nil ? confirmed : nil
        result.posterConfirmedAt = confirmedAt ?? (confirmed && result.poster != nil ? Date() : nil)
        return result
    }
    public var artworkDecisionDate: Date? { posterConfirmedAt ?? (posterIsConfirmed == true ? .distantPast : nil) }

    /// A legacy record may contain the share as its title. Keep the stored identity intact and
    /// expose a readable label without printing credentials or a signed URL below the poster.
    public var displayTitle: String {
        func readable(_ value: String) -> String? {
            let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  title.range(of: "^(?:[a-z][a-z0-9+.-]*://|magnet:|ed2k:|thunder:|//)", options: [.regularExpression, .caseInsensitive]) == nil,
                  !["推送", "push", "播放", "play", "video", "视频"].contains(title.lowercased()) else { return nil }
            return title
        }
        if let title = readable(videoName) { return title }
        if let title = readable(episodeName), title.range(of: "^第?\\d+[集期话]?$", options: .regularExpression) == nil { return title }
        return sourceKey.localizedCaseInsensitiveContains("push") || sourceName.contains("推送") ? "推送视频" : "未命名视频"
    }

    /// Names survive list reordering. Never silently resume a different episode
    /// just because a source now gives it the saved numeric index.
    public func episode(in episodes: [Episode]) -> Episode? {
        let matches = episodes.filter { $0.flag == episodeFlag && $0.name == episodeName }
        if let exact = matches.first(where: { $0.id == episodeID }) { return exact }
        return matches.count == 1 ? matches.first : nil
    }
}

public struct PlaybackHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let context: PlaybackHistoryContext
    public let position: Double
    public let duration: Double
    public let updatedAt: Date
    public var id: String { context.historyIdentity }
    public var completed: Bool {
        if let reading = context.readingProgress { return reading.isValid && reading.page == reading.totalPages - 1 }
        return duration > 0 && position >= duration - 1
    }
    public var resumePosition: Double { completed ? 0 : position }
    public func position(for mode: PlaybackResumeMode) -> Double { mode == .beginning ? 0 : resumePosition }
    public var progress: Double {
        if let reading = context.readingProgress { return reading.isValid ? Double(reading.page + 1) / Double(reading.totalPages) : 0 }
        return duration > 0 ? min(1, max(0, position / duration)) : 0
    }

    /// Where to start an episode again: the saved position when it is the episode this entry is about, so
    /// picking it from a list picks up where it stopped. Any other episode starts at 0, and so does an entry
    /// finished or barely started.
    public func resumePosition(for episode: Episode) -> Double? {
        guard context.episode(in: [episode]) != nil, resumePosition > 1 else { return nil }
        return resumePosition
    }

    /// What Continue plays on the video's page: the episode watched last, or, once that one is finished, the next
    /// one on its line. Nil when the details no longer list it or a finished episode was the line's last, so
    /// Play starts the line instead.
    public func continuation(in episodes: [Episode]) -> Episode? {
        completed ? EpisodePlaylist(episodes).next(after: context) : context.episode(in: episodes)
    }

    public init(context: PlaybackHistoryContext, position: Double, duration: Double, updatedAt: Date) {
        self.context = context
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }

    public static func resumeTarget(_ position: Double, duration: Double) -> Double? {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0 else { return nil }
        return min(position, max(0, duration - 0.25))
    }
}

extension PlaybackHistoryEntry {
    /// Watching saves the title, matching the detail page and the title-only favorites library.
    public func favoriteItem() -> FavoriteItem {
        if context.sourceKey == CloudFiles.sourceKey {
            return .cloud(FavoriteCloudFile(driveKey: context.episodeFlag, folderID: context.videoID, folderName: context.videoName, fileID: context.episodeID, fileName: context.episodeName, size: 0))
        }
        let video = FavoriteVideo(origin: context.origin, sourceKey: context.sourceKey, sourceName: context.sourceName, videoID: context.videoID, videoName: context.videoName, poster: context.poster, posterHeaders: context.posterHeaders ?? [:], year: context.year)
        return .video(video)
    }
}

/// Shared by the library and player, bounded per subscription and atomically persisted outside
/// UserDefaults so a growing history does not hit its size limit.
@MainActor @Perceptible public final class PlaybackHistory {
    public static let shared = PlaybackHistory()
    public static let limit = 600
    public private(set) var entries: [PlaybackHistoryEntry] = []
    public private(set) var persistenceError: String?
    public var isEnabled = true
    @PerceptionIgnored private let persistence: PlaybackHistoryPersistence
    @PerceptionIgnored private var persistenceRevision: UInt64 = 0
    @PerceptionIgnored private var entriesRevision: UInt64 = 0
    private struct Artwork {
        let context: PlaybackHistoryContext
        let poster: URL?
        let headers: [String: String]
        let confirmed: Bool
        let confirmedAt: Date
    }
    @PerceptionIgnored private var confirmedArtwork: [Artwork] = []
    private let cache: MediaCache
    /// Store updates this when the selected subscription changes during playback. Nil leaves explicit
    /// contexts alone (imports); an empty string records in the standalone library.
    public var recordingScope: String?
    /// Called after the history changes here (not after `adopt`), for iCloud sync.
    @PerceptionIgnored public var onChange: (@MainActor () -> Void)?

    public init(file: URL? = nil, cache: MediaCache = .shared, defaults: UserDefaults = .standard) {
        self.cache = cache
        #if os(tvOS)
        let directory = URL.cachesDirectory
        #else
        let directory = URL.applicationSupportDirectory
        #endif
        let file = file ?? directory.appending(path: "playback-history-v1.json")
        persistence = PlaybackHistoryPersistence.writer(for: file)
        if let latest = persistence.latestEntries {
            entries = latest
            entriesRevision = persistence.latestRevision
        } else if let data = try? Data(contentsOf: file), data.count <= 32 * 1024 * 1024,
           let decoded = try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data) {
            var seen = Set<String>()
            entries = Self.bounded(decoded.filter { Self.valid($0) }.sorted { $0.updatedAt > $1.updatedAt }
                .filter { seen.insert($0.id).inserted })
        }
        persistence.prioritize(entries, cache: cache)
    }

    public func record(_ originalContext: PlaybackHistoryContext, position: Double, duration: Double, now: Date = Date()) {
        guard isEnabled else { return }
        guard position.isFinite, position >= 0, duration.isFinite, duration >= 0 else { return }
        if let reading = originalContext.readingProgress {
            guard reading.isValid else { return }
        } else if position < 1 { return }
        var context = originalContext
        if context.poster != nil, PosterPresentation.imageURL(context.poster, excluding: [context.videoID, context.episodeID]) == nil {
            context = context.replacingPoster(nil, confirmedAt: context.posterConfirmedAt)
        }
        if let recordingScope { context.historyScope = recordingScope }
        refreshPendingEntries()
        if let known = confirmedArtwork.last(where: { $0.context.id == context.id && $0.context.libraryScope == context.libraryScope }),
           context.artworkDecisionDate == nil || known.confirmedAt > (context.artworkDecisionDate ?? .distantPast) {
            context = context.replacingPoster(known.poster, headers: known.headers, confirmed: known.confirmed, confirmedAt: known.confirmedAt)
        }
        if let old = latestArtworkDecision(for: context),
           context.artworkDecisionDate == nil || (old.artworkDecisionDate ?? .distantPast) > (context.artworkDecisionDate ?? .distantPast) {
            context = context.replacingPoster(old.poster, headers: old.posterHeaders ?? [:], confirmed: old.posterIsConfirmed == true,
                                             confirmedAt: old.artworkDecisionDate)
        } else if context.poster == nil, context.artworkDecisionDate == nil,
                  let old = entries.first(where: { $0.id == context.historyIdentity }),
                  let image = PosterPresentation.imageURL(old.context.poster) {
            context = context.replacingPoster(image, headers: old.context.posterHeaders ?? [:])
        }
        let entry = PlaybackHistoryEntry(context: context, position: context.readingProgress == nil ? (duration > 0 ? min(position, duration) : position) : 0,
                                         duration: context.readingProgress == nil ? duration : 0, updatedAt: now)
        guard Self.valid(entry) else { return }
        if let old = entries.first(where: { $0.id == entry.id }), old.context == context,
           abs(old.position - entry.position) < 0.25, old.duration == duration { return }
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        entries = Self.bounded(entries)
        persist()
        onChange?()
    }

    /// Existing rows and a session that has not reached its first progress tick share the same
    /// confirmed cover. A later tick may still carry the provider placeholder; it cannot undo this.
    /// Recovery callers compare the old poster so an asynchronous cache read cannot overwrite a new choice.
    public func updateArtwork(for reference: PlaybackHistoryContext, poster: URL, headers: [String: String] = [:],
                              onlyIfUnchanged: Bool = false, decidedAt: Date = Date()) {
        guard let poster = PosterPresentation.imageURL(poster, excluding: [reference.videoID, reference.episodeID]) else { return }
        decideArtwork(for: reference, poster: poster, headers: headers, confirmed: true, onlyIfUnchanged: onlyIfUnchanged, decidedAt: decidedAt)
    }
    /// A rejected match is a newer decision even when the fallback has no image. Old sessions and
    /// optional cache writes cannot turn that explicit choice back into the former TMDB cover.
    public func resetArtwork(for reference: PlaybackHistoryContext, poster: URL? = nil, headers: [String: String] = [:],
                             onlyIfUnchanged: Bool = false, decidedAt: Date = Date()) {
        decideArtwork(for: reference, poster: poster, headers: headers, confirmed: false, onlyIfUnchanged: onlyIfUnchanged, decidedAt: decidedAt)
    }
    private func latestArtworkDecision(for reference: PlaybackHistoryContext) -> PlaybackHistoryContext? {
        entries.lazy.map(\.context).filter {
            $0.id == reference.id && $0.libraryScope == reference.libraryScope && $0.artworkDecisionDate != nil
        }.max { ($0.artworkDecisionDate ?? .distantPast) < ($1.artworkDecisionDate ?? .distantPast) }
    }
    private func decideArtwork(for reference: PlaybackHistoryContext, poster: URL?, headers: [String: String],
                               confirmed: Bool, onlyIfUnchanged: Bool, decidedAt: Date) {
        refreshPendingEntries()
        if onlyIfUnchanged {
            guard let current = entries.first(where: { $0.id == reference.historyIdentity }),
                  current.context.poster == reference.poster,
                  current.context.posterIsConfirmed == reference.posterIsConfirmed,
                  current.context.posterConfirmedAt == reference.posterConfirmedAt else { return }
        }
        if let known = confirmedArtwork.last(where: { $0.context.id == reference.id && $0.context.libraryScope == reference.libraryScope }),
           known.confirmedAt > decidedAt { return }
        if let latest = latestArtworkDecision(for: reference)?.artworkDecisionDate, latest > decidedAt { return }
        confirmedArtwork.removeAll { $0.context.id == reference.id && $0.context.libraryScope == reference.libraryScope }
        confirmedArtwork.append(Artwork(context: reference, poster: poster, headers: headers, confirmed: confirmed, confirmedAt: decidedAt))
        if confirmedArtwork.count > 32 { confirmedArtwork.removeFirst(confirmedArtwork.count - 32) }
        var changed = false
        entries = entries.map { entry in
            guard entry.context.id == reference.id, entry.context.libraryScope == reference.libraryScope else { return entry }
            let updated = entry.context.replacingPoster(poster, headers: headers, confirmed: confirmed, confirmedAt: decidedAt)
            guard entry.context != updated else { return entry }
            changed = true
            return PlaybackHistoryEntry(context: updated, position: entry.position, duration: entry.duration, updatedAt: entry.updatedAt)
        }
        if changed { persist(); onChange?() }
    }

    /// Another device's merged history. Removing progress leaves the independent cache and skip preferences intact.
    public func adopt(_ synced: [PlaybackHistoryEntry]) {
        var seen = Set<String>()
        let next = Self.bounded(synced.filter { Self.valid($0) }.sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.id).inserted })
        entries = next
        persist()
    }

    public func remove(_ id: String) { remove(Set([id])) }
    public func remove(_ ids: Set<String>) {
        refreshPendingEntries()
        entries.removeAll { ids.contains($0.id) }; persist(); onChange?()
    }
    public func entries(in scope: String?) -> [PlaybackHistoryEntry] { entries.filter { $0.context.libraryScope == scope } }
    /// Attach old catalog origins to their imported subscription identities once. Progress, dates and
    /// every unmatched record survive the migration, including subscriptions that are disabled.
    public func migrateLegacyScopes(_ scopes: [URL: String]) {
        refreshPendingEntries()
        var changed = false
        entries = entries.map { entry in
            guard entry.context.historyScope == nil,
                  let owner = scopes[entry.context.origin] ?? scopes[PlaybackHistoryContext.sourceIdentity(entry.context.origin)] else { return entry }
            var context = entry.context; context.historyScope = owner; changed = true
            return PlaybackHistoryEntry(context: context, position: entry.position, duration: entry.duration, updatedAt: entry.updatedAt)
        }
        if changed { persist() }
    }
    public func clear(scope: String?) {
        refreshPendingEntries()
        remove(Set(entries(in: scope).map(\.id)))
    }
    public func clear() { entries.removeAll(); persist(); onChange?() }
    private static func bounded(_ values: [PlaybackHistoryEntry]) -> [PlaybackHistoryEntry] {
        var counts: [String: Int] = [:]
        return values.filter { entry in
            let scope = entry.context.libraryScope ?? ""
            counts[scope, default: 0] += 1
            return counts[scope, default: 0] <= limit
        }
    }
    private static func valid(_ entry: PlaybackHistoryEntry) -> Bool {
        !entry.context.sourceKey.isEmpty && !entry.context.videoID.isEmpty &&
        (entry.context.readingProgress?.isValid ?? true) &&
        entry.position.isFinite && entry.position >= 0 && entry.duration.isFinite && entry.duration >= 0 &&
        entry.updatedAt.timeIntervalSince1970.isFinite
    }

    private func persist() {
        persistenceRevision = persistence.enqueue(entries, cache: cache) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.persistenceRevision == result.revision,
                      self.persistence.latestRevision == result.revision else { return }
                self.persistenceError = result.error
            }
        }
        entriesRevision = persistenceRevision
    }

    private func refreshPendingEntries() {
        let revision = persistence.latestRevision
        guard revision != entriesRevision, let latest = persistence.latestEntries else { return }
        entries = latest
        entriesRevision = revision
    }

    /// Close/background/restore callers can await durable latest state without blocking rendering.
    /// Entries change immediately; `persistenceError` is updated when this drain completes.
    @discardableResult public func flushPersistence() async -> Bool {
        while true {
            let result = await persistence.flush()
            // A newer mutation may arrive before the main actor resumes after the drain.
            guard persistence.latestRevision == result.revision else { continue }
            persistenceError = result.error
            return result.error == nil
        }
    }
}
