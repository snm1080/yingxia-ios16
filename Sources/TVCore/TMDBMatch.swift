import Foundation

/// The TMDB movie or series behind a source's video, for its detail page: artwork, cast, facts and episode stills.
/// Automatic matching uses MacCat's conservative title/year rules with either service's search/details endpoints.
/// Sent: the video's title, year, remarks, synopsis and episode names, and which source and video it is (the source's
/// key and name from the subscription, the video's ID there), so a TMDB title can list the sources others found it on
/// (`sources`). Never an account, a subscription address or a playback link.
public enum TMDBMatch {
    /// Settings › Look Up on TMDB.
    public static let key = "tmdbLookups"
    public static var enabled: Bool {
        #if os(iOS)
        true
        #else
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
        #endif
    }
    static let endpoint = URL(string: "https://yingxia-tmdb.getmegaportal.com/v1/")!

    static var base: URL {
        return endpoint
    }

    /// TMDB's language for the app's: names, overviews and episode titles come in it where TMDB has them.
    public static var language: String {
        switch L10n.resolvedLanguage() {
        case "zh-Hans": "zh-CN"
        case "zh-Hant": "zh-TW"
        case "ja": "ja-JP"
        default: "en-US"
        }
    }

    public struct Request: Codable, Hashable, Sendable {
        public var title: String
        public var year: String?
        public var remarks: String
        public var synopsis: String
        public var episodes: [String]
        /// The source's category and genre tags.
        public var category: String?
        public var language: String
        public var source: SourceRef?
        public var item: String?

        /// From the details (`video`) and, for what details often leave out, the list's card.
        public init(video: Video, listVideo: Video? = nil, source: SourceRef? = nil, language: String = TMDBMatch.language) {
            title = video.name
            year = video.year ?? listVideo?.year
            remarks = video.remarks.isEmpty ? listVideo?.remarks ?? "" : video.remarks
            synopsis = String(video.synopsis.prefix(600))
            // One line's names: the others repeat them.
            let flag = video.episodes.first?.flag
            episodes = video.episodes.filter { $0.flag == flag }.prefix(400).map { String($0.name.prefix(60)) }
            category = [video.category, listVideo?.category].compactMap { $0 }.first { !$0.isEmpty }.map { String($0.prefix(80)) }
            self.language = language
            self.source = source
            item = source == nil ? nil : (listVideo ?? video).id
            year = TMDBTitleMatching.sourceYear(year, title: title, episodes: video.episodes.map(\.name))
        }
    }

    /// Sources whose videos aren't on TMDB: the built-in Hongguo (short dramas), Bilibili (uploads) and Douyin, and
    /// music sources. Each subscription picks its own keys, so a music source is known by its spider (csp_MusicGuard);
    /// never by its name, which would skip video sources that happen to use such a word.
    public static func skipsSource(key: String, api: String) -> Bool {
        ["builtin.hongguo", "builtin.xifan", "builtin.hema", "builtin.bilibili", "builtin.douyin"].contains(key) || api.localizedCaseInsensitiveContains("music")
    }

    /// Labels a source puts on AI-generated videos and short dramas, which aren't on TMDB: in the category
    /// (AI短剧, 漫剧, 爽文短剧, a tag "AI"), or as words in the title or remarks. Not "AI" alone in a title: AI创世者 is a film.
    private static let unlistedLabels = ["AI生成", "AI制作", "AIGC", "AI短剧", "AI漫剧", "AI电影", "AI动画", "AI动漫"]

    /// The source labels this video as AI-generated or a short drama: the app doesn't look it up at all.
    public static func labeledNotOnTMDB(_ request: Request) -> Bool {
        let category = request.category ?? ""
        if category.contains("漫剧") || category.contains("短剧") { return true }
        // "AI" as a word of its own ("AI短剧", "动作,AI"), not inside another ("Mountain").
        if category.split(whereSeparator: { !($0.isASCII && $0.isLetter) }).contains(where: { $0.uppercased() == "AI" }) { return true }
        let words = (request.title + " " + request.remarks).uppercased()
        return unlistedLabels.contains { words.contains($0) }
    }

    /// A source as subscriptions name it: its key, and its name for showing.
    public struct SourceRef: Codable, Hashable, Sendable {
        public let key: String
        public let name: String
        public init(key: String, name: String) { self.key = key; self.name = name }
    }

