import Foundation
import Perception

/// Music search across the catalogs, for songs, albums or playlists. Typing waits 350 ms before
/// searching; each catalog answers on its own, and results show as they arrive, merged and
/// ranked. A newer query cancels the older one, and a late answer never replaces newer results.
@MainActor @Perceptible public final class MusicSearchModel {
    public private(set) var query = ""
    public private(set) var kind: MusicSearchKind = .songs
    /// Narrows what shows, and stays on for the next query until changed (#649).
    public private(set) var filter = MusicSearchFilter()
    /// What shows: the catalogs' answers that pass the filter.
    public private(set) var results: [MusicTrack] = []
    public private(set) var collections: [MusicCollection] = []
    /// Everything the catalogs answered, before the filter.
    private var allResults: [MusicTrack] = [] { didSet { results = allResults.filter(filter.admits) } }
    private var allCollections: [MusicCollection] = [] { didSet { collections = allCollections.filter(filter.admits) } }
    public private(set) var busy = false
    public private(set) var loadingMore = false
    public var canLoadMore: Bool {
        !query.isEmpty && (!nextSongPage.isEmpty || nextCollectionPage.values.contains { !$0.isEmpty })
    }
    /// Why a catalog failed this time, by catalog. One failing catalog is not a failed search.
    public private(set) var failures: [MusicPlatform: MusicProviderError] = [:]
    /// Set once every catalog answered a song search: the one track the query clearly means, if any.
    public private(set) var directHit: MusicTrack?
    private var nothingFound: Bool { allResults.isEmpty && allCollections.isEmpty }
    /// The catalogs found something, and the filter hides all of it.
    public var filteredOut: Bool { !busy && !query.isEmpty && !nothingFound && results.isEmpty && collections.isEmpty }
    /// The search finished and no catalog found anything.
    public var empty: Bool { !busy && !query.isEmpty && nothingFound && failures.count < catalogs.count }
    /// Every catalog failed: the search itself could not run.
    public var failed: Bool { !busy && !query.isEmpty && nothingFound && failures.count == catalogs.count }

    private let catalogs: [any MusicCatalogSource]
    private let health: MusicHealth
    private var task: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?
    private var publicationRevision = 0
    private let resultBuilder = ResultBuilder()
    private var computedDirectHit: MusicTrack?
    private var generation = UUID()
    private var songLists: [MusicPlatform: [MusicTrack]] = [:]
    private var collectionLists: [MusicCollection.Kind: [MusicPlatform: [MusicCollection]]] = [:]
    private var nextSongPage: [MusicPlatform: Int] = [:]
    private var nextCollectionPage: [MusicCollection.Kind: [MusicPlatform: Int]] = [:]
    private var cacheKey: String?
    private struct Cached {
        var songs: [MusicPlatform: [MusicTrack]]
        var collections: [MusicCollection.Kind: [MusicPlatform: [MusicCollection]]]
        var nextSongs: [MusicPlatform: Int]
        var nextCollections: [MusicCollection.Kind: [MusicPlatform: Int]]
        var results: Published
        var created: Date
    }
    private var cache: [String: Cached] = [:]
    static let debounce: Duration = .milliseconds(350)
    static let cacheLifetime: TimeInterval = 10 * 60

    public init(catalogs: [any MusicCatalogSource]? = nil, health: MusicHealth = .shared, kind: MusicSearchKind = .songs) {
        self.catalogs = catalogs ?? Self.defaultCatalogs(health: health)
        self.health = health
        self.kind = kind
    }

    /// Catalogs searched mainly so their channels can play what the others list.
    nonisolated static let supplementary: Set<MusicPlatform> = [.migu, .kuwo]

    /// Migu and Kuwo list many unlabelled versions of a song (concert recordings, re-uploads),
    /// most without a cover, which only repeated the title in the results. A song found only in
    /// them shows when no other result has its title and artists, and once.
    nonisolated static func withoutEchoes(_ tracks: [MusicTrack]) -> [MusicTrack] {
        func key(_ track: MusicTrack) -> String {
            MusicMatching.normalize(track.title) + "|" + track.artists.map(MusicMatching.normalize).sorted().joined(separator: ",")
        }
        let onlySupplementary = { (track: MusicTrack) in track.ids.keys.allSatisfy(supplementary.contains) }
        var seen = Set(tracks.filter { !onlySupplementary($0) }.map(key))
        return tracks.filter { !onlySupplementary($0) || seen.insert(key($0)).inserted }
    }

