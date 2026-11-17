import Foundation

public struct NativeDanmakuAPI: Identifiable, Codable, Sendable, Equatable {
    public var id: String, name: String, url: String
    public var enabled: Bool
    public init(id: String = UUID().uuidString, name: String, url: String, enabled: Bool = true) { self.id = id; self.name = name; self.url = url; self.enabled = enabled }
}
public enum NativeDanmakuAPIStore {
    public static let key = "danmakuApis"
    public static func load(defaults: UserDefaults = .standard) -> [NativeDanmakuAPI] {
        if let data = defaults.data(forKey: key), let list = try? JSONDecoder().decode([NativeDanmakuAPI].self, from: data) { return list }
        // MacCat starts with no custom API. Retain an explicitly configured
        // legacy server, without silently adding a public provider on first run.
        guard let legacy = defaults.string(forKey: "danmakuServer")?.trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty else { return [] }
        return [NativeDanmakuAPI(id: "default", name: "Dandanplay", url: legacy)]
    }
    public static func enabled(defaults: UserDefaults = .standard) -> [NativeDanmakuAPI] { load(defaults: defaults).filter(\.enabled) }
    public static func save(_ list: [NativeDanmakuAPI], defaults: UserDefaults = .standard) throws {
        guard list.count <= 30, Set(list.map(\.id)).count == list.count else { throw TVError.unsupported("弹幕 API 数量过多或标识重复") }
        for api in list {
            guard !api.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, api.name.count <= 80 else { throw TVError.unsupported("请填写弹幕 API 名称") }
            _ = try CatalogDanmakuClient(address: api.url)
        }
        defaults.set(try JSONEncoder().encode(list), forKey: key)
        NotificationCenter.default.post(name: LocalDanmakuPreferences.changed, object: nil)
    }
}
public struct NativeDanmakuCatalogSource: Identifiable, Sendable {
    public let id: String, name: String
    public let address: String?
    public let publicCatalog: Bool
    public let headers: [String: String]
    /// Identifies the subscription bundle, independently of its video sites or a custom API's chosen ID.
    public let subscriptionID: String?
    public let catalogRevision: UUID?
    public var isBuiltin: Bool { subscriptionID != nil }
    public var enabled: Bool
    public init(id: String, name: String, address: String?, publicCatalog: Bool = false, headers: [String: String] = [:], subscriptionID: String? = nil, catalogRevision: UUID? = nil, enabled: Bool = true) {
        self.id = id; self.name = name; self.address = address; self.publicCatalog = publicCatalog; self.headers = headers
        self.subscriptionID = subscriptionID
        self.catalogRevision = catalogRevision
        self.enabled = enabled
    }
}
public struct NativeDanmakuCatalogEpisode: Identifiable, Sendable {
    public let id: String, title: String
    public let url: String?
}
public struct NativeDanmakuCatalogResult: Identifiable, Sendable {
    public let id: String, title: String
    public let source: NativeDanmakuCatalogSource
    public var episodes: [NativeDanmakuCatalogEpisode]
    public let animeID: String?
    public let raw: JSONValue
    private struct Edition: Equatable {
        let title: String, year: String, category: String
    }
    private var decoratedEdition: (edition: Edition, platform: String)? {
        let pattern = #"^(.+?)\((\d{4})\)【([^】]+)】from\s+(\S+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) else { return nil }
        let text = title as NSString
        let name = text.substring(with: match.range(at: 1)), year = text.substring(with: match.range(at: 2))
        let category = text.substring(with: match.range(at: 3)), platform = text.substring(with: match.range(at: 4))
        if source.publicCatalog {
            guard raw.object?["SearchName"]?.string == name, raw.object?["source"]?.string == platform else { return nil }
        }
        let series = category.range(of: #"^(?:电视|国产|大陆|港台|香港|台湾|日本|韩国|欧美|海外|港|台|日|韩|美|泰)剧$"#, options: .regularExpression) != nil
        return (Edition(title: name, year: year, category: series ? "series" : category), platform)
    }
    /// Aggregates list one edition once per platform. These are ordered fallbacks,
    /// while duplicate entries from the same platform still require manual selection.
    public static func automaticCandidates(in results: [Self], context: PlaybackHistoryContext) -> [Self] {
        let matches = results.filter { $0.matchesAutomatically(context) }
        guard matches.count > 1 else { return matches }
        let editions = matches.compactMap(\.decoratedEdition)
        guard editions.count == matches.count, let first = editions.first,
              editions.allSatisfy({ $0.edition == first.edition }),
              Set(editions.map(\.platform)).count == editions.count else { return [] }
        return matches
    }
    /// Public/aggregate catalogs decorate the work name with edition evidence.
    /// Preserve that evidence for automatic matching; manual search keeps title.
    public func matchesAutomatically(_ context: PlaybackHistoryContext) -> Bool {
        var candidate = title
        let pattern = #"^(.+?)\((\d{4})\)【([^】]+)】from\s+(\S+)$"#
        if let expression = try? NSRegularExpression(pattern: pattern),
           let match = expression.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) {
            let text = title as NSString
            candidate = text.substring(with: match.range(at: 1))
            let year = text.substring(with: match.range(at: 2)), category = text.substring(with: match.range(at: 3))
            if source.publicCatalog {
                guard raw.object?["SearchName"]?.string == candidate,
                      raw.object?["source"]?.string == text.substring(with: match.range(at: 4)) else { return false }
            }
            if let wantedYear = context.year.flatMap(Int.init), wantedYear != Int(year) { return false }
            if CatalogDanmakuMatcher.episodeNumber(context.episodeName) != nil,
               category.range(of: "电影|電影|剧场版|劇場版|movie|film", options: [.regularExpression, .caseInsensitive]) != nil { return false }
            let seasons = Set(([LocalDetailEpisodeNumbers.numbers(candidate).season] +
                ["season", "seasonNumber", "season_number", "Season", "SeasonNumber"].map { raw.object?[$0]?.int }).compactMap { $0 })
            let wanted = Set([LocalDetailEpisodeNumbers.numbers(context.videoName).season,
                              LocalDetailEpisodeNumbers.numbers(context.episodeName).season].compactMap { $0 })
            guard seasons.count <= 1, wanted.count <= 1 else { return false }
            if let season = seasons.first, season != (wanted.first ?? 1) { return false }
            if let wanted = wanted.first, wanted > 1, seasons.first != wanted { return false }
        }
        return CatalogDanmakuMatcher.normalized(candidate) == CatalogDanmakuMatcher.normalized(context.videoName)
    }
}

