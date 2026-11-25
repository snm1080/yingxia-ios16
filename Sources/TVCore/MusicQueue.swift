import Foundation
import Perception

/// The songs to play, in order, and where playback is in them: one song from search, or an album
/// or playlist from the chosen track on.
public struct MusicQueue: Codable, Equatable, Sendable {
    public private(set) var tracks: [MusicTrack]
    public private(set) var index: Int
    /// For each shuffled slot, its position in the original list. Optional for older saved queues.
    /// Positions preserve duplicate songs as separate entries without saving a second copy of the tracks.
    private var originalOrder: [Int]?
    /// A mixed music/listening queue shuffles only the contiguous current segment.
    /// Nil keeps the legacy whole-queue behavior for queues from older versions.
    private var shuffledBounds: Range<Int>?
    /// What the queue was started from, such as an album's title; nil for a single song.
    public var source: String?
    /// The album or playlist it plays; song history still records the actual playing track.
    public var collection: MusicCollection?

    public init(tracks: [MusicTrack], start: Int = 0, source: String? = nil, collection: MusicCollection? = nil) {
        self.tracks = tracks
        index = tracks.isEmpty ? 0 : min(max(0, start), tracks.count - 1)
        self.source = source ?? collection?.title
        self.collection = collection
    }

    /// The same tracks in random order, starting with `first` when given.
    public static func shuffled(_ tracks: [MusicTrack], first: MusicTrack? = nil, source: String? = nil, collection: MusicCollection? = nil) -> MusicQueue {
        let start = first.flatMap { tracks.firstIndex(of: $0) } ?? tracks.indices.randomElement() ?? 0
        var queue = MusicQueue(tracks: tracks, start: start, source: source, collection: collection)
        queue.setShuffled(true)
        return queue
    }

    public var current: MusicTrack? { tracks.indices.contains(index) ? tracks[index] : nil }
    public var hasNext: Bool { index + 1 < tracks.count }
    public var hasPrevious: Bool { index > 0 }
    public var isShuffled: Bool { originalOrder != nil }
    public var isShuffledWithinCurrentDomain: Bool {
        originalOrder != nil && (shuffledBounds?.contains(index) ?? true)
    }
    public var repeatingTrackCount: Int { shuffledBounds?.count ?? tracks.count }

    /// Added songs must not drag a book's chapters into the music shuffle pass.
    public mutating func setDomainShuffled(_ enabled: Bool) {
        guard let current else { return }
        if !enabled { setShuffled(false); return }
        let listening = current.source != nil
        let mixed = tracks.contains { ($0.source != nil) != listening }
        if !mixed { setShuffled(true); return }
        if let bounds = shuffledBounds, bounds.contains(index) { return }
        setShuffled(false)
        var lower = index, upper = index + 1
        while lower > 0 && (tracks[lower - 1].source != nil) == listening { lower -= 1 }
        while upper < tracks.count && (tracks[upper].source != nil) == listening { upper += 1 }
        let bounds = lower..<upper
        let segment = [index] + bounds.filter { $0 != index }.shuffled()
        var order = Array(tracks.indices)
        order.replaceSubrange(bounds, with: segment)
        tracks = order.map { tracks[$0] }
        originalOrder = order
        shuffledBounds = bounds
        index = lower
    }

    /// Queue traversal preserves the order that was actually played. Explicit
    /// mode changes still use setDomainShuffled to restore source order.
    public mutating func continueDomainShuffled(_ enabled: Bool) {
        guard let current else { return }
        let listening = current.source != nil
        guard tracks.contains(where: { ($0.source != nil) != listening }) else { setShuffled(enabled); return }
        var lower = index, upper = index + 1
        while lower > 0 && (tracks[lower - 1].source != nil) == listening { lower -= 1 }
        while upper < tracks.count && (tracks[upper].source != nil) == listening { upper += 1 }
        let bounds = lower..<upper
        if let shuffledBounds, shuffledBounds == bounds { return }
        if originalOrder != nil { originalOrder = nil; shuffledBounds = nil }
        guard enabled else { return }
        // Entering at the first item starts a new random segment; going back
        // into a segment keeps its already visited occurrence order intact.
        if index == lower { setDomainShuffled(true) }
        else { originalOrder = Array(tracks.indices); shuffledBounds = bounds }
    }