    public nonisolated static func defaultCatalogs(transport: MusicTransport = URLSessionMusicTransport(), health: MusicHealth = .shared) -> [any MusicCatalogSource] {
        [QQMusicCatalog(transport: transport), NeteaseMusicCatalog(transport: transport, health: health),
         KugouMusicCatalog(transport: transport), MiguMusicCatalog(transport: transport), KuwoMusicCatalog(transport: transport)]
    }

    /// Where to fetch a collection's tracks.
    public func source(for platform: MusicPlatform) -> (any MusicCollectionSource)? {
        catalogs.first { $0.platform == platform } as? any MusicCollectionSource
    }

    /// Searches for `text` after the typing pause; `immediately` skips the pause (Return pressed).
    /// `kind` nil keeps the current kind.
    public func search(_ text: String, kind newKind: MusicSearchKind? = nil, immediately: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = newKind ?? self.kind
        guard trimmed != query || kind != self.kind || immediately || (nothingFound && failures.isEmpty && !busy) else { return }
        task?.cancel(); pageTask?.cancel(); publicationTask?.cancel()
        pageTask = nil; publicationTask = nil; loadingMore = false
        let run = UUID(); generation = run
        let replacesResults = trimmed != query || kind != self.kind
        query = trimmed; self.kind = kind; directHit = nil; computedDirectHit = nil; failures = [:]
        songLists = [:]; collectionLists = [:]; nextSongPage = [:]; nextCollectionPage = [:]; cacheKey = nil
        guard !trimmed.isEmpty else { allResults = []; allCollections = []; busy = false; return }
        let deep = Self.searchesDeep(kind, filter)
        let key = kind.rawValue + "|" + MusicMatching.normalize(trimmed) + "|" + MusicMatching.tags(inQuery: trimmed).map(\.rawValue).sorted().joined()
            + (deep ? "|deep" : "")
        cacheKey = key
        // An artist's songs are a list to choose from, not one song the query means.
        let findsSongs = (kind == .songs || kind == .top) && filter.isEmpty
        if let cached = cache[key], Date().timeIntervalSince(cached.created) < Self.cacheLifetime {
            songLists = cached.songs; collectionLists = cached.collections
            nextSongPage = cached.nextSongs; nextCollectionPage = cached.nextCollections
            allResults = cached.results.songs; allCollections = cached.results.collections
            computedDirectHit = cached.results.directHit; busy = false
            directHit = findsSongs ? computedDirectHit : nil
            return
        }
        // A new query or kind must never leave the old query's playable results on screen.
        // A deeper refresh of the same query can keep its already-filtered answers.
        if replacesResults { allResults = []; allCollections = [] }
        busy = true
        task = Task {
            if !immediately {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled, self.generation == run else { return }
            }
            if let collectionKind = kind.collectionKind {
                await self.searchCollections(trimmed, kind: collectionKind, run: run)
            } else if kind == .top {
                async let songs: Void = self.searchSongs(trimmed, byArtist: false, deep: deep, run: run)
                async let albums: Void = self.searchCollections(trimmed, kind: .album, run: run)
                async let playlists: Void = self.searchCollections(trimmed, kind: .playlist, run: run)
                _ = await (songs, albums, playlists)
            } else {
                await self.searchSongs(trimmed, byArtist: kind == .artists, deep: deep, run: run)
            }
            guard self.generation == run, !Task.isCancelled else { return }
            await self.finishPublishing(run: run)
            guard self.generation == run, !Task.isCancelled else { return }
            self.busy = false
            // With a catalog missing, the clearest result may only look clear: the viewer chooses.
            self.directHit = findsSongs && self.filter.isEmpty && self.failures.isEmpty ? self.computedDirectHit : nil
            self.cacheCurrent()
        }
    }

    public func clear() { search("") }

