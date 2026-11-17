import Foundation

/// Native TMDB v3 response adapter; matching rules are shared with the built-in service.
enum CustomTMDBService {
    static func object(_ path: String, _ parameters: [String: String] = [:], config: TMDBServiceSettings,
                       session: URLSession, refresh: Bool = false) async throws -> [String: Any] {
        var request = try config.request(path: path, parameters: parameters)
        if refresh {
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        let data = try await config.data(for: request, session: session)
        guard data.count <= 12 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.badServerResponse) }
        return json
    }

    static func item(_ value: [String: Any], kind: TMDBMatch.MediaType? = nil, config: TMDBServiceSettings) -> TMDBCatalog.Item? {
        guard let id = value["id"] as? Int, id > 0 else { return nil }
        let type = kind ?? TMDBMatch.MediaType(rawValue: value["media_type"] as? String ?? "") ?? (value["name"] == nil ? .movie : .tv)
        let name = value["title"] as? String ?? value["name"] as? String ?? ""
        guard !name.isEmpty else { return nil }
        let date = value["release_date"] as? String ?? value["first_air_date"] as? String
        return TMDBCatalog.Item(id: id, mediaType: type, name: name,
            originalName: value["original_title"] as? String ?? value["original_name"] as? String ?? name,
            year: date.flatMap { Int($0.prefix(4)) }, overview: value["overview"] as? String ?? "",
            poster: config.image(value["poster_path"] as? String), backdrop: config.image(value["backdrop_path"] as? String, size: "original"),
            rating: value["vote_average"] as? Double, genreIDs: value["genre_ids"] as? [Int] ?? [], date: date)
    }
    static func rows(_ object: [String: Any], key: String = "results") -> [[String: Any]] { object[key] as? [[String: Any]] ?? [] }
    static func candidate(_ value: TMDBCatalog.Item) -> TMDBMatch.Candidate {
        TMDBMatch.Candidate(mediaType: value.mediaType, id: value.id, name: value.name, originalName: value.originalName,
                            year: value.year, poster: value.poster, overview: value.overview)
    }

    static func page(_ feed: TMDBCatalog.Feed, page: Int, language: String, config: TMDBServiceSettings, session: URLSession, refresh: Bool = false) async throws -> TMDBCatalog.Page {
        var path = "discover/tv", values = ["page": String(max(1, page)), "language": language, "sort_by": "popularity.desc"]
        var kind: TMDBMatch.MediaType? = .tv
        switch feed {
        case .trending, .featured: path = "trending/all/week"; kind = nil
        case .movies: path = "movie/popular"; kind = .movie
        case .television: path = "tv/popular"
        case .onTheAir: path = "tv/on_the_air"
        case .nowPlaying: path = "movie/now_playing"; kind = .movie
        case .upcoming: path = "movie/upcoming"; kind = .movie
        case .topMovies: path = "movie/top_rated"; kind = .movie
        case .topTelevision: path = "tv/top_rated"
        case .animation: values["with_genres"] = "16"
        case .chinese: values["with_original_language"] = "zh"
        case .korean: values["with_original_language"] = "ko"
        case .variety: values["with_genres"] = "10764|10767"
        case .family: path = "discover/movie"; kind = .movie; values["with_genres"] = "10751"
        case .kids: values["with_genres"] = "10762"
        case .netflix: values["with_networks"] = "213"
        case .disney: values["with_networks"] = "2739"
        case .appleTV: values["with_networks"] = "2552"
        case .hbo: values["with_networks"] = "49"
        case .warner: path = "discover/movie"; kind = .movie; values["with_companies"] = "174"
        case .universal: path = "discover/movie"; kind = .movie; values["with_companies"] = "33"
        case .paramount: path = "discover/movie"; kind = .movie; values["with_companies"] = "4"
        case .sony: path = "discover/movie"; kind = .movie; values["with_companies"] = "5"
        }
        let json = try await object(path, values, config: config, session: session, refresh: refresh)
        return TMDBCatalog.Page(items: rows(json).filter { $0["media_type"] as? String != "person" }.compactMap { item($0, kind: kind, config: config) },
                                page: json["page"] as? Int ?? page, totalPages: min(500, json["total_pages"] as? Int ?? 1))
    }

    static func search(_ query: String, language: String, config: TMDBServiceSettings, session: URLSession) async throws -> [TMDBMatch.SearchResult] {
        let json = try await object("search/multi", ["query": query, "language": language, "include_adult": "false"], config: config, session: session)
        return rows(json).filter { $0["media_type"] as? String != "person" }.compactMap { item($0, config: config) }.map {
            TMDBMatch.SearchResult(mediaType: $0.mediaType, id: $0.id, name: $0.name, originalName: $0.originalName,
                                   year: $0.year, poster: $0.poster, backdrop: $0.backdrop, overview: $0.overview, sources: 0)
        }
    }

    static func details(_ type: TMDBMatch.MediaType, id: Int, season: Int?, language: String,
                        config: TMDBServiceSettings, session: URLSession) async throws -> TMDBMatch.Details {
        let json = try await object("\(type.rawValue)/\(id)", ["language": language, "append_to_response": "credits,images,videos,recommendations,external_ids", "include_image_language": "zh,en,null"], config: config, session: session)
        guard let title = item(json, kind: type, config: config) else { throw URLError(.cannotParseResponse) }
        let credits = json["credits"] as? [String: Any] ?? [:]
        func person(_ value: [String: Any]) -> TMDBMatch.Person {
            TMDBMatch.Person(id: value["id"] as? Int, name: value["name"] as? String ?? "", role: value["character"] as? String ?? value["job"] as? String, profile: config.image(value["profile_path"] as? String, size: "w185"))
        }
        let seasons = rows(json, key: "seasons").map { value in
            TMDBMatch.SeasonSummary(number: value["season_number"] as? Int ?? 0, name: value["name"] as? String ?? "", episodeCount: value["episode_count"] as? Int ?? 0,
                                   year: (value["air_date"] as? String).flatMap { Int($0.prefix(4)) }, poster: config.image(value["poster_path"] as? String))
        }
        var chosen: TMDBMatch.Season?
        if type == .tv, let number = season ?? seasons.first(where: { $0.number > 0 })?.number {
            let data = try await object("tv/\(id)/season/\(number)", ["language": language], config: config, session: session)
            chosen = TMDBMatch.Season(number: number, name: data["name"] as? String ?? "", overview: data["overview"] as? String ?? "",
                poster: config.image(data["poster_path"] as? String), year: (data["air_date"] as? String).flatMap { Int($0.prefix(4)) },
                episodes: rows(data, key: "episodes").map { value in
                    TMDBMatch.EpisodeInfo(number: value["episode_number"] as? Int ?? 0, name: value["name"] as? String ?? "", overview: value["overview"] as? String ?? "",
                        still: config.image(value["still_path"] as? String), airDate: value["air_date"] as? String, runtime: (value["runtime"] as? NSNumber)?.doubleValue, rating: value["vote_average"] as? Double)
                })
        }
        let images = json["images"] as? [String: Any] ?? [:]
        let portraits = rows(images, key: "posters").filter { value in
            guard let ratio = (value["aspect_ratio"] as? NSNumber)?.doubleValue else { return true }
            return ratio >= 0.5 && ratio <= 0.85
        }.sorted { left, right in
            let leftClean = left["iso_639_1"] == nil || left["iso_639_1"] is NSNull
            let rightClean = right["iso_639_1"] == nil || right["iso_639_1"] is NSNull
            if leftClean != rightClean { return leftClean }
            return (left["vote_count"] as? Int ?? 0) > (right["vote_count"] as? Int ?? 0)
        }
        let imdb = (json["external_ids"] as? [String: Any])?["imdb_id"] as? String ?? json["imdb_id"] as? String
        let genres = rows(json, key: "genres")
        let next = json["next_episode_to_air"] as? [String: Any]
        let nextEpisode: TMDBMatch.ScheduledEpisode?
        if let next, let season = next["season_number"] as? Int, let number = next["episode_number"] as? Int,
           let date = next["air_date"] as? String, date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            nextEpisode = TMDBMatch.ScheduledEpisode(season: season, number: number, date: date)
        } else { nextEpisode = nil }
        var seenCountries = Set<String>()
        let countries = ((json["origin_country"] as? [String] ?? []) + rows(json, key: "production_countries").compactMap { $0["iso_3166_1"] as? String ?? $0["name"] as? String })
            .filter { seenCountries.insert($0).inserted }
        return TMDBMatch.Details(mediaType: type, id: id, name: title.name, originalName: title.originalName,
            tagline: json["tagline"] as? String ?? "", overview: title.overview, year: title.year, date: title.date,
            genres: genres.compactMap { $0["name"] as? String }, genreItems: genres.compactMap { value in
                guard let id = value["id"] as? Int, let name = value["name"] as? String else { return nil }; return TMDBCatalog.Keyword(id: id, name: name)
            }, runtime: (json["runtime"] as? NSNumber)?.doubleValue ?? (json["episode_run_time"] as? [Double])?.first,
            rating: title.rating, voteCount: json["vote_count"] as? Int ?? 0,
            countries: countries, status: json["status"] as? String,
            poster: title.poster, backdrop: title.backdrop, logo: config.image(rows(images, key: "logos").first?["file_path"] as? String),
            heroPoster: config.image(portraits.first?["file_path"] as? String, size: "w780") ?? title.poster,
            trailer: imdb.flatMap { $0.range(of: "^tt[0-9]{5,12}$", options: .regularExpression) == nil ? nil : TMDBMatch.Trailer(site: "IMDb", key: $0, title: title.name, year: title.year) },
            stills: rows(images, key: "backdrops").compactMap { config.image($0["file_path"] as? String, size: "w780") },
            studios: rows(json, key: "production_companies").map { TMDBMatch.Studio(id: $0["id"] as? Int, kind: "company", name: $0["name"] as? String ?? "", logo: config.image($0["logo_path"] as? String, size: "w185")) },
            cast: rows(credits, key: "cast").map(person), crew: rows(credits, key: "crew").filter { ["Director", "Writer", "Screenplay", "Creator"].contains($0["job"] as? String ?? "") }.map(person),
            networks: rows(json, key: "networks").compactMap { $0["name"] as? String }, seasons: seasons, season: chosen,
            recommendations: rows(json["recommendations"] as? [String: Any] ?? [:]).compactMap { item($0, kind: type, config: config) }.map(candidate),
            link: URL(string: "https://www.themoviedb.org/\(type.rawValue)/\(id)")!,
            originalLanguage: json["original_language"] as? String,
            episodeCount: json["number_of_episodes"] as? Int,
            posters: Array(portraits.compactMap { config.image($0["file_path"] as? String, size: "w780") }.prefix(12)),
            broadcastNetworks: rows(json, key: "networks").map { value in
                TMDBMatch.Studio(id: value["id"] as? Int, kind: "network", name: value["name"] as? String ?? "", logo: config.image(value["logo_path"] as? String, size: "w300"))
            }, nextEpisode: nextEpisode)
    }

    static func lookup(_ request: TMDBMatch.Request, config: TMDBServiceSettings, session: URLSession,
                       progress: @Sendable (TMDBMatch.Step) -> Void) async throws -> TMDBMatch.Answer {
        try await TMDBMatch.resolve(request, progress: progress, search: {
            try await search($0, language: request.language, config: config, session: session)
        }, details: { type, id, season in
            try await details(type, id: id, season: season, language: request.language, config: config, session: session)
        })
    }

    static func catalogSearch(query: String, kind: TMDBCatalog.SearchKind, page: Int, feed: TMDBCatalog.SearchFeed,
                              filter: TMDBCatalog.Filter?, personID: Int?, keywords: Bool, language: String,
                              config: TMDBServiceSettings, session: URLSession) async throws -> TMDBCatalog.SearchPage {
        let mediaKind = filter?.kind ?? kind
        var path: String
        var values = ["language": language, "page": String(max(1, page))]
        if let personID { path = "person/\(personID)/combined_credits" }
        else if keywords { path = "search/keyword"; values["query"] = query }
        else if let filter {
            path = "discover/\(mediaKind.rawValue)"
            values["with_genres"] = filter.genres.sorted().map(String.init).joined(separator: ",")
            values["sort_by"] = filter.sort; values["with_original_language"] = filter.originalLanguage
            values["with_origin_country"] = filter.region; values[mediaKind == .tv ? "with_networks" : "with_companies"] = filter.company
            values["vote_average.gte"] = String(filter.rating); values["vote_count.gte"] = String(filter.votes)
            values["with_runtime.gte"] = filter.minRuntime; values["with_runtime.lte"] = filter.maxRuntime
            values["with_keywords"] = filter.keywords.map { String($0.id) }.joined(separator: ",")
            let date = mediaKind == .tv ? "first_air_date" : "primary_release_date"
            if !filter.from.isEmpty { values[date + ".gte"] = filter.from + "-01-01" }
            if !filter.to.isEmpty { values[date + ".lte"] = filter.to + "-12-31" }
        } else if !query.isEmpty { path = "search/\(mediaKind.rawValue)"; values["query"] = query }
        else if feed == .popular || mediaKind == .person { path = "\(mediaKind.rawValue)/popular" }
        else { path = "trending/\(mediaKind.rawValue)/\(feed.rawValue)" }
        let json = try await object(path, values, config: config, session: session)
        let result = personID == nil ? rows(json) : rows(json, key: "cast") + rows(json, key: "crew")
        var seen = Set<String>()
        let items = mediaKind == .person && personID == nil || keywords ? [] : result.compactMap { item($0, kind: personID == nil ? TMDBMatch.MediaType(rawValue: mediaKind.rawValue) : nil, config: config) }.filter { seen.insert($0.key).inserted }
        let people = mediaKind != .person || personID != nil ? [] : result.compactMap { value -> TMDBCatalog.SearchPerson? in
            guard let id = value["id"] as? Int else { return nil }
            return TMDBCatalog.SearchPerson(id: id, name: value["name"] as? String ?? "", profile: config.image(value["profile_path"] as? String), department: value["known_for_department"] as? String, works: rows(value, key: "known_for").compactMap { item($0, config: config) })
        }
        return TMDBCatalog.SearchPage(items: items, people: people, keywords: keywords ? result.compactMap { value in
            guard let id = value["id"] as? Int, let name = value["name"] as? String else { return nil }; return TMDBCatalog.Keyword(id: id, name: name)
        } : [], page: json["page"] as? Int ?? page, totalPages: min(500, json["total_pages"] as? Int ?? 1))
    }

    static func person(_ id: Int, language: String, config: TMDBServiceSettings, session: URLSession) async throws -> TMDBCatalog.PersonProfile {
        let json = try await object("person/\(id)", ["language": language, "append_to_response": "combined_credits,external_ids"], config: config, session: session)
        let credits = json["combined_credits"] as? [String: Any] ?? [:]
        var seen = Set<String>()
        let works = (rows(credits, key: "cast") + rows(credits, key: "crew")).compactMap { value -> TMDBCatalog.PersonWork? in
            guard let work = item(value, config: config), seen.insert(work.key).inserted else { return nil }
            return TMDBCatalog.PersonWork(item: work, date: work.date, roles: [value["character"] as? String ?? value["job"] as? String ?? ""].filter { !$0.isEmpty }, departments: [value["department"] as? String ?? ""].filter { !$0.isEmpty })
        }
        return TMDBCatalog.PersonProfile(id: id, name: json["name"] as? String ?? "", profile: config.image(json["profile_path"] as? String), biography: json["biography"] as? String ?? "", birthday: json["birthday"] as? String, birthplace: json["place_of_birth"] as? String ?? "", department: json["known_for_department"] as? String ?? "", instagram: (json["external_ids"] as? [String: Any])?["instagram_id"] as? String, works: works)
    }

    static func collections(language: String, config: TMDBServiceSettings, session: URLSession) async throws -> TMDBCatalog.Collections {
        let json = try await object("person/popular", ["language": language], config: config, session: session)
        let people = rows(json).prefix(12).compactMap { value -> TMDBCatalog.Person? in
            guard let id = value["id"] as? Int else { return nil }
            return TMDBCatalog.Person(id: id, name: value["name"] as? String ?? "", profile: config.image(value["profile_path"] as? String), works: rows(value, key: "known_for").compactMap { item($0, config: config) })
        }
        let networks: [(TMDBCatalog.Feed, String)] = [(.netflix, "Netflix"), (.disney, "Disney+"), (.appleTV, "Apple TV+"), (.hbo, "HBO")]
        let companies: [(TMDBCatalog.Feed, String)] = [(.warner, "Warner"), (.universal, "Universal"), (.paramount, "Paramount"), (.sony, "Sony")]
        return TMDBCatalog.Collections(people: people, networks: networks.map { TMDBCatalog.Brand(feed: $0.0, name: $0.1, logo: nil) }, companies: companies.map { TMDBCatalog.Brand(feed: $0.0, name: $0.1, logo: nil) })
    }
}
