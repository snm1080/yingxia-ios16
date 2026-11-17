import Foundation

/// Daily charts also work with the older bundled service and a viewer's own TMDB service.
/// Chart requests carry no TMDB credentials; only the selected TMDB adapter resolves their titles.
enum FeaturedCatalog {
    private static let snapshotKey = "local.discover.featured.v1"
    private struct Snapshot: Codable {
        let identity: String
        let page: TMDBCatalog.Page
        let fetchedAt: Date
    }

    /// One bounded last-successful page survives process restarts. Identity includes
    /// both the selected service and language; credentials never enter this payload.
    static func cachedPage(language: String) -> TMDBCatalog.Page? {
        cachedPage(key: TMDBServiceSettings.identity + "|" + language)
    }

    private static func cachedPage(key: String) -> TMDBCatalog.Page? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey), data.count <= 512 * 1024,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.identity == key,
              !snapshot.page.items.isEmpty, snapshot.page.items.count <= 10,
              snapshot.page.items.contains(where: { $0.poster != nil }) else { return nil }
        var page = snapshot.page
        page.fetchedAt = snapshot.fetchedAt
        return page
    }

    private static func persist(_ page: TMDBCatalog.Page, key: String) {
        guard let fetchedAt = page.fetchedAt, !page.items.isEmpty,
              page.items.contains(where: { $0.poster != nil }),
              let data = try? JSONEncoder().encode(Snapshot(identity: key, page: page, fetchedAt: fetchedAt)),
              data.count <= 512 * 1024 else { return }
        UserDefaults.standard.set(data, forKey: snapshotKey)
    }

    struct Entry: Sendable {
        let title: String
        let originalTitle: String?
        let type: TMDBMatch.MediaType
        let year: Int?
    }
    private struct Cached: Sendable { let page: TMDBCatalog.Page; let expires: Date }
    private actor Cache {
        var entries: [String: Cached] = [:]
        var operations: [String: UUID] = [:]
        func read(_ key: String, allowExpired: Bool = false) -> TMDBCatalog.Page? {
            if entries[key] == nil, let stored = FeaturedCatalog.cachedPage(key: key), let fetchedAt = stored.fetchedAt {
                entries[key] = Cached(page: stored, expires: fetchedAt.addingTimeInterval(900))
            }
            guard let entry = entries[key], allowExpired || entry.expires > Date() else { return nil }
            return entry.page
        }
        func begin(_ key: String) -> UUID {
            let token = UUID(); operations[key] = token; return token
        }
        func finish(_ key: String, token: UUID) {
            if operations[key] == token { operations[key] = nil }
        }
        func save(_ value: TMDBCatalog.Page, key: String, token: UUID) -> TMDBCatalog.Page {
            var page = TMDBCatalog.Page(items: Array(value.items.filter { $0.poster != nil }.prefix(10)), page: value.page, totalPages: value.totalPages)
            // A nonempty remote list can still contain no displayable titles. Keep its
            // predecessor before pruning expired entries, without stamping it as fresh.
            guard !page.items.isEmpty else { return read(key, allowExpired: true) ?? page }
            page.fetchedAt = Date()
            guard operations[key] == token else { return page }
            entries = entries.filter { $0.value.expires > Date() }
            if entries.count >= 8 { entries.removeAll() }
            if !page.items.isEmpty {
                entries[key] = Cached(page: page, expires: Date().addingTimeInterval(900))
                FeaturedCatalog.persist(page, key: key)
            }
            return page
        }
    }
    private static let cache = Cache()

    static func page(language: String, session: URLSession, refresh: Bool = false) async throws -> TMDBCatalog.Page {
        let settings = TMDBServiceSettings.load()
        let key = settings.serviceIdentity + "|" + language
        if !refresh, let kept = await cache.read(key) { return kept }
        let token = await cache.begin(key)
        defer { Task { await cache.finish(key, token: token) } }
        if settings.custom == nil {
            // A fresh in-memory entry already returned above. Once it expires, do not give a
            // URLCache response another lease merely because a new Home model was created.
            if let remote = try? await TMDBCatalog.builtinPage(.featured, page: 1, language: language, session: session, refresh: true), !remote.items.isEmpty {
                try Task.checkCancellation()
                return await cache.save(remote, key: key, token: token)
            }
        }
        try Task.checkCancellation()
        async let imdb = try? imdbEntries(session: session, refresh: true)
        async let movies = try? doubanEntries("movie_hot_gaia", session: session, refresh: true)
        async let series = try? doubanEntries("tv_hot", session: session, refresh: true)
        let lists = await (imdb, movies, series)
        try Task.checkCancellation()
        let douban = interleave(lists.1 ?? [], lists.2 ?? [])
        let entries = language.lowercased().hasPrefix("zh") ? interleave(douban, lists.0 ?? []) : interleave(lists.0 ?? [], douban)
        // Bound search fan-out; keep chart order, independent of the response order.
        var resolved: [Int: TMDBCatalog.Item] = [:]
        await withTaskGroup(of: (Int, TMDBCatalog.Item?).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                group.addTask { (index, try? await resolve(entries[index], language: language, settings: settings, session: session)) }
            }
            while next < min(4, entries.count) { enqueue(next); next += 1 }
            for await (index, item) in group {
                if Task.isCancelled { group.cancelAll(); continue }
                resolved[index] = item
                if next < entries.count { enqueue(next); next += 1 }
            }
        }
        try Task.checkCancellation()
        var seen = Set<String>()
        var items = entries.indices.compactMap { resolved[$0] }.filter { seen.insert($0.key).inserted }
        if items.count < 10 {
            let trending: TMDBCatalog.Page?
            if let custom = settings.custom {
                trending = try? await CustomTMDBService.page(.trending, page: 1, language: language, config: custom, session: session, refresh: true)
            } else {
                trending = try? await TMDBCatalog.builtinPage(.trending, page: 1, language: language, session: session, refresh: true)
            }
            items += (trending?.items ?? []).filter { $0.poster != nil && seen.insert($0.key).inserted }
        }
        try Task.checkCancellation()
        // Keep the last usable same-service page through an outage, without extending its
        // lifetime. A recreated Home can retry immediately when its providers recover.
        if items.isEmpty, let previous = await cache.read(key, allowExpired: true) { return previous }
        let page = TMDBCatalog.Page(items: Array(items.prefix(10)), page: 1, totalPages: 1)
        return await cache.save(page, key: key, token: token)
    }

    private static func read(_ request: URLRequest, session: URLSession, refresh: Bool) async throws -> [String: Any] {
        var request = request
        if refresh {
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2 * 1024 * 1024,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.badServerResponse) }
        return body
    }

    private static func imdbEntries(session: URLSession, refresh: Bool) async throws -> [Entry] {
        var request = URLRequest(url: URL(string: "https://api.graphql.imdb.com/")!, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = ["Content-Type": "application/json", "Origin": "https://www.imdb.com", "Referer": "https://www.imdb.com/", "User-Agent": "Mozilla/5.0"]
        let fields = "edges { node { id titleText { text } originalTitleText { text } releaseYear { year } } }"
        let query = "{ movie: chartTitles(first: 5, chart: {chartType: MOST_POPULAR_MOVIES}) { \(fields) } tv: chartTitles(first: 5, chart: {chartType: MOST_POPULAR_TV_SHOWS}) { \(fields) } }"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let body = try await read(request, session: session, refresh: refresh)
        let data = body["data"] as? [String: Any] ?? [:]
        func list(_ type: TMDBMatch.MediaType) -> [Entry] {
            let edges = (data[type.rawValue] as? [String: Any])?["edges"] as? [[String: Any]] ?? []
            return edges.prefix(5).compactMap { edge in
                guard let node = edge["node"] as? [String: Any], let id = node["id"] as? String,
                      id.range(of: #"^tt[0-9]{5,12}$"#, options: .regularExpression) != nil,
                      let title = (node["titleText"] as? [String: Any])?["text"] as? String, !title.isEmpty else { return nil }
                return Entry(title: title, originalTitle: (node["originalTitleText"] as? [String: Any])?["text"] as? String,
                             type: type, year: (node["releaseYear"] as? [String: Any])?["year"] as? Int)
            }
        }
        return interleave(list(.movie), list(.tv))
    }

    private static func doubanEntries(_ collection: String, session: URLSession, refresh: Bool) async throws -> [Entry] {
        var request = URLRequest(url: URL(string: "https://m.douban.com/rexxar/api/v2/subject_collection/\(collection)/items?start=0&count=5")!, timeoutInterval: 8)
        request.setValue(DoubanCatalog.referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let body = try await read(request, session: session, refresh: refresh)
        return (body["subject_collection_items"] as? [[String: Any]] ?? []).prefix(5).compactMap { row in
            guard let raw = row["type"] as? String, let type = TMDBMatch.MediaType(rawValue: raw),
                  let title = row["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Entry(title: title, originalTitle: nil, type: type, year: (row["year"] as? String).flatMap(Int.init) ?? row["year"] as? Int)
        }
    }

    static func searchTitle(_ entry: Entry) -> String {
        guard entry.type == .tv,
              let range = entry.title.range(of: #"(\s*第[一二三四五六七八九十百零〇\d]+季|(?<=\D)\s*(19|20)\d\d)$"#, options: .regularExpression),
              range.lowerBound > entry.title.startIndex else { return entry.title }
        return String(entry.title[..<range.lowerBound])
    }

    static func match(_ entry: Entry, in results: [TMDBMatch.SearchResult]) -> TMDBMatch.SearchResult? {
        func normalized(_ text: String) -> String {
            let folded = text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return (folded.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? folded).filter { $0.isLetter || $0.isNumber }
        }
        let title = searchTitle(entry), season = title != entry.title
        let names = Set(([title] + [entry.originalTitle].compactMap { $0 }).map(normalized))
        return results.first { result in
            result.mediaType == entry.type && (names.contains(normalized(result.name)) || result.originalName.map { names.contains(normalized($0)) } == true)
                && (season || entry.year == nil || result.year == nil || abs(entry.year! - result.year!) <= 1)
        }
    }

    private static func resolve(_ entry: Entry, language: String, settings: TMDBServiceSettings, session: URLSession) async throws -> TMDBCatalog.Item? {
        try Task.checkCancellation()
        let results: [TMDBMatch.SearchResult]
        if let custom = settings.custom {
            results = try await CustomTMDBService.search(searchTitle(entry), language: language, config: custom, session: session)
        } else {
            results = try await TMDBMatch.builtinSearch(searchTitle(entry), language: language, session: session)
        }
        guard let found = match(entry, in: results), found.poster != nil else { return nil }
        return TMDBCatalog.Item(id: found.id, mediaType: found.mediaType, name: found.name, originalName: found.originalName ?? found.name,
                                year: found.year, overview: found.overview ?? "", poster: found.poster, backdrop: found.backdrop, rating: nil, genreIDs: [])
    }

    private static func interleave<T>(_ first: [T], _ second: [T]) -> [T] {
        var result: [T] = []
        for index in 0..<max(first.count, second.count) {
            if index < first.count { result.append(first[index]) }
            if index < second.count { result.append(second[index]) }
        }
        return result
    }
}

extension TMDBCatalog {
    /// Display-only restoration; opening Home still revalidates both carousel feeds.
    public static func cachedFeatured(language: String = TMDBMatch.language) -> Page? {
        FeaturedCatalog.cachedPage(language: language)
    }
}