    /// A source video that viewers' lookups found for a TMDB work.
    public struct SourceLink: Codable, Hashable, Sendable, Identifiable {
        public let source: String
        public let sourceName: String
        public let item: String
        public let title: String
        public let year: String?
        public let season: Int?
        public let seen: Double
        public var id: String { "\(source)|\(item)" }
    }

    /// A TMDB search result, with how many source videos are known for it.
    public struct SearchResult: Codable, Hashable, Sendable, Identifiable {
        public let mediaType: MediaType
        public let id: Int
        public let name: String
        public let originalName: String?
        public let year: Int?
        public let poster: URL?
        public let backdrop: URL?
        public let overview: String?
        public let sources: Int
        public var key: String { "\(mediaType.rawValue):\(id)" }
    }

    public enum MediaType: String, Codable, Hashable, Sendable { case tv, movie }
    /// How the source counts its episodes: from 1 in each season, or on across seasons (long anime).
    public enum Numbering: String, Codable, Hashable, Sendable { case season, absolute }

    /// What the agent is doing, shown while it works.
    public enum Step: Equatable, Sendable {
        case starting, thinking, waiting, loading
        case searching(String)
        case checking(String?, Int?)
        case season(Int)
    }

    public struct Candidate: Codable, Hashable, Sendable, Identifiable {
        public let mediaType: MediaType
        public let id: Int
        public let name: String
        public let originalName: String?
        public let year: Int?
        public let poster: URL?
        public let overview: String?
        public var key: String { "\(mediaType.rawValue):\(id)" }
    }

    public struct Person: Codable, Hashable, Sendable {
        public let id: Int?
        public let name: String
        public let role: String?
        public let profile: URL?
    }

    public struct SeasonSummary: Codable, Hashable, Sendable {
        public let number: Int
        public let name: String
        public let episodeCount: Int
        public let year: Int?
        public let poster: URL?
    }

    public struct EpisodeInfo: Codable, Hashable, Sendable {
        public let number: Int
        public let name: String
        public let overview: String
        public let still: URL?
        public let airDate: String?
        public let runtime: Double?
        public let rating: Double?
    }

    public struct Season: Codable, Hashable, Sendable {
        public let number: Int
        public let name: String
        public let overview: String
        public let poster: URL?
        public let year: Int?
        public let episodes: [EpisodeInfo]
    }

    public struct Trailer: Codable, Hashable, Sendable {
        public let site: String
        public let key: String
        /// Matching context for public catalogs that have a clip when IMDb does not.
        /// Optional so existing cached/service metadata remains decodable.
        public let title: String?
        public let year: Int?
        public init(site: String, key: String, title: String? = nil, year: Int? = nil) {
            self.site = site; self.key = key; self.title = title; self.year = year
        }
    }

    public struct Studio: Codable, Hashable, Sendable {
        public let id: Int?
        public let kind: String?
        public let name: String
        public let logo: URL?
    }

    public struct ScheduledEpisode: Codable, Hashable, Sendable {
        public let season: Int
        public let number: Int
        public let date: String
    }

    public struct Details: Codable, Hashable, Sendable {
        public let mediaType: MediaType
        public let id: Int
        public let name: String
        public let originalName: String
        public let tagline: String
        public let overview: String
        public let year: Int?
        public let date: String?
        public let genres: [String]
        public let genreItems: [TMDBCatalog.Keyword]?
        public let runtime: Double?
        public let rating: Double?
        public let voteCount: Int
        public let countries: [String]
        public let status: String?
        public let poster: URL?
        public let backdrop: URL?
        public let logo: URL?
        /// Optional for details cached before Discover; prefers a text-free portrait behind the wordmark.
        public let heroPoster: URL?
        public let trailer: Trailer?
        /// Enrich old IMDb-only replies without changing the remote service's schema.
        public var playableTrailer: Trailer? {
            guard trailer != nil || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Trailer(site: trailer?.site ?? "Douban", key: trailer?.key ?? "",
                           title: trailer?.title ?? name, year: trailer?.year ?? year)
        }
        public let stills: [URL]?
        public let studios: [Studio]?
        public let cast: [Person]
        public let crew: [Person]
        public let networks: [String]
        public let seasons: [SeasonSummary]
        public let season: Season?
        /// "You may like": TMDB's recommendations, then similar titles. Absent in details saved before it was added.
        public let recommendations: [Candidate]?
        public let link: URL
        /// Optional so answers saved by older versions and the built-in service remain decodable.
        public let originalLanguage: String?
        public let episodeCount: Int?
        /// Alternative portrait artwork. Old services fall back to heroPoster/poster and stills.
        public let posters: [URL]?
        public let broadcastNetworks: [Studio]?
        public let nextEpisode: ScheduledEpisode?
    }