    /// The bottom sentinel requests one page from each catalog that still has results. A new
    /// query cancels it and invalidates late answers, including when a provider ignores cancellation.
    public func loadMore() async {
        guard !busy, !loadingMore, canLoadMore, !Task.isCancelled else { return }
        let run = generation, text = query, kind = kind
        loadingMore = true; directHit = nil
        let operation = Task {
            if let collectionKind = kind.collectionKind {
                await self.searchCollections(text, kind: collectionKind, run: run, more: true)
            } else if kind == .top {
                async let songs: Void = self.searchSongs(text, byArtist: false, deep: false, run: run, more: true)
                async let albums: Void = self.searchCollections(text, kind: .album, run: run, more: true)
                async let playlists: Void = self.searchCollections(text, kind: .playlist, run: run, more: true)
                _ = await (songs, albums, playlists)
            } else {
                await self.searchSongs(text, byArtist: kind == .artists, deep: false, run: run, more: true)
            }
            guard self.generation == run else { return }
            // A cancelled caller can already have accepted rows and advanced a provider cursor.
            // Finish publishing that snapshot; cancellation only stops pending network work.
            // A new query cancels the publication separately and its generation still wins.
            await self.finishPublishing(run: run)
            guard self.generation == run else { return }
            self.loadingMore = false; self.pageTask = nil
            if !Task.isCancelled { self.cacheCurrent() }
        }
        pageTask = operation
        await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
    }

    private struct Published: Sendable {
        var songs: [MusicTrack]
        var collections: [MusicCollection]
        var directHit: MusicTrack?
    }

    /// One serial background builder per search model. Cancelled queued jobs stop before doing
    /// work; coalescing a burst of replies never launches several CPU-heavy merges concurrently.
    private actor ResultBuilder {
        func prepare(songs: [[MusicTrack]], collections: [[MusicCollection]], query: String, kind: MusicSearchKind) -> Published? {
            guard !Task.isCancelled else { return nil }
            let merged = MusicSearchModel.withoutEchoes(MusicMatching.merge(songs))
            guard !Task.isCancelled else { return nil }
            let ranked = kind == .artists ? MusicMatching.byArtist(merged, query: query) : MusicMatching.rank(merged, query: query)
            guard !Task.isCancelled else { return nil }
            let lists = collections.flatMap { MusicCollections.rank($0, query: query) }
            let hit = kind == .songs || kind == .top ? MusicMatching.directHit(ranked, query: query) : nil
            return Task.isCancelled ? nil : Published(songs: ranked, collections: lists, directHit: hit)
        }
    }

    private func publishResults() {
        publicationRevision += 1
        let revision = publicationRevision, run = generation, text = query, kind = kind
        let songs = MusicPlatform.allCases.compactMap { songLists[$0] }
        let collections = [MusicCollection.Kind.album, .playlist].map { kind in
            MusicPlatform.allCases.flatMap { collectionLists[kind]?[$0] ?? [] }
        }
        publicationTask?.cancel()
        publicationTask = Task {
            // Network replies tend to arrive together; keep incremental display without rebuilding
            // the entire result after every reply in the same short burst.
            try? await Task.sleep(for: .milliseconds(12))
            guard !Task.isCancelled else { return }
            let prepared = await self.resultBuilder.prepare(songs: songs, collections: collections, query: text, kind: kind)
            guard let prepared, !Task.isCancelled, self.generation == run, self.publicationRevision == revision else { return }
            self.allResults = prepared.songs; self.allCollections = prepared.collections
            self.computedDirectHit = prepared.directHit
        }
    }

    private func finishPublishing(run: UUID) async {
        while generation == run {
            let revision = publicationRevision
            await publicationTask?.value
            if publicationRevision == revision { return }
        }
    }

    private func cacheCurrent() {
        guard failures.isEmpty, let cacheKey else { return }
        if cache.count >= 30, let oldest = cache.min(by: { $0.value.created < $1.value.created })?.key { cache[oldest] = nil }
        cache[cacheKey] = Cached(songs: songLists, collections: collectionLists, nextSongs: nextSongPage,
                                nextCollections: nextCollectionPage,
                                results: Published(songs: allResults, collections: allCollections, directHit: computedDirectHit), created: Date())
    }

    /// Shows the answers that pass `newFilter` at once. The first filter on songs also searches again for a
    /// second page from each catalog, since a filter keeps only part of one.
    public func setFilter(_ newFilter: MusicSearchFilter) {
        guard newFilter != filter else { return }
        let wasDeep = Self.searchesDeep(kind, filter)
        directHit = nil
        filter = newFilter
        results = allResults.filter(filter.admits); collections = allCollections.filter(filter.admits)
        if !query.isEmpty, !wasDeep, Self.searchesDeep(kind, filter) { search(query, immediately: true) }
    }