    /// Mixed-domain edits preserve the current visible order and selected
    /// occurrence, including a random pass that started at the original tail.
    public mutating func preservePlaybackOrder() {
        originalOrder = nil
        shuffledBounds = nil
    }

    /// Changes order without changing the selected entry. A new random pass includes every other song,
    /// even when random playback is enabled on the original list's last song.
    public mutating func setShuffled(_ enabled: Bool) {
        guard enabled != isShuffled, current != nil else { return }
        if enabled {
            let order = [index] + tracks.indices.filter { $0 != index }.shuffled()
            tracks = order.map { tracks[$0] }
            originalOrder = order
            shuffledBounds = nil
            index = 0
        } else if let originalOrder {
            let selected = originalOrder[index]
            tracks = zip(originalOrder, tracks).sorted { $0.0 < $1.0 }.map(\.1)
            index = selected
            self.originalOrder = nil
            shuffledBounds = nil
        }
    }

    /// Begins another random pass, avoiding the just-finished song at the boundary when possible.
    @discardableResult public mutating func restartShuffledPass() -> MusicTrack? {
        guard tracks.count > 1, let current, let originalOrder else { return nil }
        let bounds = shuffledBounds ?? tracks.startIndex..<tracks.endIndex
        guard bounds.contains(index), bounds.count > 1 else { return nil }
        var segment = Array(bounds).shuffled()
        if tracks[segment[0]] == current, let different = segment.firstIndex(where: { tracks[$0] != current }) {
            segment.swapAt(0, different)
        }
        var order = Array(tracks.indices)
        order.replaceSubrange(bounds, with: segment)
        tracks = order.map { tracks[$0] }
        self.originalOrder = order.map { originalOrder[$0] }
        index = bounds.lowerBound
        return self.current
    }

    @discardableResult public mutating func advance() -> MusicTrack? {
        guard hasNext else { return nil }
        index += 1
        return current
    }

    @discardableResult public mutating func back() -> MusicTrack? {
        guard hasPrevious else { return nil }
        index -= 1
        return current
    }

    @discardableResult public mutating func jump(to position: Int) -> MusicTrack? {
        guard tracks.indices.contains(position) else { return nil }
        index = position
        return current
    }

    /// Puts `new` right after the current song.
    public mutating func insertNext(_ new: [MusicTrack]) {
        if let bounds = shuffledBounds, bounds.contains(index) {
            shuffledBounds = bounds.lowerBound..<(bounds.upperBound + new.count)
        }
        if var originalOrder, originalOrder.indices.contains(index) {
            let insertion = originalOrder[index] + 1
            originalOrder = originalOrder.map { $0 >= insertion ? $0 + new.count : $0 }
            originalOrder.insert(contentsOf: insertion..<(insertion + new.count), at: index + 1)
            self.originalOrder = originalOrder
        }
        tracks.insert(contentsOf: new, at: tracks.isEmpty ? 0 : index + 1)
    }

    /// Puts `new` at the end.
    public mutating func append(_ new: [MusicTrack]) {
        if let bounds = shuffledBounds, bounds.upperBound == tracks.count {
            shuffledBounds = bounds.lowerBound..<(bounds.upperBound + new.count)
        }
        originalOrder?.append(contentsOf: tracks.count..<(tracks.count + new.count))
        tracks.append(contentsOf: new)
    }

    /// After a song that would not play, move on, unless several in a row failed: then the
    /// channels are down, and skipping on would only spend requests.
    public static let failuresBeforeStopping = 3
    public func skipsAfterFailure(consecutive failures: Int) -> Bool { hasNext && failures < Self.failuresBeforeStopping }

    /// "Previous" restarts the song once it has played a few seconds, as players do.
    public static let restartThreshold: Double = 3
}