    public struct Match: Codable, Hashable, Sendable {
        public let mediaType: MediaType
        public let id: Int
        public let season: Int?
        public let numbering: Numbering
        /// TMDB episodes before the source's first one in `season`, when TMDB lists two broadcast seasons as one.
        public let offset: Int?
        public let confidence: Double
        public let unmatched: String
    }

    public enum Status: String, Codable, Sendable { case matched, ambiguous, notFound }

    public struct Answer: Codable, Hashable, Sendable {
        public let status: Status
        public let match: Match?
        public let season: Int?
        public let numbering: Numbering
        public let unmatched: String
        public let candidates: [Candidate]
        public let details: Details?
    }

    /// The lookup failed: unlike `notFound`, this says nothing about the title.
    public struct Failure: LocalizedError, Equatable {
        public let code: String
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Both services use the same deterministic matching policy; ambiguous names stay a viewer choice.
    public static func lookup(_ request: Request, session: URLSession = .shared, progress: @Sendable (Step) -> Void) async throws -> Answer {
        if let custom = TMDBServiceSettings.load().custom {
            return try await CustomTMDBService.lookup(request, config: custom, session: session, progress: progress)
        }
        return try await resolve(request, progress: progress, search: {
            try await builtinSearch($0, language: request.language, session: session)
        }, details: { type, id, season in
            try await builtinDetails(type, id: id, season: season, language: request.language, session: session)
        })
    }

    static func resolve(_ request: Request, progress: @Sendable (Step) -> Void,
                        search: (String) async throws -> [SearchResult],
                        details: (MediaType, Int, Int?) async throws -> Details) async throws -> Answer {
        try Task.checkCancellation()
        let query = TMDBTitleMatching.query(request.title)
        guard !query.isEmpty, !query.lowercased().hasPrefix("http://"), !query.lowercased().hasPrefix("https://") else {
            return Answer(status: .notFound, match: nil, season: nil, numbering: .season, unmatched: "", candidates: [], details: nil)
        }
        progress(.searching(query))
        let results = try await search(query)
        try Task.checkCancellation()
        let seasons = Set(([request.title, request.remarks] + request.episodes).compactMap(TMDBTitleMatching.season))
        let candidates = results.prefix(12).map { Candidate(mediaType: $0.mediaType, id: $0.id, name: $0.name,
            originalName: $0.originalName, year: $0.year, poster: $0.poster, overview: $0.overview) }
        guard let match = TMDBTitleMatching.pick(results, request: request), match.mediaType != .tv || seasons.count <= 1 else {
            return Answer(status: results.isEmpty ? .notFound : .ambiguous, match: nil, season: seasons.count == 1 ? seasons.first : nil,
                          numbering: .season, unmatched: "", candidates: candidates, details: nil)
        }
        progress(.checking(match.name, match.year))
        let value = try await details(match.mediaType, match.id, match.mediaType == .tv ? seasons.first ?? 1 : nil)
        try Task.checkCancellation()
        return Answer(status: .matched, match: Match(mediaType: match.mediaType, id: match.id, season: value.season?.number,
            numbering: .season, offset: nil, confidence: 1, unmatched: ""), season: value.season?.number,
            numbering: .season, unmatched: "", candidates: [], details: value)
    }

    /// One work's details: a candidate the viewer picked.
    public static func details(_ type: MediaType, id: Int, season: Int?, language: String = TMDBMatch.language, session: URLSession = .shared) async throws -> Details {
        if let custom = TMDBServiceSettings.load().custom {
            return try await CustomTMDBService.details(type, id: id, season: season, language: language, config: custom, session: session)
        }
        return try await builtinDetails(type, id: id, season: season, language: language, session: session)
    }