public struct NativeDanmakuCatalog: Sendable {
    public let context: PlaybackHistoryContext?
    public let http: DanmakuHTTP
    private let binding: CatPawDanmaku.Binding?
    public init(context: PlaybackHistoryContext?, http: DanmakuHTTP = .init()) {
        self.context = context; self.http = http
        binding = context.flatMap { CatPawDanmaku.binding(for: $0) }
    }
    private func route(_ path: String, params: [String: String] = [:]) async throws -> [String: JSONValue] {
        try Task.checkCancellation()
        guard let binding else { throw TVError.unsupported("当前来源没有弹幕目录") }
        let result = try await binding.request(["catDanmakuRoute": path, "routeParams": String(data: try JSONEncoder().encode(params), encoding: .utf8)!, "catDanmakuFeed": path.hasSuffix("/comment") ? "1" : ""])
        try Task.checkCancellation()
        return result
    }
    /// Use the bundle's advertised danmaku page, with its currently listening loopback port.
    /// This stays in an in-app browser so the local source is not suspended behind Safari.
    public func configurationWebsite() async -> URL? {
        guard let binding,
              let config = try? await binding.request(["catConfig": "1"]),
              let website = try? await binding.request(["catWebsite": "1"]),
              let address = website["url"]?.string, let base = URL(string: address) else { return nil }
        let video = config["video"]?.object ?? config["data"]?.object?["video"]?.object ?? [:]
        guard let configured = video["danmuSearchUrl"]?.string,
              let url = Self.configurationURL(configured, base: base) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("1", forHTTPHeaderField: "x-yingxia-host")
        guard let data = try? await http.send(request), !Task.isCancelled, binding.isCurrent,
              String(decoding: data.prefix(128 * 1024), as: UTF8.self)
                .range(of: #"<(?:!doctype|html|body)\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return url
    }

    static func configurationURL(_ configured: String, base: URL) -> URL? {
        guard var origin = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        origin.path = "/"; origin.query = nil; origin.fragment = nil
        guard let root = origin.url else { return nil }
        let raw = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "js2p://_WEB_", with: root.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), options: .caseInsensitive)
        guard !raw.isEmpty, let absolute = URL(string: raw, relativeTo: root)?.absoluteURL,
              var value = URLComponents(url: absolute, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(value.scheme?.lowercased() ?? "") else { return nil }
        if ["127.0.0.1", "localhost", "::1"].contains(value.host ?? "") {
            value.host = root.host; value.port = root.port; value.scheme = root.scheme
        }
        guard let url = value.url else { return nil }
        return ConfigCenter.local(url) ?? url
    }
    public static func isEnabled(_ source: NativeDanmakuCatalogSource, defaults: UserDefaults = .standard) -> Bool {
        if source.isBuiltin {
            return LocalDanmakuPreferences.builtinEnabled(defaults: defaults) &&
                (source.catalogRevision == nil || source.catalogRevision == CatPawDanmaku.revision)
        }
        return NativeDanmakuAPIStore.enabled(defaults: defaults).contains {
            $0.id == source.id && $0.url == source.address
        }
    }
    public static func setEnabled(_ enabled: Bool, source: NativeDanmakuCatalogSource, defaults: UserDefaults = .standard) throws {
        if source.isBuiltin {
            defaults.set(enabled, forKey: LocalDanmakuPreferences.builtinKey)
            NotificationCenter.default.post(name: LocalDanmakuPreferences.changed, object: nil)
        } else {
            var apis = NativeDanmakuAPIStore.load(defaults: defaults)
            guard let index = apis.firstIndex(where: { $0.id == source.id }) else { throw TVError.unsupported("弹幕 API 已改变，请刷新来源") }
            apis[index].enabled = enabled
            try NativeDanmakuAPIStore.save(apis, defaults: defaults)
        }
    }
    public func sources(includeDisabled: Bool = false) async -> [NativeDanmakuCatalogSource] {
        var sources = NativeDanmakuAPIStore.load().filter { includeDisabled || $0.enabled }
            .map { NativeDanmakuCatalogSource(id: $0.id, name: $0.name, address: $0.url, enabled: $0.enabled) }
        let builtinEnabled = LocalDanmakuPreferences.builtinEnabled()
        guard includeDisabled || builtinEnabled else { return sources }
        guard let binding, binding.isCurrent else { return sources }
        let config = try? await binding.request(["catConfig": "1"])
        let video = config?["video"]?.object ?? config?["data"]?.object?["video"]?.object ?? [:]
        let identity = Self.subscriptionID(binding.client)
        if let configured = video["danmuSearchUrl"]?.string,
           let website = try? await binding.request(["catWebsite": "1"]),
           let base = website["url"]?.string.flatMap({ URL(string: $0) }),
           let url = Self.configurationURL(configured, base: base),
           url.scheme == base.scheme, url.host == base.host, url.port == base.port,
           ["/danmusearch", "/danmusearch/"].contains(url.path) {
            sources.insert(NativeDanmakuCatalogSource(id: identity, name: "内置", address: nil,
                publicCatalog: true, subscriptionID: identity, catalogRevision: binding.revision, enabled: builtinEnabled), at: 0)
            return sources
        }
        if let setting = try? await route("/website/danmu/setting") {
            if let code = setting["code"], ![0, 200].contains(code.int ?? -1) { return sources }
            if let address = Self.aggregateAddress(setting) {
                sources.insert(NativeDanmakuCatalogSource(id: identity, name: "内置", address: address,
                    headers: ["x-yingxia-host": "1"], subscriptionID: identity, catalogRevision: binding.revision, enabled: builtinEnabled), at: 0)
            }
        }
        return sources
    }
    private static func aggregateAddress(_ setting: [String: JSONValue]) -> String? {
        if let code = setting["code"], ![0, 200].contains(code.int ?? -1) { return nil }
        let values = setting["data"]?.object ?? setting
        let entries = values["urls"]?.array ?? []
        // Disabled/invalid aggregate metadata must not promote one of its child providers.
        let aggregate = entries.first { $0.object?["builtin"] == .bool(true) }
            ?? entries.first { $0.object?["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "内置" }
            ?? entries.first
        guard let aggregate, aggregate.object?["enabled"] != .bool(false),
              let address = (aggregate.object?["address"]?.string ?? aggregate.object?["url"]?.string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              (try? CatalogDanmakuClient(address: address)) != nil else { return nil }
        return address
    }
    /// A catalog choice identifies its subscription. Its listener/address can change while
    /// another subscription plays, so look up the current aggregate before using the choice.
    private func current(_ source: NativeDanmakuCatalogSource) async throws -> NativeDanmakuCatalogSource {
        try Task.checkCancellation()
        try validate(source)
        guard source.isBuiltin, !source.publicCatalog else { return source }
        let setting = try await route("/website/danmu/setting")
        try validate(source)
        guard let address = Self.aggregateAddress(setting) else { throw TVError.unsupported("当前订阅的内置弹幕来源不可用，请刷新来源。") }
        return NativeDanmakuCatalogSource(id: source.id, name: source.name, address: address,
            publicCatalog: source.publicCatalog, headers: source.headers, subscriptionID: source.subscriptionID, catalogRevision: source.catalogRevision, enabled: source.enabled)
    }
    private static func subscriptionID(_ client: CatalogClient) -> String {
        let bundle = (try? client.site.scriptURL(origin: client.origin))?.absoluteString ?? client.site.api
        let scope = [client.origin.absoluteString, bundle].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return "builtin-danmaku:" + PluginChecksum.sha256(Data(scope.utf8))
    }
    private func validate(_ source: NativeDanmakuCatalogSource) throws {
        guard let identity = source.subscriptionID else { return }
        guard let binding, binding.isCurrent,
              source.catalogRevision == nil || source.catalogRevision == binding.revision,
              Self.subscriptionID(binding.client) == identity else { throw CancellationError() }
    }
    public static func hasBuiltin(subscription: Subscription) async -> Bool {
        if LocalDanmakuPreferences.hasBuiltin(subscription.raw) || subscription.sites.contains(where: { LocalDanmakuPreferences.hasBuiltin($0.raw) }) { return true }
        // A CatPaw subscription advertises its comment catalog through its own config.
        // Ask one site per bundle; plain Python/JSON subscriptions require no host startup.
        var checked = Set<String>()
        for site in subscription.sites where site.raw["catPawOpen"] != nil {
            guard let address = try? site.scriptURL(origin: subscription.origin), checked.insert(address.absoluteString).inserted else { continue }
            let client = CatalogClient(site: site, origin: subscription.origin, jarURL: subscription.spiderURL)
            if let config = try? await client.catPawRequest(["catConfig": "1"]), LocalDanmakuPreferences.hasBuiltin(config) { return true }
            if Task.isCancelled { return false }
        }
        return false
    }
    public func search(_ keyword: String, source: NativeDanmakuCatalogSource) async throws -> [NativeDanmakuCatalogResult] {
        let source = try await current(source)
        if source.publicCatalog {
            let result = try await route("/danmusearch/api/search", params: ["keyword": keyword])
            let groups = result["data"]?.object?.values.flatMap { $0.object?["data"]?.array ?? [] } ?? result["data"]?.array ?? []
            return groups.compactMap { anime in
                guard let title = anime.object?["Name"]?.string else { return nil }
                return NativeDanmakuCatalogResult(id: UUID().uuidString, title: title, source: source, episodes: Self.publicEpisodes(anime.object?["Pages"]), animeID: anime.object?["Id"]?.string, raw: anime)
            }
        }
        guard let address = source.address else { return [] }
        let server = try CatalogDanmakuClient(address: address).server
        var routed: JSONValue?
        if source.isBuiltin {
            do { routed = .object(try await route("/website/danmu/search", params: ["source": address, "anime": keyword])) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // A stopped local source must recover through its host; retrying the cached
                // loopback address directly bypasses host reinitialization and repeats failure.
                if Self.isLoopback(address) { throw error }
            }
        }
        try Task.checkCancellation()
        var components = URLComponents(url: server.appendingPathComponent("api/v2/search/episodes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "anime", value: keyword)]
        var request = URLRequest(url: components.url!, timeoutInterval: 22)
        source.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let directData = routed == nil ? try? await http.send(request) : nil
        try Task.checkCancellation()
        try validate(source)
        if let result = routed ?? directData.flatMap({ try? JSONDecoder().decode(JSONValue.self, from: $0) }),
           let animes = result.object?["animes"]?.array ?? result.object?["data"]?.object?["animes"]?.array {
            return animes.compactMap { anime in
                guard let title = anime.object?["animeTitle"]?.string ?? anime.object?["title"]?.string else { return nil }
                let episodes = (anime.object?["episodes"]?.array ?? []).compactMap { value -> NativeDanmakuCatalogEpisode? in
                    guard let id = value.object?["episodeId"]?.string else { return nil }
                    return NativeDanmakuCatalogEpisode(id: id, title: value.object?["episodeTitle"]?.string ?? value.object?["title"]?.string ?? "第 \(id) 集", url: nil)
                }
                guard !episodes.isEmpty else { return nil }
                return NativeDanmakuCatalogResult(id: UUID().uuidString, title: title, source: source, episodes: episodes, animeID: nil, raw: anime)
            }
        }
        let animes = try await CatalogDanmakuClient(address: address, transport: http).search(keyword)
        try validate(source)
        return animes.map { NativeDanmakuCatalogResult(id: UUID().uuidString, title: $0.title, source: source, episodes: [], animeID: $0.id, raw: .null) }
    }
    public func episodes(_ result: NativeDanmakuCatalogResult) async throws -> [NativeDanmakuCatalogEpisode] {
        try Task.checkCancellation()
        try validate(result.source)
        if !result.episodes.isEmpty { return result.episodes }
        let source = try await current(result.source)
        if source.publicCatalog {
            let params = result.animeID.map { ["animeId": $0] } ?? ["anime": result.title]
            return Self.publicEpisodes(try await route("/danmusearch/api/episodes", params: params)["data"])
        }
        guard let address = source.address, let animeID = result.animeID else { return [] }
        // The catalog client validates numeric IDs from the API response.
        let episodes = try await CatalogDanmakuClient(address: address, transport: http).episodes(CatalogDanmakuAnime(id: animeID, title: result.title, type: ""))
            .map { NativeDanmakuCatalogEpisode(id: $0.id, title: $0.title, url: nil) }
        try validate(source)
        return episodes
    }
    public func prepareParameters(_ episode: NativeDanmakuCatalogEpisode, result: NativeDanmakuCatalogResult) async throws -> [String: JSONValue] {
        try validate(result.source)
        if let address = result.source.address, let url = URL(string: address), DandanplayCredentials.isOfficial(url) {
            let values = try await CatalogDanmakuClient(address: address).comments(CatalogDanmakuEpisode(id: episode.id, title: episode.title))
            try validate(result.source)
            let normalized: JSONValue = .array(values.map { .object(["time": .number($0.time), "mode": .number(Double($0.mode.rawValue)), "color": .number(Double($0.color)), "text": .string($0.text)]) })
            return ["text": .string(String(data: try JSONEncoder().encode(normalized), encoding: .utf8)!)]
        }
        let address = try await feed(episode, result: result)
        var headers = result.source.headers
        if result.source.isBuiltin, Self.isLoopback(address), let owner = binding?.owner {
            headers["x-wincat-play-session"] = owner
        }
        return ["url": .string(address), "headers": .object(headers.mapValues(JSONValue.string))]
    }
    public func feed(_ episode: NativeDanmakuCatalogEpisode, result: NativeDanmakuCatalogResult) async throws -> String {
        let source = try await current(result.source)
        if source.publicCatalog {
            _ = try await route("/danmuput", params: ["id": episode.id, "url": episode.url ?? ""])
            guard let context, let binding else { throw TVError.unsupported("来源已改变") }
            let response = try await binding.request(["catDanmaku": "1", "name": context.videoName, "episode": context.episodeName])
            guard let url = response["url"]?.string else { throw TVError.unsupported("来源没有返回弹幕地址") }
            return url
        }
        guard let address = source.address else { throw TVError.invalidURL }
        if source.isBuiltin {
            do {
                let answer = try await route("/website/danmu/comment", params: ["source": address, "episodeId": episode.id])
                if let url = answer["url"]?.string ?? answer["data"]?.object?["url"]?.string { return url }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if Self.isLoopback(address) { throw error }
            }
        }
        let server = try CatalogDanmakuClient(address: address).server
        var components = URLComponents(url: server.appendingPathComponent("api/v2/comment/" + episode.id), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "format", value: "xml"), .init(name: "withRelated", value: "true")]
        return components.url!.absoluteString
    }
    private static func isLoopback(_ address: String) -> Bool {
        guard let url = URL(string: address) else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }
    private static func publicEpisodes(_ value: JSONValue?) -> [NativeDanmakuCatalogEpisode] {
        (value?.array ?? []).compactMap { episode in
            guard let id = episode.object?["Key"]?.string ?? episode.object?["Url"]?.string else { return nil }
            return NativeDanmakuCatalogEpisode(id: id, title: episode.object?["Name"]?.string ?? episode.object?["FileNum"]?.string ?? "未命名分集", url: episode.object?["Url"]?.string)
        }
    }
}