/// Where listening stopped, to continue from: the queue and the second within its current song.
public struct MusicResumePoint: Codable, Equatable, Sendable {
    public var queue: MusicQueue
    public var position: Double
    public var savedAt: Date
    public init(queue: MusicQueue, position: Double, savedAt: Date = Date()) {
        self.queue = queue; self.position = position; self.savedAt = savedAt
    }
}

/// A song played on its own, or an album or playlist played from its page.
public struct MusicHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var track: MusicTrack?
    public var collection: MusicCollection?
    public var playedAt: Date
    public var id: String { collection?.id ?? track?.id ?? "" }
}

/// Songs played recently, newest first, and where to continue: kept in one file.
@MainActor @Perceptible public final class MusicLibrary {
    public static let shared = MusicLibrary(file: MusicLibrary.directory.appending(path: "music-library.json"))
    /// tvOS only keeps app files in Caches, as for subscriptions.
    static var directory: URL {
        #if os(tvOS)
        URL.cachesDirectory
        #else
        URL.applicationSupportDirectory
        #endif
    }
    public static let historyLimit = 20

    public private(set) var history: [MusicHistoryEntry] = []
    public private(set) var resumePoint: MusicResumePoint?
    public private(set) var favoriteCollections: [MusicCollection] = []
    private let file: URL?
    private var saveTask: Task<Void, Never>?

    private struct Saved: Codable {
        var history: [MusicHistoryEntry]
        var resumePoint: MusicResumePoint?
        var favoriteCollections: [MusicCollection]?
    }

    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            // Older files mixed album/playlist visits with songs. Only actual songs belong here.
            var seen: Set<String> = []
            history = Array(saved.history.filter { $0.track != nil && seen.insert($0.id).inserted }.prefix(Self.historyLimit))
            resumePoint = saved.resumePoint
            favoriteCollections = saved.favoriteCollections ?? []
        }
    }

    /// A song started playing on its own: it moves to the top, once.
    public func recordPlay(_ track: MusicTrack, at date: Date = Date()) {
        record(MusicHistoryEntry(track: track, playedAt: date))
    }

    /// Compatibility entry point: opening a collection does not record an actual listen.
    public func recordPlay(_ collection: MusicCollection, at date: Date = Date()) {
        // Kept for older callers. Visiting a collection is not evidence of playing a song.
    }

    public func isFavorite(_ collection: MusicCollection) -> Bool { favoriteCollections.contains { $0.id == collection.id } }

    public func toggleFavorite(_ collection: MusicCollection) {
        if isFavorite(collection) { favoriteCollections.removeAll { $0.id == collection.id } }
        else { favoriteCollections.insert(collection, at: 0) }
        flush()
    }

    private func record(_ entry: MusicHistoryEntry) {
        history.removeAll { $0.id == entry.id }
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        scheduleSave()
    }

    public func remove(_ entry: MusicHistoryEntry) {
        history.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    public func clearHistory() {
        history = []
        scheduleSave()
    }

    public func saveResumePoint(_ point: MusicResumePoint?) {
        guard point != resumePoint else { return }
        resumePoint = point
        scheduleSave()
    }

    /// Writes after a short pause, so frequent position updates save once.
    private func scheduleSave() {
        guard let file, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.saveTask = nil
            self.saveNow(to: file)
        }
    }

    /// For leaving the app, when a delayed write might not happen.
    public func flush() {
        saveTask?.cancel(); saveTask = nil
        if let file { saveNow(to: file) }
    }

    private func saveNow(to file: URL) {
        // Build 37 probe: encoding the whole library runs on the main actor; log a save
        // that overruns 250 ms, with the payload size (category music.perf).
        let signpost = ContinuousClock.now
        guard let data = try? JSONEncoder().encode(Saved(history: history, resumePoint: resumePoint, favoriteCollections: favoriteCollections)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        let elapsed = signpost.duration(to: ContinuousClock.now)
        if elapsed > .milliseconds(250) {
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            Diagnostics.shared.record(.warning, "music.perf", "MusicLibrary.saveNow took \(ms)ms bytes=\(data.count)")
        }
    }
}