    private static func builtinDetails(_ type: MediaType, id: Int, season: Int?, language: String, session: URLSession) async throws -> Details {
        var parts = URLComponents(url: base.appending(path: "details"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "type", value: type.rawValue), URLQueryItem(name: "id", value: String(id)),
                            URLQueryItem(name: "language", value: language), URLQueryItem(name: "v", value: "4")] + (season.map { [URLQueryItem(name: "season", value: String($0))] } ?? [])
        return try await get(Details.self, parts.url!, session: session)
    }

    /// TMDB's movies and series for a name, best first.
    public static func search(_ query: String, language: String = TMDBMatch.language, session: URLSession = .shared) async throws -> [SearchResult] {
        if let custom = TMDBServiceSettings.load().custom {
            return try await CustomTMDBService.search(query, language: language, config: custom, session: session)
        }
        return try await builtinSearch(query, language: language, session: session)
    }

    static func builtinSearch(_ query: String, language: String, session: URLSession) async throws -> [SearchResult] {
        var parts = URLComponents(url: base.appending(path: "search"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "language", value: language)]
        return try await get([SearchResult].self, parts.url!, session: session)
    }

    /// The source videos viewers' lookups matched to this work, most recent first.
    public static func sources(_ type: MediaType, id: Int, session: URLSession = .shared) async throws -> [SourceLink] {
        // Native TMDB does not expose this app's private source-association database.
        if TMDBServiceSettings.load().custom != nil { return [] }
        var parts = URLComponents(url: base.appending(path: "sources"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "type", value: type.rawValue), URLQueryItem(name: "id", value: String(id))]
        return try await get([SourceLink].self, parts.url!, session: session)
    }

    /// The viewer chose this work for a source video ("Not this title?"), so others see that source for it too.
    public static func link(_ request: Request, to type: MediaType, id: Int, season: Int?, session: URLSession = .shared) async {
        if TMDBServiceSettings.load().custom != nil { return }
        struct Body: Encodable { let request: Request; let mediaType: MediaType; let id: Int; let season: Int? }
        var urlRequest = URLRequest(url: base.appending(path: "link"), timeoutInterval: 20)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try? JSONEncoder().encode(Body(request: request, mediaType: type, id: id, season: season))
        _ = try? await session.data(for: urlRequest)
    }

    private static func get<T: Decodable>(_ type: T.Type, _ url: URL, session: URLSession) async throws -> T {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(code: "http", message: "HTTP \(status)") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct Event: Decodable {
        let type: String
        let step: Step?
        let code: String?
        let message: String?

        enum Keys: String, CodingKey { case type, step, query, name, year, season, code, message }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            type = try container.decode(String.self, forKey: .type)
            code = try container.decodeIfPresent(String.self, forKey: .code)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            switch try container.decodeIfPresent(String.self, forKey: .step) {
            case "search": step = .searching(try container.decodeIfPresent(String.self, forKey: .query) ?? "")
            case "details": step = .checking(try container.decodeIfPresent(String.self, forKey: .name), try container.decodeIfPresent(Int.self, forKey: .year))
            case "season": step = .season(try container.decodeIfPresent(Int.self, forKey: .season) ?? 1)
            case "thinking": step = .thinking
            case "waiting": step = .waiting
            case "loading", "done": step = .loading
            default: step = nil
            }
        }
    }
}

// MARK: Episodes

public extension TMDBMatch.Details {
    /// Align metadata with the source's explicit episode and season numbers. Unnumbered variants,
    /// ranges, extras and other seasons remain unmatched instead of borrowing another episode's still.
    func episodes(for names: [String], numbering: TMDBMatch.Numbering, offset: Int = 0) -> [TMDBMatch.EpisodeInfo?] {
        guard let season, !season.episodes.isEmpty else { return names.map { _ in nil } }
        let byNumber = Dictionary(season.episodes.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        let counts = Dictionary(seasons.map { ($0.number, $0.episodeCount) }, uniquingKeysWith: { first, _ in first })
        return LocalDetailEpisodeNumbers.mappedNumbers(names, season: season.number, seasonCounts: counts,
                                                       absolute: numbering == .absolute, offset: offset).map { number in
            number.flatMap { byNumber[$0] }
        }
    }
}

extension TMDBMatch {
    public static func episodeNumber(_ name: String) -> Int? { LocalDetailEpisodeNumbers.numbers(name).episode }
}

// MARK: Cache

/// Answers on this device by source and video, so a page opened again shows its details at once (a few days, then the
/// Worker is asked again), and the work the viewer chose for a video, kept until they change it.
public actor TMDBMatchStore {
    public static let shared = TMDBMatchStore()
    /// The notification object is the source/video match key whose manual choice changed.
    /// Automatic answer saves are silent, so displaying artwork never creates a reload loop.
    public static let choiceChanged = Notification.Name("TMDBMatchChoiceChanged")

    public enum Choice: Codable, Hashable, Sendable {
        case work(TMDBMatch.MediaType, Int, season: Int?)
        /// "None of these": no TMDB details for this video.
        case none
    }

    struct Entry: Codable {
        let answer: TMDBMatch.Answer
        let saved: Date
        let version: Int?
    }

    private let cacheURL: URL
    private let choicesURL: URL
    private var entries: [String: Entry]?
    private var choices: [String: Choice]?
    private static let limit = 600
    private static let matchingVersion = 2

    init(cacheURL: URL? = nil, choicesURL: URL? = nil) {
        let fileManager = FileManager.default
        self.cacheURL = cacheURL ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "tmdb-matches.json")
        self.choicesURL = choicesURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "tmdb-choices.json")
    }

