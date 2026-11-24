import Foundation

public struct Category: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// The source's filters for this category (TVBox `filters`), such as 类型, 地区 or 年份, in its order.
    public let filters: [CategoryFilter]
    public init(id: String, name: String, filters: [CategoryFilter] = []) {
        self.id = id; self.name = name; self.filters = filters
    }
}

/// One of a category's filters: a group of values (TVBox `{key, name, init, value: [{n, v}]}`) of which the chosen one
/// goes to the source's category request in `extend`, under `key`.
public struct CategoryFilter: Identifiable, Hashable, Sendable {
    public struct Option: Hashable, Sendable {
        public let name: String
        public let value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }
    public let key: String
    public let name: String
    public let options: [Option]
    /// The value chosen before the viewer picks one: the source's `init`, else its first option's.
    public let initial: String
    public var id: String { key }

    public init(key: String, name: String, options: [Option], initial: String? = nil) {
        self.key = key; self.name = name; self.options = options
        self.initial = initial ?? options.first?.value ?? ""
    }

    init?(json: [String: JSONValue]) {
        guard let key = json["key"]?.string, !key.isEmpty else { return nil }
        var seen = Set<String>()
        let options = (json["value"]?.array ?? []).compactMap { entry -> Option? in
            guard let fields = entry.object, let value = fields["v"]?.string ?? fields["value"]?.string else { return nil }
            let name = (fields["n"]?.string ?? fields["name"]?.string).map(HTMLText.name) ?? value
            return seen.insert(value).inserted ? Option(name: name.isEmpty ? value : name, value: value) : nil
        }
        guard !options.isEmpty, options.count > 1 || options[0].value != "" else { return nil }
        self.init(key: key, name: json["name"]?.string.map(HTMLText.name) ?? key, options: options, initial: json["init"]?.string)
    }

    /// A home answer's `filters`: an object of category id to filter list, sometimes sent as JSON text.
    static func all(_ value: JSONValue?, categoryID: String? = nil) -> [String: [CategoryFilter]] {
        var value = value
        if let text = value?.string, let data = text.data(using: .utf8) { value = try? JSONDecoder().decode(JSONValue.self, from: data) }
        let values: [String: JSONValue]
        if let categoryID, value?.array != nil || value?.object?["key"] != nil { values = [categoryID: value ?? .null] }
        else { values = value?.object ?? [:] }
        return values.compactMapValues { list in
            let rows: [JSONValue]
            if let array = list.array { rows = array }
            else if let object = list.object {
                if object["key"] != nil { rows = [list] }
                else { rows = object.sorted { $0.key < $1.key }.map { key, value in
                    var fields = value.object ?? [:]
                    fields["key"] = fields["key"] ?? .string(key)
                    if value.array != nil { fields["value"] = value }
                    return .object(fields)
                } }
            } else { rows = [] }
            var seen = Set<String>()
            let filters = rows.compactMap { $0.object.flatMap(CategoryFilter.init(json:)) }.filter { seen.insert($0.key).inserted }
            return filters.isEmpty ? nil : filters
        }
    }