    /// Songs come two pages per catalog for an artist, and while a filter narrows them.
    nonisolated static func searchesDeep(_ kind: MusicSearchKind, _ filter: MusicSearchFilter) -> Bool {
        switch kind {
        case .artists: true
        case .songs, .top: !filter.isEmpty
        case .albums, .playlists: false
        }
    }

    private struct SongAnswer: Sendable { var tracks: [MusicTrack]; var nextPage: Int? }

    private func searchSongs(_ query: String, byArtist: Bool, deep: Bool, run: UUID, more: Bool = false) async {
        await withTaskGroup(of: (MusicPlatform, Result<SongAnswer, MusicProviderError>).self) { group in
            for catalog in catalogs {
                let page = more ? nextSongPage[catalog.platform] : 1
                guard let page else { continue }
                group.addTask {
                    do {
                        let first = try await catalog.search(query, page: page)
                        try Task.checkCancellation()
                        var answer = SongAnswer(tracks: first, nextPage: first.isEmpty || page >= 200 ? nil : page + 1)
                        if deep, !first.isEmpty, let second = try? await catalog.search(query, page: page + 1) {
                            try Task.checkCancellation()
                            let existing = Set(first.map(\.id))
                            let next = second.filter { !existing.contains($0.id) }
                            answer.tracks += next
                            answer.nextPage = next.isEmpty || page + 1 >= 200 ? nil : page + 2
                        }
                        return (catalog.platform, .success(answer))
                    }
                    catch { return (catalog.platform, .failure(MusicProviderError(error))) }
                }
            }
            for await (platform, result) in group {
                guard generation == run else { group.cancelAll(); return }
                guard let answer = await record(platform, result, run: run) else {
                    if generation == run, !Task.isCancelled { nextSongPage[platform] = nil }
                    continue
                }
                guard generation == run else { group.cancelAll(); return }
                var seen = Set((songLists[platform] ?? []).map(\.id))
                let novel = answer.tracks.filter { seen.insert($0.id).inserted }
                songLists[platform, default: []] += novel
                nextSongPage[platform] = novel.isEmpty ? nil : answer.nextPage
                publishResults()
            }
        }
    }

    private func searchCollections(_ query: String, kind: MusicCollection.Kind, run: UUID, more: Bool = false) async {
        await withTaskGroup(of: (MusicPlatform, Result<[MusicCollection], MusicProviderError>).self) { group in
            for catalog in catalogs {
                guard let source = catalog as? any MusicCollectionSource else { continue }
                let page = more ? nextCollectionPage[kind]?[source.platform] : 1
                guard let page else { continue }
                group.addTask {
                    do { return (source.platform, .success(try await source.searchCollections(query, kind: kind, page: page))) }
                    catch { return (source.platform, .failure(MusicProviderError(error))) }
                }
            }
            for await (platform, result) in group {
                guard generation == run else { group.cancelAll(); return }
                guard let found = await record(platform, result, run: run) else {
                    if generation == run, !Task.isCancelled { nextCollectionPage[kind]?[platform] = nil }
                    continue
                }
                guard generation == run else { group.cancelAll(); return }
                let page = more ? nextCollectionPage[kind]?[platform] ?? 1 : 1
                var seen = Set((collectionLists[kind]?[platform] ?? []).map(\.id))
                let novel = found.filter { seen.insert($0.id).inserted }
                collectionLists[kind, default: [:]][platform, default: []] += novel
                nextCollectionPage[kind, default: [:]][platform] = novel.isEmpty || page >= 200 ? nil : page + 1
                publishResults()
            }
        }
    }

    /// Notes a catalog's answer in its health record; the results, or nil after a failure.
    private func record<T>(_ platform: MusicPlatform, _ result: Result<T, MusicProviderError>, run: UUID) async -> T? {
        let key = MusicHealth.key(platform.rawValue, platform, .search)
        switch result {
        case .success(let value):
            await health.record(key, error: nil)
            guard generation == run, !Task.isCancelled else { return nil }
            return value
        case .failure(let error):
            guard error != .cancelled else { return nil }
            await health.record(key, error: error)
            guard generation == run, !Task.isCancelled else { return nil }
            failures[platform] = error
            return nil
        }
    }
}