    public static func key(source: String, video: String) -> String {
        let key = "\(source)|\(video)", identity = TMDBServiceSettings.identity
        return identity == "builtin" ? key : identity + "|" + key
    }

    public func answer(for key: String, now: Date = Date()) -> TMDBMatch.Answer? {
        guard let entry = loadEntries()[key], entry.version == Self.matchingVersion,
              entry.answer.status != .matched || entry.answer.details != nil else { return nil }
        // A match stands a week; "not found" and an open choice are asked again the next day.
        let keep: TimeInterval = entry.answer.status == .matched ? 7 * 86400 : 86400
        return now.timeIntervalSince(entry.saved) < keep ? entry.answer : nil
    }

    public func save(_ answer: TMDBMatch.Answer, for key: String, now: Date = Date()) {
        var entries = loadEntries()
        // Incomplete matches are failed requests, not stable answers for this source video.
        guard answer.status != .matched || answer.details != nil else { return }
        entries[key] = Entry(answer: answer, saved: now, version: Self.matchingVersion)
        if entries.count > Self.limit {
            for old in entries.sorted(by: { $0.value.saved < $1.value.saved }).prefix(entries.count - Self.limit) { entries[old.key] = nil }
        }
        self.entries = entries
        write(entries, to: cacheURL)
    }

    /// A kept match with newer details (a series' new episodes). It keeps when it was saved: the match still expires.
    public func update(_ details: TMDBMatch.Details, for key: String) -> TMDBMatch.Answer? {
        var entries = loadEntries()
        guard let entry = entries[key], entry.answer.status == .matched else { return nil }
        let old = entry.answer
        let answer = TMDBMatch.Answer(status: old.status, match: old.match, season: old.season, numbering: old.numbering,
                                      unmatched: old.unmatched, candidates: old.candidates, details: details)
        entries[key] = Entry(answer: answer, saved: entry.saved, version: entry.version)
        self.entries = entries
        write(entries, to: cacheURL)
        return answer
    }

    public func choice(for key: String) -> Choice? { loadChoices()[key] }

    public func choose(_ choice: Choice?, for key: String) async {
        var choices = loadChoices()
        guard choices[key] != choice else { return }
        choices[key] = choice
        self.choices = choices
        write(choices, to: choicesURL)
        await MainActor.run { NotificationCenter.default.post(name: Self.choiceChanged, object: key) }
    }

    private func loadEntries() -> [String: Entry] {
        if let entries { return entries }
        let value = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = value
        return value
    }

    private func loadChoices() -> [String: Choice] {
        if let choices { return choices }
        let value = (try? Data(contentsOf: choicesURL)).flatMap { try? JSONDecoder().decode([String: Choice].self, from: $0) } ?? [:]
        choices = value
        return value
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
