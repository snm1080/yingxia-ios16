import Foundation
import TVCore

/// Adapts a catalog/Python chapter to the existing native manga reader. Source identity,
/// episode order and the history owner come from the catalog that opened the reader.
@MainActor final class LocalReadingSession: Identifiable {
    let id = UUID()
    let comic: MangaComic
    let chapters: [MangaChapter]
    let chapter: Int
    let page: Int
    let defaultMode: MangaReaderMode
    private let channel: Channel
    private let catalog: PlaybackCatalog?
    private let episodes: [Episode]
    private let images = LocalReadingImages()
    private var media: [Int: ReadingMedia] = [:]
    private var chapterRequests: [Int: Task<ReadingMedia, Error>] = [:]
    private var closed = false
    private weak var store: Store?

    init(channel: Channel, media: ReadingMedia, catalog: PlaybackCatalog?, store: Store) {
        self.channel = channel; self.catalog = catalog; self.store = store
        let context = channel.historyContext
        let flag = context?.episodeFlag ?? channel.group
        let candidates = catalog?.video.episodes.filter { $0.flag == flag } ?? []
        let episodes = candidates.isEmpty ? catalog?.video.episodes ?? [] : candidates
        self.episodes = episodes
        chapter = context.flatMap { context in episodes.firstIndex { $0.id == context.episodeID && $0.flag == context.episodeFlag } } ?? 0
        chapters = episodes.map { MangaChapter(id: $0.id, title: $0.name) }
        let scopedSource = (context?.origin.absoluteString ?? "") + "|" + (context?.sourceKey ?? "catalog")
        comic = MangaComic(id: context?.videoID ?? channel.id, sourceKey: "catalog:" + scopedSource,
                           title: context?.videoName ?? channel.name, subtitle: context?.episodeName ?? "",
                           cover: context?.poster?.absoluteString ?? "")
        let progress = context?.readingProgress ?? store.visibleHistory.first { entry in
            guard let context else { return false }
            return entry.context.historyIdentity == context.historyIdentity
        }?.context.readingProgress
        page = channel.playbackRequestID == nil ? max(0, progress?.page ?? 0) : 0
        let labels = (catalog?.client.site.name ?? "") + " " + (catalog?.video.category ?? "") + " " + flag
        let comic = media.kind == .comic || labels.range(of: "漫画|漫畫|漫|comic|manga|mange", options: [.regularExpression, .caseInsensitive]) != nil
        defaultMode = store.playbackDefaults.string(forKey: "local.reading.mode").flatMap(MangaReaderMode.init(rawValue:))
            ?? (comic ? .vertical : .leftToRight)
        self.media[chapter] = media
    }

    var reading: MangaReading { MangaReading(comic: comic, chapters: chapters, chapter: chapter, page: page) }

    func pages(_ chapter: Int) async throws -> [String] {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let media = media[chapter] {
            if media.images.isEmpty { self.media.removeValue(forKey: chapter) }
            return try addresses(media)
        }
        guard let catalog, episodes.indices.contains(chapter) else { throw TVError.unsupported("未找到这一章节，请重新打开详情。") }
        let task: Task<ReadingMedia, Error>
        if let pending = chapterRequests[chapter] { task = pending }
        else {
            let episode = episodes[chapter]
            task = Task {
                let plan = try await catalog.client.preparePlayback(episode)
                try Task.checkCancellation()
                guard let media = plan.choices.first?.playback?.reading else {
                    throw TVError.unsupported("这一章节没有返回图片，请返回详情选择其它章节。")
                }
                return media
            }
            chapterRequests[chapter] = task
        }
        defer { chapterRequests[chapter] = nil }
        let loaded = try await task.value
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let values = try addresses(loaded)
        media[chapter] = loaded
        return values
    }

    private func addresses(_ media: ReadingMedia) throws -> [String] {
        guard !media.images.isEmpty else { throw TVError.unsupported("源未返回有效图片，请重试或选择其它章节。") }
        return media.images.map(\.url)
    }

    func imageData(chapter: Int, page: Int) async throws -> Data {
        guard !closed, let pages = media[chapter]?.images, pages.indices.contains(page) else { throw CancellationError() }
        return try await images.data(pages[page])
    }

    func record(chapter: Int, page: Int, totalPages: Int) {
        guard !closed, let store, let original = channel.historyContext, totalPages > 0 else { return }
        var context: PlaybackHistoryContext
        if let catalog, episodes.indices.contains(chapter) {
            context = PlaybackHistoryContext(origin: catalog.client.origin, site: catalog.client.site,
                                             video: catalog.video, episode: episodes[chapter])
            context.historyScope = original.historyScope
        } else { context = original }
        context.readingProgress = ReadingHistoryProgress(page: page, totalPages: totalPages)
        store.playbackHistory.record(context, position: 0, duration: 0)
        // URL lists are session metadata; discard distant chapters as the reader does with images.
        for index in media.keys where abs(index - chapter) > 2 { media.removeValue(forKey: index) }
    }

    func setMode(_ mode: MangaReaderMode) { store?.playbackDefaults.set(mode.rawValue, forKey: "local.reading.mode") }

    func close() {
        guard !closed else { return }
        closed = true
        for task in chapterRequests.values { task.cancel() }
        chapterRequests.removeAll(); media.removeAll()
        Task { await images.close() }
    }
}