    /// The choices a category opens with: each filter's initial value, as other TVBox clients send them.
    public static func initialChoices(_ filters: [CategoryFilter]) -> [String: String] {
        Dictionary(filters.map { ($0.key, $0.initial) }, uniquingKeysWith: { first, _ in first })
    }
}
public struct Episode: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let address: String
    public let flag: String
    public let videoID: String?
    public init(id: String, name: String, address: String, flag: String, videoID: String? = nil) {
        self.id = id; self.name = name; self.address = address; self.flag = flag; self.videoID = videoID
    }
}
public struct Video: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let poster: URL?
    public let posterHeaders: [String: String]
    public let year: String?
    public let remarks: String
    public let synopsis: String
    public let episodes: [Episode]
    /// The source's category and genre tags (type_name, vod_class, vod_tag), comma-separated; nil when it gave none.
    public let category: String?
    public let area: String?
    public let director: String?
    public let actor: String?
    /// A plugin setting listed among titles (`action`, e.g. FTY's "LoginShow" or "quarkClean"): TVBox runs
    /// `Spider.action` for it instead of opening details, which the plugin can't answer for such an item.
    public let action: String?
    private let folderID: String?
    private let folderChoices: [String: String]?
    public init(id: String, name: String, poster: URL? = nil, posterHeaders: [String: String] = [:], year: String? = nil,
                remarks: String = "", synopsis: String = "", episodes: [Episode] = [], category: String? = nil, action: String? = nil,
                folderCategoryID: String? = nil, folderFilters: [String: String] = [:], area: String? = nil, director: String? = nil, actor: String? = nil) {
        self.id = id; self.name = name; self.poster = poster; self.posterHeaders = posterHeaders
        self.year = year; self.remarks = remarks; self.synopsis = synopsis; self.episodes = episodes; self.category = category
        self.action = action
        self.area = area; self.director = director; self.actor = actor
        self.folderID = folderCategoryID; self.folderChoices = folderFilters.isEmpty ? nil : folderFilters
    }
    /// A folder of a drive source (AList, 小雅 and other cloud-drive spiders tag it `vod_tag: "folder"`). As in
    /// TVBox it opens as a listing of its own (the category request with the folder's id), not as details.
    public var isFolder: Bool { folderID != nil || (category?.lowercased().split(separator: ",").contains("folder") ?? false) }
    public var folderCategoryID: String { folderID ?? id }
    public var folderFilters: [String: String] { folderChoices ?? [:] }
    /// This video with `poster` when it has none of its own. Many sources leave `vod_pic` out of the detail
    /// answer although their list or search answer had it, and history, favorites and Now Playing keep what plays.
    public func keepingPoster(_ poster: URL?, headers: [String: String]? = nil) -> Video {
        guard self.poster == nil, let poster else { return self }
        return Video(id: id, name: name, poster: poster, posterHeaders: headers ?? [:], year: year,
                     remarks: remarks, synopsis: synopsis, episodes: episodes, category: category, action: action,
                     folderCategoryID: folderID, folderFilters: folderFilters, area: area, director: director, actor: actor)
    }
    public init?(json: [String: JSONValue], origin: URL) {
        guard let id = json["vod_id"]?.string ?? json["id"]?.string ?? json["type_id"]?.string, !id.isEmpty else { return nil }
        self.id = id; name = (json["vod_name"]?.string ?? json["name"]?.string ?? json["type_name"]?.string).map(HTMLText.name).flatMap { $0.isEmpty ? nil : $0 } ?? id
        year = json["vod_year"]?.string.flatMap { $0.count == 4 && $0.allSatisfy(\.isNumber) ? $0 : nil }
        let picture = json["vod_pic"] ?? json["pic"]
        let fields = picture?.object
        let address = picture?.string ?? ["url", "normal", "large", "medium"].compactMap { fields?[$0]?.string }.first
        var transportHeaders: [String: String] = [:]
        var endpoint = address
        if let address, let pipe = address.lastIndex(of: "|") {
            var parameters = URLComponents()
            parameters.percentEncodedQuery = String(address[address.index(after: pipe)...])
            transportHeaders = Dictionary((parameters.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, new in new })
            if !transportHeaders.isEmpty { endpoint = String(address[..<pipe]) }
        }
        let artwork = endpoint.flatMap { PosterResource(address: $0, origin: origin) }
        poster = artwork?.url
        var headers = artwork?.headers ?? [:]
        headers.merge(transportHeaders) { _, new in new }
        headers.merge((fields?["headers"] ?? fields?["header"])?.object?.compactMapValues(\.string) ?? [:]) { _, new in new }
        posterHeaders = headers
        remarks = HTMLText.plain(json["vod_remarks"]?.string ?? "")
        synopsis = HTMLText.synopsis(json["vod_content"]?.string ?? "")
        let labels = ["type_name", "vod_class", "vod_tag"].compactMap { json[$0]?.string.map(HTMLText.name) }.filter { !$0.isEmpty }
        category = labels.isEmpty ? nil : labels.joined(separator: ",")
        func metadata(_ key: String) -> String? { json[key]?.string.map(HTMLText.name).flatMap { $0.isEmpty ? nil : $0 } }
        area = metadata("vod_area"); director = metadata("vod_director"); actor = metadata("vod_actor")
        let cate = json["cate"]?.object
        let tag = (json["vod_tag"]?.string ?? json["tag"]?.string ?? json["kind"]?.string ?? "").lowercased()
        let isDirectory = cate != nil || tag == "folder" || json["is_dir"] == .bool(true) || json["extend"]?.object?["type"]?.string == "folder"
        folderID = isDirectory ? (cate != nil ? cate?["id"]?.string ?? id : json["type_id"]?.string ?? id) : nil
        folderChoices = (cate?["filters"] ?? cate?["extend"] ?? json["categoryFilters"])?.object?.compactMapValues(\.string)
        action = json["action"]?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let flags = (json["vod_play_from"]?.string ?? "").components(separatedBy: "$$$")
        var groups: [[Episode]] = []
        for (groupIndex, group) in (json["vod_play_url"]?.string ?? "").components(separatedBy: "$$$").enumerated() {
            let flag = groupIndex < flags.count ? flags[groupIndex] : ""
            var episodes: [Episode] = []
            for (index, item) in group.components(separatedBy: "#").enumerated() where !item.isEmpty {
                let parts = item.split(separator: "$", maxSplits: 1).map(String.init)
                episodes.append(Episode(id: "\(groupIndex)-\(index)", name: parts.count == 2 ? HTMLText.name(parts[0]) : L10n.text("Play"), address: parts.last ?? item, flag: flag, videoID: id))
            }
            groups.append(episodes)
        }
        // Collection APIs often list a web player group (".../share/<id>") before the m3u8 group of the
        // same episodes, so groups of direct media come first and are what playback starts with.
        let playable = groups.map { $0.first.map { CatalogClient.isDirectMedia($0.address) } ?? false }
        self.episodes = groups.indices.sorted { playable[$0] != playable[$1] ? playable[$0] : $0 < $1 }.flatMap { groups[$0] }
    }
}
/// Plugins pass through site HTML, often entity-escaped twice ("&amp;nbsp;"), so decode until stable before stripping tags.
enum HTMLText {
    private static let entity = try! NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});?")
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}", "middot": "\u{00B7}",
    ]

    static func plain(_ html: String) -> String {
        var text = html
        for _ in 0..<3 {
            let decoded = decodeEntities(text)
            if decoded == text { break }
            text = decoded
        }
        return text
            .replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t\u{00A0}\u{3000}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\n\\s*", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A synopsis (`vod_content`): `plain`, minus the lines that hold nothing but a 线路 label ("线路1", "播放线路")
    /// or a quality word ("蓝光", "1080P"), which aggregator pages leave behind as layout. Everything else is the
    /// provider's own text and stays as written, links and promotion included: a plugin's synopsis can carry the
    /// address the app opens (the Wex config center, #360), and a plot can mention 地址 or 弹幕.
    static func synopsis(_ html: String) -> String {
        let text = plain(html)
        return text.split(separator: "\n").filter { line in
            line.count > 12 || layoutLabel.firstMatch(in: String(line), range: NSRange(line.startIndex..., in: line)) == nil
        }.joined(separator: "\n")
    }
    /// A whole line that is only a 线路 label or a quality word. Anchored at both ends, so plot text never matches.
    private static let layoutLabel = try! NSRegularExpression(
        pattern: "^\\s*(?:(?:播放|高清|蓝光|超清|备用|高速)?\\s*线路[一二三四五六七八九十0-9]*[:：]?|超清|高清|蓝光|标清|流畅|4k|1080p|720p|2160p)\\s*$",
        options: [.caseInsensitive])

    /// A title or name: entities decoded ("太阳&amp;月亮" is "太阳&月亮"), spaces tidied, and nothing else touched,
    /// so a name that reads like markup after decoding ("&lt;3") keeps its text.
    static func name(_ text: String) -> String {
        var text = text
        for _ in 0..<3 {
            let decoded = decodeEntities(text)
            if decoded == text { break }
            text = decoded
        }
        return text.replacingOccurrences(of: "[\\s\u{00A0}\u{3000}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let source = text as NSString
        var output = "", cursor = 0
        for match in entity.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let body = source.substring(with: match.range(at: 1))
            let scalar: UInt32? = body.hasPrefix("#x") || body.hasPrefix("#X") ? UInt32(body.dropFirst(2), radix: 16)
                : body.hasPrefix("#") ? UInt32(body.dropFirst()) : nil
            guard let replacement = scalar.flatMap(Unicode.Scalar.init).map({ String(Character($0)) }) ?? named[body.lowercased()]
            else { continue }
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + replacement
            cursor = match.range.location + match.range.length
        }
        return output + source.substring(from: cursor)
    }
}

public struct CatalogPage: Sendable {
    public let categories: [Category]
    public let videos: [Video]
    public let pageCount: Int
    public let filters: [String: [CategoryFilter]]
    public init(json: [String: JSONValue], origin: URL, categoryID: String? = nil) {
        let filters = CategoryFilter.all(json["filters"] ?? json["filter"], categoryID: categoryID)
        self.filters = filters
        categories = (json["class"]?.array ?? []).compactMap {
            guard let v = $0.object, let id = v["type_id"]?.string else { return nil }
            return Category(id: id, name: v["type_name"]?.string.map(HTMLText.name) ?? id, filters: filters[id] ?? [])
        }
        let directories = (json["dirs"]?.array ?? []).compactMap { value -> Video? in
            guard var fields = value.object else { return nil }
            fields["vod_tag"] = .string("folder")
            return Video(json: fields, origin: origin)
        }
        videos = directories + (json["list"]?.array ?? []).compactMap { $0.object.flatMap { Video(json: $0, origin: origin) } }
        pageCount = max(1, json["pagecount"]?.int ?? 1)
    }
}

public struct CatalogClient: Sendable {
    public let site: Site
    public let origin: URL
    public let http: HTTPClient
    public let jarURL: URL?
    /// The subscription's parse services, used when a source hands back a web player page.
    public private(set) var parses: [ParseService] = []
    public private(set) var sniffAds: [String] = []
    public private(set) var sniffRules: [SniffRule] = []
    public private(set) var sniffer: (any WebSniffing)?
    public private(set) var pushInput: String?
    private var pushFlags: [String] = []
    /// Already resolved HTML-home episode results, scoped to that native playback session.
    private var localPlaybackPlans: [String: PlaybackPlan]?
    private var localPlaybackResolver: (@Sendable (Episode) async throws -> PlaybackPlan)?
    /// A merged source runs against its own subscription, whatever `origin` and `jarURL` the caller has.
    public init(site: Site, origin: URL, http: HTTPClient = HTTPClient(), jarURL: URL? = nil) {
        self.site = site; self.origin = site.origin(or: origin); self.http = http; self.jarURL = site.spider(or: jarURL)
    }
    /// Names the source in an error report: its key, its spider or API, and its type.
    public var reportContext: String { "source=\(site.key) api=\(site.api) type=\(site.type)" }
    public func with(parses: [ParseService]) -> CatalogClient {
        var client = self; client.parses = parses; return client
    }
    public func withPushInput(_ input: String, flags: [String] = []) -> CatalogClient {
        var client = self; client.pushInput = input; client.pushFlags = flags; return client
    }
    public func withLocalPlaybackPlans(_ plans: [String: PlaybackPlan], resolver: (@Sendable (Episode) async throws -> PlaybackPlan)? = nil) -> CatalogClient {
        var client = self; client.localPlaybackPlans = plans; client.localPlaybackResolver = resolver; return client
    }
    public func applying(_ subscription: Subscription) -> CatalogClient {
        var client = with(parses: subscription.parseServices)
        client.sniffAds = subscription.sniffAds
        client.sniffRules = subscription.sniffRules
        return client
    }
    public func with(sniffer: any WebSniffing) -> CatalogClient {
        var client = self
        client.sniffer = sniffer
        return client
    }
    public func requestURL(_ params: [String: String]) throws -> URL {
        guard site.native else { throw TVError.unsupported(L10n.text("%@: this source cannot run in this version.", site.compatibility)) }
        let endpoint = try WebAddress.resolve(site.api, relativeTo: origin)
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: true) else { throw TVError.invalidURL }
        var values = params
        if let ext = site.raw["ext"] {
            if let text = ext.string { values["extend"] = text }
            else if let data = try? JSONEncoder().encode(ext) { values["extend"] = String(data: data, encoding: .utf8) }
        }
        parts.queryItems = (parts.queryItems ?? []).filter { values[$0.name] == nil } + values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // A query item keeps `+`, which servers read as a space: escape it in the filters (base64 has `+`).
        parts.percentEncodedQueryItems = parts.percentEncodedQueryItems?.map { item in
            params[item.name] == nil || !["ext", "f"].contains(item.name) ? item
                : URLQueryItem(name: item.name, value: item.value?.replacingOccurrences(of: "+", with: "%2B"))
        }
        guard let url = parts.url else { throw TVError.invalidURL }
        return url
    }
    /// Every answer, or failure, feeds the source's `SourceHealth`.
    private func request(_ params: [String: String]) async throws -> [String: JSONValue] {
        let started = ContinuousClock.now
        do {
            let json = try await perform(params)
            await SourceHealth.shared.record(site, origin: origin, seconds: started.duration(to: .now).seconds, error: nil)
            return json
        } catch {
            if !Task.isCancelled {
                await SourceHealth.shared.record(site, origin: origin, seconds: started.duration(to: .now).seconds, error: error)
            }
            throw error
        }
    }
    private func perform(_ params: [String: String]) async throws -> [String: JSONValue] {
        if site.isCloudFiles { return try await CloudFilesSource.request(site, params: params) }
        // Yingxia's own sources run in-process on every platform, the Mac's included.
        if site.runsInProcess {
            return try await ScriptRuntime.shared.request(site: site, scriptURL: site.scriptURL(origin: origin), params: params, http: http, origin: origin)
        }
        // A bundled lite port runs first, in-process on QuickJS everywhere; when it fails or answers
        // with nothing usable, the source's JAR spider answers instead.
        if let script = site.liteScript, ScriptRuntime.available, await LiteFallback.shared.prefersPort(site.key) {
            let jarReady = !site.isBuiltIn && EmbeddedJarHost.available && (try? site.pluginURL(origin: origin, fallback: jarURL)) != nil
            let reason: String
            do {
                let json = try await ScriptRuntime.shared.request(site: site, scriptURL: script, params: params, http: http, origin: origin)
                guard jarReady, let problem = LiteSites.unusable(json, params: params) else { return json }
                reason = problem
            } catch {
                if !jarReady || error is CancellationError { throw error }
                reason = error.localizedDescription
            }
            await LiteFallback.shared.record(site.key)
            Diagnostics.shared.record(.warning, "lite.fallback", "\(site.key) \(site.api): port failed (\(reason)); using the JAR")
        }
        #if os(macOS)
        if site.runtime == .javascript || site.runtime == .python {
            return try await LocalJarHost.shared.request(site: site, jarURL: site.scriptURL(origin: origin), params: params, http: http, scriptOrigin: origin)
        }
        #else
        #if os(iOS) || os(tvOS)
        if site.raw["catPawOpen"] != nil, site.runtime == .javascript {
            return try await EmbeddedNodeHost.shared.request(site: site, bundleURL: site.scriptURL(origin: origin), params: params, http: http, origin: origin)
        }
        #endif
        if site.runtime == .javascript {
            return try await ScriptRuntime.shared.request(site: site, scriptURL: site.scriptURL(origin: origin), params: params, http: http, origin: origin)
        }
        #if os(iOS) || os(tvOS)
        if site.runtime == .python {
            return try await EmbeddedPythonHost.shared.request(site: site, scriptURL: site.scriptURL(origin: origin), params: params, http: http, origin: origin)
        }
        #endif
        #endif
        if site.runtime == .jar, var plugin = try site.pluginURL(origin: origin, fallback: jarURL) {
            func run(_ archive: URL) async throws -> [String: JSONValue] {
                let progress = PluginPreparation(site: site, origin: origin)
                defer { progress.finish() }
                return try await EmbeddedJarHost.shared.request(site: site, jarURL: archive, params: params, http: http, configurationOrigin: origin, progress: progress)
            }
            // Only sources on the shared spider borrow; a source's own archive keeps its class version.
            let ownArchive = site.raw["jar"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let className = String(site.api.dropFirst("csp_".count))
            let locator = PluginLocator.shared
            if !ownArchive {
                if let known = await locator.known(source: site.key) { plugin = known }
                else if let known = await locator.known(className) { plugin = known }
            }
            do { return try await run(plugin) }
            catch let missing as PluginClassMissing {
                // Another archive in the subscription may define the class this one lacks.
                guard let other = await locator.archive(containing: missing.className, excluding: plugin, http: http) else { throw missing }
                return try await run(other)
            } catch let crashed as PluginIncompatible where !ownArchive {
                // A merged subscription can pair a source's configuration with the wrong version of
                // its spider; another archive's version may be the one the source was written for.
                for other in await locator.alternatives(containing: className, excluding: [plugin], limit: 3, http: http) {
                    if let result = try? await run(other) {
                        await locator.remember(source: site.key, archive: other)
                        return result
                    }
                }
                throw crashed
            }
        }
        let (data, _) = try await http.get(requestURL(params), headers: site.raw["header"]?.object?.compactMapValues(\.string) ?? [:])
        do { return try JSONDecoder().decode([String: JSONValue].self, from: data) }
        catch {
            // Dead or bot-protected sites answer with a web page; say that rather than a decoding error.
            let start = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
            if start.contains("<html") || start.contains("<!doctype") || start.contains("<head") {
                throw TVError.unsupported(L10n.text("The source returned a web page instead of data. It may be offline or blocking apps."))
            }
            throw error
        }
    }
    public func home() async throws -> CatalogPage {
        CatalogPage(json: try await homeJSON(), origin: origin)
    }
    /// The source's home answer. A CMS API (type 1) answers its plain home call like `ac=list`: names and remarks
    /// but no `vod_pic`. As other TVBox clients do, the posters then come from one `ac=detail` call for those ids.
    private func homeJSON() async throws -> [String: JSONValue] {
        let json = try await request(site.type == 4 ? ["filter": "true"] : [:])
        guard site.type == 1, let list = json["list"]?.array else { return json }
        let ids = Self.idsMissingPosters(list)
        guard !ids.isEmpty else { return json }
        let details: [String: JSONValue]
        do { details = try await request(["ac": "detail", "ids": ids.joined(separator: ",")]) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Diagnostics.shared.record(.warning, "catalog", "\(reportContext) home posters: \(error.localizedDescription)")
            return json
        }
        var result = json
        result["list"] = .array(Self.fillingPosters(list, from: details["list"]?.array ?? []))
        return result
    }
    static func idsMissingPosters(_ list: [JSONValue]) -> [String] {
        list.compactMap { entry in
            guard let fields = entry.object, (fields["vod_pic"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return fields["vod_id"]?.string
        }
    }
    /// `list` with each entry's missing `vod_pic` taken from the detail entry with the same `vod_id`.
    static func fillingPosters(_ list: [JSONValue], from details: [JSONValue]) -> [JSONValue] {
        var posters: [String: JSONValue] = [:]
        for entry in details {
            guard let fields = entry.object, let id = fields["vod_id"]?.string,
                  let pic = fields["vod_pic"], !(pic.string ?? "").isEmpty else { continue }
            posters[id] = pic
        }
        return list.map { entry in
            guard var fields = entry.object, (fields["vod_pic"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                  let id = fields["vod_id"]?.string, let pic = posters[id] else { return entry }
            fields["vod_pic"] = pic
            return .object(fields)
        }
    }
    public func recommendations() async throws -> [Recommendation] { try await recommendationPage().items }
    /// The home answer as recommendations plus the source's categories, from one plugin call.
    public func recommendationPage() async throws -> (items: [Recommendation], categories: [Category]) {
        let json = try await homeJSON()
        var seen = Set<String>()
        let items = (json["list"]?.array ?? []).compactMap { entry in
            entry.object.flatMap { Recommendation(json: $0, origin: origin, isIndex: (site.raw["indexs"]?.int ?? 0) == 1) }
        }.filter { seen.insert($0.id).inserted }
        return (items, CatalogPage(json: json, origin: origin).categories)
    }
    /// A search (`query`) or one page of a category, narrowed by the category's filter `choices` (key to value).
    public func list(category: String?, query: String, page: Int, filters choices: [String: String] = [:]) async throws -> CatalogPage {
        var params = ["pg": String(page)]
        if !query.isEmpty { params["wd"] = query; params["quick"] = "false" }
        else {
            params["ac"] = "detail"; params["t"] = category
            params.merge(Self.filterParameters(choices, siteType: site.type)) { _, new in new }
        }
        return CatalogPage(json: try await request(params), origin: origin, categoryID: category)
    }

    /// A category's filter choices as the source reads them, leaving out empty ("全部") values: as other TVBox clients
    /// send them, base64 JSON in `ext` for an HTTP spider (type 4) and JSON in `f` for a CMS API; a plugin host gets the
    /// JSON in `filters` and hands the spider its `extend` map.
    static func filterParameters(_ choices: [String: String], siteType: Int) -> [String: String] {
        let extend = choices.filter { !$0.value.isEmpty }
        guard !extend.isEmpty, let data = try? JSONSerialization.data(withJSONObject: extend, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return [:] }
        switch siteType {
        case 4: return ["ext": data.base64EncodedString()]
        case 0, 1: return ["f": String(decoding: data, as: UTF8.self)]
        default: return ["filters": String(decoding: data, as: UTF8.self)]
        }
    }
    /// A missing optional support endpoint permits the real detail lookup. An explicit false stops it.
    public func pushSupport(_ input: String) async throws -> Bool? {
        // Script/Python spiders have no support operation; sending an unknown method would request their home.
        guard site.isCatPawOpen || site.native else { return nil }
        do { return MediaPush.supported(.object(try await request(["pushSupport": input]))) }
        catch TVError.http(let status) where status == 404 || status == 405 { return nil }
        catch TVError.unsupported(let message) where message.contains("HTTP 404") || message.contains("HTTP 405") { return nil }
    }
    /// Push cloud parsers can briefly return an empty list while their file lookup continues.
    public func pushDetail(_ input: String) async throws -> Video {
        let json: [String: JSONValue]
        do { json = try await request(["ac": "detail", "ids": input]) }
        catch TVError.http(let status) where [400, 404, 405].contains(status) {
            return pushOnlyDetail(input)
        } catch TVError.unsupported(let message) where [400, 404, 405].contains(where: { message.contains("HTTP \($0)") }) {
            return pushOnlyDetail(input)
        }
        if let message = ["error", "errMsg", "message"].compactMap({ json[$0]?.string }).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw TVError.unsupported(message)
        }
        var result = json
        if let list = json["list"]?.array {
            result["list"] = .array(list.map { item in
                guard var fields = item.object else { return item }
                if fields["vod_id"] == nil { fields["vod_id"] = .string(input) }
                return .object(fields)
            })
        }
        if let video = CatalogPage(json: result, origin: origin).videos.first {
            // Preserve original group/index IDs while removing error rows whose '$' has no provider file ID.
            let fields = result["list"]?.array?.first?.object ?? [:]
            var invalid = Set<String>(), reasons: [String] = []
            for (group, text) in (fields["vod_play_url"]?.string ?? "").components(separatedBy: "$$$").enumerated() {
                for (index, row) in text.components(separatedBy: "#").enumerated() {
                    let parts = row.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
                    if parts.count == 2, parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        invalid.insert("\(group)-\(index)")
                        if !parts[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append(String(parts[0])) }
                    }
                }
            }
            let episodes = video.episodes.filter { !invalid.contains($0.id) }
            if episodes.isEmpty, let reason = reasons.first { throw TVError.unsupported(reason) }
            if episodes.isEmpty, !video.isFolder { return pushOnlyDetail(input, listing: video) }
            return Video(id: video.id, name: video.name, poster: video.poster, posterHeaders: video.posterHeaders,
                         year: video.year, remarks: video.remarks, synopsis: video.synopsis, episodes: episodes,
                         category: video.category, action: video.action, folderCategoryID: video.isFolder ? video.folderCategoryID : nil, folderFilters: video.folderFilters,
                         area: video.area, director: video.director, actor: video.actor)
        }
        return pushOnlyDetail(input)
    }
    /// This episode still runs this source's play resolver; it is never a resolved media channel.
    private func pushOnlyDetail(_ input: String, listing: Video? = nil) -> Video {
        let id = listing?.id ?? input
        return Video(id: id, name: listing?.name ?? input, poster: listing?.poster, posterHeaders: listing?.posterHeaders ?? [:],
                     year: listing?.year, remarks: listing?.remarks ?? "", synopsis: listing?.synopsis ?? "",
                     episodes: [.init(id: "push-" + String(PluginChecksum.sha256(Data(input.utf8)).prefix(24)), name: "播放", address: input, flag: "push", videoID: id)],
                     area: listing?.area, director: listing?.director, actor: listing?.actor)
    }
    public func detail(_ id: String, cached: Bool = false) async throws -> Video {
        if let pushInput { return try await pushDetail(pushInput) }
        if LocalMediaLibrary.isLocalSource(site.key) {
            guard let video = LocalMediaLibrary.shared.video(sourceKey: site.key, id: id) else { throw TVError.unsupported("本地媒体记录不存在，请重新打开媒体") }
            return video
        }
        let scope = EpisodeSkipSettings.scope(origin: origin, source: site.sourceKey, video: id)
        if cached, let data = MediaCache.shared.data(for: "detail", kind: .catalog, scope: scope),
           let video = try? JSONDecoder().decode(Video.self, from: data), video.id == id { return video }
        var json = try await request(["ac": "detail", "ids": id])
        if let list = json["list"]?.array {
            json["list"] = .array(list.map { item in
                guard var fields = item.object else { return item }
                if fields["vod_id"] == nil { fields["vod_id"] = .string(id) }
                return .object(fields)
            })
        }
        let result = CatalogPage(json: json, origin: origin)
        guard let video = result.videos.first else { throw TVError.unsupported(L10n.text("The API did not return video details.")) }
        return video
    }
    /// Runs a listed plugin setting (`Video.action`) with the source's JAR spider, as TVBox does with
    /// `Spider.action`: what the plugin then shows (its own window, its toasts, the pages it opens).
    public func runAction(_ action: String) async throws -> PluginScreen {
        guard site.type == 3, site.runtime == .jar else { throw TVError.unsupported(L10n.text("This plugin setting only works in Android TVBox.")) }
        // Settings are not browsing: they stay out of the source's health (`request`).
        let result = try await perform(["spiderAction": action])
        if let failure = result["errMsg"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !failure.isEmpty {
            throw TVError.unsupported(failure)
        }
        return PluginScreen(json: result)
    }
    /// Sends the viewer's input to the plugin window a setting opened, and returns what it shows then.
    public func pluginWindow(_ event: PluginEvent) async throws -> PluginScreen {
        PluginScreen(json: try await perform(["spiderUI": event.json]))
    }
    public func playback(_ episode: Episode) async throws -> Channel {
        let plan = try await preparePlayback(episode)
        return try await resolvePlayback(plan, choice: plan.choices[0])
    }

    static func playbackClick(site: Site, result: [String: JSONValue]?) -> String {
        let siteClick = site.raw["click"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !siteClick.isEmpty { return siteClick }
        return result?["click"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func preparePlayback(_ episode: Episode, forDownload: Bool = false) async throws -> PlaybackPlan {
        let owner = forDownload ? nil : CatPawDanmaku.reserve(self, episode: episode)
        do {
            let plan = try await preparePlayback(episode, forDownload: forDownload, danmakuOwner: owner)
            try Task.checkCancellation()
            guard let owner else { return plan }
            let choices = try plan.choices.map { choice -> PlaybackChoice in
                var choice = choice
                var descriptor = choice.playback ?? PlaybackDescriptor()
                var request = descriptor.requestJSON.flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8)) } ?? [:]
                request["catDanmakuOwner"] = .string(owner)
                descriptor.requestJSON = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
                choice.playback = descriptor
                return choice
            }
            return PlaybackPlan(choices: choices, headers: plan.headers, group: plan.group,
                                requiresWebDetection: plan.requiresWebDetection, click: plan.click,
                                webPlayURL: plan.webPlayURL, subtitles: plan.subtitles)
        } catch {
            if let owner { CatPawDanmaku.discardPrepared(owner) }
            throw error
        }
    }

    private func preparePlayback(_ episode: Episode, forDownload: Bool, danmakuOwner: String?) async throws -> PlaybackPlan {
        if let plans = localPlaybackPlans {
            let plan: PlaybackPlan
            if let resolved = plans[episode.id] { plan = resolved }
            else if let localPlaybackResolver { plan = try await localPlaybackResolver(episode); try Task.checkCancellation() }
            else { throw TVError.unsupported("此集需要首页解析，请返回首页重新选择。") }
            guard !plan.choices.isEmpty else { throw TVError.unsupported("首页解析未返回可播放资源") }
            if forDownload, plan.choices.contains(where: { $0.playback?.reading != nil }) {
                throw TVError.unsupported("图集和漫画请在阅读器中打开，不能作为视频下载。")
            }
            return plan
        }
        var headers = site.raw["header"]?.object?.compactMapValues(\.string) ?? [:]
        if site.type == 4 || site.type == 3 {
            if !forDownload { CatPawDanmaku.remember(self) }
            var params = ["play": episode.address, "flag": episode.flag]
            if let danmakuOwner { params["catDanmakuOwner"] = danmakuOwner; params["catDanmakuPending"] = "1" }
            if forDownload { params["catPlayback"] = "false" }
            if site.type == 3 { params["detailID"] = episode.videoID }
            if let pushInput {
                params["url"] = pushInput; params["link"] = pushInput
                // Send the same work identity the app will use for matching before
                // the bundle's delayed getPlayInfo request, instead of the raw share URL.
                if !forDownload, let videoID = episode.videoID,
                   let saved = PushMediaLibrary.shared.record(origin: origin, sourceKey: site.sourceKey, videoID: videoID),
                   let title = saved.title, !title.isEmpty {
                    params["danmakuTitle"] = MediaDanmakuIdentity.title(title)
                    params["danmakuEpisode"] = MediaDanmakuIdentity.episode(episode.name)
                }
                params["flags"] = String(decoding: try JSONEncoder().encode(pushFlags.isEmpty ? ["push"] : pushFlags), as: UTF8.self)
            }
            let rawResult = try await request(params)
            let result = PlaybackNormalization.payload(rawResult)
            // Python and other catalog sources return ordered image protocols and image arrays.
            // Inspect the original envelope before the video normalizer flattens its headers or URLs.
            if let reading = ReadingMedia.normalize(.object(rawResult),
                baseURL: (try? WebAddress.resolve(episode.address)) ?? URL(string: site.api, relativeTo: origin)?.absoluteURL ?? origin, headers: headers) {
                if reading.images.isEmpty, let message = Self.providerError(result) { throw TVError.unsupported(message) }
                if forDownload { throw TVError.unsupported("图集和漫画请在阅读器中打开，不能作为视频下载。") }
                return reading.playbackPlan(name: episode.name, group: episode.flag)
            }
            if let message = Self.providerError(result) { throw TVError.unsupported(message) }
            if let fields = result["header"]?.object { headers.merge(fields.compactMapValues(\.string)) { _, new in new } }
            else if let text = result["header"]?.string, let data = text.data(using: .utf8),
                    let fields = try? JSONDecoder().decode([String: String].self, from: data) { headers.merge(fields) { _, new in new } }
            if let ua = result["UA"]?.string ?? result["ua"]?.string, !ua.isEmpty { headers["User-Agent"] = ua }
            let prefix = result["playUrl"]?.string ?? ""
            let click = Self.playbackClick(site: site, result: result)
            if prefix.hasPrefix("json:") || prefix.hasPrefix("parse:") {
                let choices = PlaybackChoice.parse(result["url"], prefix: "", fallbackName: episode.name)
                guard !choices.isEmpty else { throw TVError.unsupported(L10n.text("The API did not return a single playback URL.")) }
                return PlaybackPlan(choices: choices, headers: headers, group: episode.flag, requiresWebDetection: true, click: click, webPlayURL: prefix)
            }
            var choices = PlaybackChoice.parse(result["url"], prefix: prefix, fallbackName: episode.name)
            // The portable desktop normalizer accepts wrapped answers, one-element arrays,
            // quality objects and separate companion audio, preserving opaque signed URLs.
            let requestValue: [String: JSONValue] = ["sourceId": .string(origin.absoluteString), "siteKey": .string(site.sourceKey),
                "vodId": episode.videoID.map(JSONValue.string) ?? .null, "id": .string(episode.address), "flag": .string(episode.flag),
                "siteAPI": .string(site.raw["catPawOpen"]?.string ?? site.api),
                "isLive": .bool(PlaybackSourceContext.isLive(route: site.raw["catPawOpen"]?.string ?? site.api,
                    fields: site.raw, group: episode.flag))]
            if prefix.isEmpty {
                choices = try await PlaybackNormalization.choices(result: rawResult, request: requestValue, headers: headers,
                    baseURL: URL(string: site.api, relativeTo: origin)?.absoluteURL ?? origin, name: episode.name)
            }
            guard !choices.isEmpty else { throw TVError.unsupported(L10n.text("The API did not return a single playback URL.")) }
            let duration = result["duration"]?.double.flatMap { $0 > 0 ? $0 : nil }
            let danmaku = result["danmaku"]?.string
            let mediaDanmaku = MediaDanmakuDescriptor(result: result, baseURL: site.api, headers: headers)
            if let mediaDanmaku {
                for choice in choices {
                    if let address = try? WebAddress.resolve(choice.address) { MediaDanmakuRegistry.register(mediaDanmaku, for: address) }
                }
            }
            // Separate video and audio files (DASH), which the app describes as HLS for the player.
            if let dash = result["dash"]?.object {
                do {
                    guard let master = try await DashStreams.stream(dash, headers: headers, danmaku: danmaku, session: http.session) else {
                        throw TVError.unsupported(L10n.text("The API did not return a single playback URL."))
                    }
                    if let mediaDanmaku { MediaDanmakuRegistry.register(mediaDanmaku, for: master) }
                    return PlaybackPlan(choices: [PlaybackChoice(id: 0, name: episode.name, address: master.absoluteString)], headers: headers,
                                        group: episode.flag, requiresWebDetection: false, subtitles: ExternalSubtitle.parse(result["subs"]))
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    throw error
                }
            }
            // An encrypted MP4 with its key, which the app decrypts as it plays.
            if let key = result["decryptKey"]?.string, !key.isEmpty {
                do {
                    let remote = try WebAddress.resolve(choices[0].address)
                    let backups = (result["backupUrls"]?.array ?? []).compactMap { $0.string.flatMap { try? WebAddress.resolve($0) } }
                    let address: URL
                    if forDownload {
                        address = try await HongguoMedia.shared.prepare(url: remote, backups: backups, key: key, headers: headers, http: http)
                    } else {
                        address = try HongguoStreams.register(url: remote, backups: backups, key: key, headers: headers, http: http)
                    }
                    if let mediaDanmaku { MediaDanmakuRegistry.register(mediaDanmaku, for: address) }
                    choices = [PlaybackChoice(id: 0, name: episode.name, address: address.absoluteString)]
                    headers = [:]
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    throw TVError.unsupported(L10n.text("This Hongguo video could not be prepared for playback. Please try again."))
                }
            } else if danmaku != nil, let url = try? WebAddress.resolve(choices[0].address) {
                DanmakuSource.register(url, feed: danmaku, duration: duration)
            }
            return PlaybackPlan(choices: choices, headers: headers, group: episode.flag,
                                requiresWebDetection: (result["parse"]?.int ?? 0) != 0 || (result["jx"]?.int ?? 0) != 0 || !prefix.isEmpty, click: click, webPlayURL: "",
                                subtitles: ExternalSubtitle.parse(result["subs"]))
        }
        if let reading = ReadingMedia.normalize(.string(episode.address), baseURL: origin, headers: headers) {
            if forDownload { throw TVError.unsupported("图集和漫画请在阅读器中打开，不能作为视频下载。") }
            return reading.playbackPlan(name: episode.name, group: episode.flag)
        }
        let prefix = site.raw["playUrl"]?.string ?? ""
        let click = Self.playbackClick(site: site, result: nil)
        if prefix.hasPrefix("json:") || prefix.hasPrefix("parse:") {
            return PlaybackPlan(choices: [PlaybackChoice(id: 0, name: episode.name, address: episode.address)], headers: headers, group: episode.flag, requiresWebDetection: true, click: click, webPlayURL: prefix)
        }
        return PlaybackPlan(choices: [PlaybackChoice(id: 0, name: episode.name, address: prefix + episode.address)], headers: headers, group: episode.flag, requiresWebDetection: !prefix.isEmpty || site.raw["requiresWebDetection"] == .bool(true), click: click, webPlayURL: "")
    }

    /// Playback routing, in TVBox order, with one extra step Yingxia already had.
    ///
    /// A direct media address plays immediately. `json:` asks that one JSON service and
    /// stops, even when the answer is empty. `parse:` runs the named parser: type 0 sniffs
    /// `parser + page`, type 1 asks that JSON service, type 2 and 3 fail, and type 4 races
    /// every type 0 and type 1 parser. A flag list on a parser limits that type to the
    /// parsers that contain the episode flag; if none contain it, that type uses them all.
    /// Any other page runs the HTML and JSON fast path first, then sniffs the page.
    /// The 15 second clock belongs to the sniffer, not to this function.
    ///
    /// A client sniffer wins. Otherwise the process-wide `WebSniff.current` is used.
    /// Neither exists on Apple TV, which throws the existing web-detection error.
    /// This does not call a spider `isVideoFormat`.
    public func resolvePlayback(_ plan: PlaybackPlan, choice: PlaybackChoice) async throws -> Channel {
        if choice.playback?.reading != nil {
            return Channel(name: choice.name, group: plan.group, url: URL(string: "reading://catalog")!, playback: choice.playback)
        }
        let headers = plan.headers.merging(choice.headers) { _, new in new }
        let selectedPlan = PlaybackPlan(choices: plan.choices, headers: headers, group: plan.group,
            requiresWebDetection: plan.requiresWebDetection, click: plan.click, webPlayURL: plan.webPlayURL, subtitles: plan.subtitles)
        var channel = try await resolveSelectedPlayback(selectedPlan, choice: choice)
        channel.playback = channel.playback ?? choice.playback
        let liveRoute = site.raw["catPawOpen"]?.string ?? site.api
        if PlaybackSourceContext.isLive(route: liveRoute, fields: site.raw, group: plan.group) {
            var descriptor = channel.playback ?? PlaybackDescriptor(format: channel.url.pathExtension)
            descriptor.isLive = true; channel.playback = descriptor
        }
        PlaybackQualityRegistry.register(channel.url, client: self, plan: plan, selected: choice.id)
        return channel
    }

    private func resolveSelectedPlayback(_ plan: PlaybackPlan, choice: PlaybackChoice) async throws -> Channel {
        if let url = URL(string: choice.address), DashManifest.recognizes(url) {
            #if os(iOS)
            // KSPlayer's FFmpeg demuxer reads ordinary DASH directly, including
            // SegmentTemplate/SegmentList manifests the AVPlayer bridge cannot represent.
            return Channel(name: choice.name, group: plan.group, url: url, headers: plan.headers, subtitles: plan.subtitles,
                           playback: choice.playback ?? PlaybackDescriptor(format: "mpd"))
            #else
            let address = try await DashManifest.stream(url, name: choice.name, headers: plan.headers, session: http.session)
            return Channel(name: choice.name, group: plan.group, url: address, headers: plan.headers, subtitles: plan.subtitles)
            #endif
        }
        // Addresses the app made itself from the play result: a keyed MP4 or DASH described as HLS.
        if let url = URL(string: choice.address), url.scheme == HongguoStreams.scheme || url.scheme == DashStreams.scheme {
            return Channel(name: choice.name, group: plan.group, url: url, headers: url.scheme == DashStreams.scheme ? plan.headers : [:])
        }
        // A drive in Cloud Files hands over its stream, which carries the CDN's headers itself.
        if site.isCloudFiles, let url = URL(string: choice.address), url.scheme == CloudStreams.scheme {
            return Channel(name: choice.name, group: plan.group, url: url, headers: [:])
        }
        if !plan.requiresWebDetection || Self.isDirectMedia(choice.address) {
            return try await playResolved(plan, choice: choice)
        }
        let playURL = plan.webPlayURL
        if playURL.hasPrefix("json:") {
            let service = String(playURL.dropFirst("json:".count))
            if let found = await WebPlayback.askJSON(service: service, page: choice.address, headers: plan.headers, http: http) {
                return Channel(name: choice.name, group: plan.group, url: found.url, headers: found.headers)
            }
            throw Self.webDetectionError
        }
        if playURL.hasPrefix("parse:") {
            let name = String(playURL.dropFirst("parse:".count))
            guard let item = parses.first(where: { $0.name == name }) else { throw Self.webDetectionError }
            switch item.type {
            case 0:
                return try await sniff(plan, choice: choice, target: item.url + choice.address, headers: item.headers.isEmpty ? plan.headers : item.headers, click: plan.click)
            case 1:
                let headers = item.headers.isEmpty ? plan.headers : item.headers
                if let found = await WebPlayback.askJSON(service: item.url, page: choice.address, headers: headers, http: http) {
                    return Channel(name: choice.name, group: plan.group, url: found.url, headers: found.headers)
                }
                throw Self.webDetectionError
            case 4:
                if let found = await superParse(plan, page: choice.address) {
                    return Channel(name: choice.name, group: plan.group, url: found.url, headers: found.headers)
                }
                throw Self.webDetectionError
            default:
                throw Self.webDetectionError
            }
        }
        if let found = await WebPlayback.resolve(page: choice.address, headers: plan.headers, parses: parses, http: http) {
            return Channel(name: choice.name, group: plan.group, url: found.url, headers: found.headers)
        }
        return try await sniff(plan, choice: choice, target: choice.address, headers: plan.headers, click: plan.click)
    }

    private static let webDetectionError = TVError.unsupported(L10n.text("This source requires web video detection or additional parsing. Only resolved media URLs are supported."))
    /// The sniffer ran and the 15 second clock ended with no playable address.
    private static let sniffTimeoutError = TVError.unsupported(L10n.text("Video detection timed out before a playable address appeared."))

    private func playResolved(_ plan: PlaybackPlan, choice: PlaybackChoice) async throws -> Channel {
        let unwrapped = Self.unwrapPluginProxy(choice.address)
        let clientProxy = Self.clientProxyParts(unwrapped)
        let address = clientProxy?.inner ?? Self.unwrapClientProxy(unwrapped)
        if site.key == "local.media.file", let file = URL(string: address), file.isFileURL,
           FileManager.default.fileExists(atPath: file.path) {
            return Channel(name: choice.name, group: plan.group, url: file, headers: plan.headers)
        }
        if address.lowercased().hasPrefix("magnet:") { throw TVError.unsupported(L10n.text("This source returned a magnet link. Torrent playback is not supported.")) }
        // Only an address that arrived through the client-proxy unwrap, with a
        // real multi-thread request, may engage the MT proxy. Registration
        // failure of any kind falls through to the direct address below.
        if let clientProxy, clientProxy.thread > 1, let mtURL = await Self.mtProxyURL(clientProxy, headers: plan.headers) {
            return Channel(name: choice.name, group: plan.group, url: mtURL, headers: [:], subtitles: plan.subtitles)
        }
        if Self.isPluginProxy(address) {
            // A Bili JAR spider's proxy id: Yingxia's own Bilibili source plays the same video.
            if let id = Self.bilibiliProxyID(address), let bilibili = CloudSources.site(where: \.isBilibili) {
                let channel = try await CatalogClient(site: bilibili, origin: CloudSources.address, http: http)
                    .playback(Episode(id: id, name: choice.name, address: id, flag: plan.group))
                return Channel(name: choice.name, group: plan.group, url: channel.url, headers: channel.headers, subtitles: channel.subtitles)
            }
            throw TVError.unsupported(L10n.text("This source needs a playback proxy that is not supported yet."))
        }
        return Channel(name: choice.name, group: plan.group, url: try MediaAddress.resolve(address), headers: plan.headers, subtitles: plan.subtitles)
    }

    /// `aid_cid[_ep]` from a Bili spider's proxy address (`…/proxy?do=bili&aid=…&cid=…&ep=…`).
    static func bilibiliProxyID(_ address: String) -> String? {
        let items = pluginProxyQuery(address)
        func parameter(_ name: String) -> String? { items.first(where: { $0.name == name })?.value.flatMap { UInt64($0) != nil ? $0 : nil } }
        guard items.first(where: { $0.name == "do" })?.value == "bili", let aid = parameter("aid"), let cid = parameter("cid") else { return nil }
        return [aid, cid, parameter("ep")].compactMap { $0 }.joined(separator: "_")
    }

    private func sniff(_ plan: PlaybackPlan, choice: PlaybackChoice, target: String, headers: [String: String], click: String) async throws -> Channel {
        let detect = !target.contains("player/?url=")
        guard let sniffer = sniffer ?? WebSniff.current else { throw Self.webDetectionError }
        guard let found = await sniffer.sniff(url: target, headers: headers, click: click, detect: detect, ads: sniffAds, rules: sniffRules) else {
            throw Self.sniffTimeoutError
        }
        if found.url.absoluteString.lowercased().hasPrefix("magnet:") {
            throw TVError.unsupported(L10n.text("This source returned a magnet link. Torrent playback is not supported."))
        }
        return Channel(name: choice.name, group: plan.group, url: found.url, headers: found.headers)
    }

    /// Every type 0 and type 1 parser races, a few at a time: a web parser is a hidden page and window,
    /// and a dead JSON service holds its slot until the HTTP timeout.
    private func superParse(_ plan: PlaybackPlan, page: String) async -> (url: URL, headers: [String: String])? {
        let json = Self.parsers(parses, type: 1, flag: plan.group)
        let webs = Self.parsers(parses, type: 0, flag: plan.group)
        let active = sniffer ?? WebSniff.current
        let http = self.http, ads = sniffAds, rules = sniffRules
        return await withTaskGroup(of: (web: Bool, found: (url: URL, headers: [String: String])?).self) { group in
            var pendingJSON = json.makeIterator(), pendingWebs = webs.makeIterator()
            func askNextJSON() {
                guard let item = pendingJSON.next() else { return }
                group.addTask { (false, await WebPlayback.askJSON(service: item.url, page: page, headers: item.headers, http: http)) }
            }
            func sniffNextWeb() {
                guard let active, let item = pendingWebs.next() else { return }
                let target = item.url + page
                group.addTask {
                    (true, await active.sniff(url: target, headers: item.headers, click: item.click, detect: !target.contains("player/?url="), ads: ads, rules: rules))
                }
            }
            for _ in 0..<Self.superParseJSONWidth { askNextJSON() }
            for _ in 0..<Self.superParseWebWidth { sniffNextWeb() }
            while let next = await group.next() {
                if let found = next.found { group.cancelAll(); return found }
                if next.web { sniffNextWeb() } else { askNextJSON() }
            }
            return nil
        }
    }
    static let superParseJSONWidth = 4
    static let superParseWebWidth = 2

    private static func parsers(_ items: [ParseService], type: Int, flag: String) -> [ParseService] {
        let typed = items.filter { $0.type == type }
        let flagged = typed.filter { $0.flags.contains(flag) }
        return flagged.isEmpty ? typed : flagged
    }
    static func isDirectMedia(_ address: String) -> Bool {
        guard let url = try? MediaAddress.resolve(address) else { return false }
        if MediaAddress.streamingSchemes.contains(url.scheme?.lowercased() ?? "") { return true }
        return ["mp4", "m4v", "mov", "mkv", "avi", "flv", "webm", "ts", "m2ts", "m3u8", "mpd", "mp3", "m4a", "aac", "flac", "wav", "iso", "bdmv", "mpls"].contains(url.pathExtension.lowercased())
    }
    static func providerError(_ result: [String: JSONValue]) -> String? {
        // Providers often supply the useful login/authorization reason beside an empty URL.
        guard result["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              result["url"]?.array?.isEmpty != false else { return nil }
        for key in ["errMsg", "error", "msg", "message"] {
            if let message = result[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty { return message }
        }
        return nil
    }
    static func isPluginProxy(_ address: String) -> Bool {
        guard let marker = address.range(of: "/proxy?") else { return false }
        let authority = String(address[..<marker.lowerBound])
        for host in ["http://127.0.0.1", "http://localhost"] {
            if authority == host { return true }
            if authority.hasPrefix(host + ":"), let port = Int(authority.dropFirst(host.count + 1)), (-1...65535).contains(port) { return true }
        }
        return false
    }
    /// The query of a plugin proxy address, split by hand. Plugins don't always percent-encode the wrapped
    /// address (spaces, CJK, `|` headers, a bare `%`), and `URLComponents.percentEncodedQuery` traps on those.
    static func pluginProxyQuery(_ address: String) -> [URLQueryItem] {
        guard isPluginProxy(address), let marker = address.range(of: "/proxy?") else { return [] }
        func decode(_ text: Substring) -> String { String(text).removingPercentEncoding ?? String(text) }
        return address[marker.upperBound...].split(separator: "&", omittingEmptySubsequences: false).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return URLQueryItem(name: decode(parts[0]), value: parts.count > 1 ? decode(parts[1]) : nil)
        }
    }
    /// Plugins wrap HLS addresses in their own loopback proxy (`http://127.0.0.1:<port>/proxy?do=m3u8&url=...`).
    /// This app hosts no such proxy, and in `m3u8` mode the wrapped address is the real playlist.
    static func unwrapPluginProxy(_ address: String) -> String {
        let items = pluginProxyQuery(address)
        guard items.first(where: { $0.name == "do" })?.value == "m3u8",
              let inner = items.first(where: { $0.name == "url" })?.value, !inner.isEmpty else { return address }
        return inner
    }
    /// Some servers rewrite play results through the client app's own loopback proxy
    /// (`http://127.0.0.1:5575/proxy?thread=10&chunkSize=256&url=...`), which only that client can serve.
    /// In this `thread`/`chunkSize` mode the wrapped address is the real media, so it plays directly.
    static func unwrapClientProxy(_ address: String) -> String {
        let items = pluginProxyQuery(address)
        guard items.contains(where: { $0.name == "thread" }), items.contains(where: { $0.name == "chunkSize" }),
              let inner = items.first(where: { $0.name == "url" })?.value, !inner.isEmpty else { return address }
        return inner
    }
    /// The parts of a client-proxy address: the wrapped media address plus the
    /// `thread`/`chunkSize` parameters `unwrapClientProxy` reads only as a guard.
    static func clientProxyParts(_ address: String) -> (inner: String, thread: Int, chunkSizeKB: Int)? {
        let items = pluginProxyQuery(address)
        guard items.contains(where: { $0.name == "thread" }), items.contains(where: { $0.name == "chunkSize" }),
              let inner = items.first(where: { $0.name == "url" })?.value, !inner.isEmpty else { return nil }
        let thread = items.first(where: { $0.name == "thread" })?.value.flatMap { Int($0) } ?? 0
        let chunkSizeKB = items.first(where: { $0.name == "chunkSize" })?.value.flatMap { Int($0) } ?? 0
        return (inner, thread, chunkSizeKB)
    }
    /// Registers an unwrapped address with the embedded host's multi-thread
    /// proxy. The play headers travel over the authenticated service channel
    /// and live only in Node; the returned URL carries just an opaque token.
    /// A non-HTTP(S) or loopback inner address, and any registration failure,
    /// returns nil so the caller keeps the direct address.
    private static func mtProxyURL(_ parts: (inner: String, thread: Int, chunkSizeKB: Int), headers: [String: String]) async -> URL? {
        guard let inner = URL(string: parts.inner), ["http", "https"].contains(inner.scheme?.lowercased() ?? ""),
              let host = inner.host?.lowercased(), !["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
        let params: [String: JSONValue] = ["url": .string(parts.inner),
            "headers": .object(headers.mapValues(JSONValue.string)),
            "thread": .number(Double(parts.thread)), "chunkSizeKB": .number(Double(parts.chunkSizeKB))]
        guard let answer = try? await EmbeddedNodeHost.shared.mediaService("mt.register", params: params),
              let address = answer.object?["url"]?.string, let url = URL(string: address) else { return nil }
        return url
    }
}
