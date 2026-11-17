#if os(iOS)
import Foundation
import SwiftUI
import CryptoKit
import TVCore

/// Called only by the selected HTML document's checked bridge. Fresh playback
/// plans remain in its catalog client; persisted rows keep the original identity.
@MainActor enum LocalHTMLHomeActions {
    static func invoke(_ method: String, payload: [String: Any], store: Store, openRoute: RouteOpener? = nil) async throws -> Any {
        let home = LocalHTMLHomeStore.load().active
        let homeID = LocalHTMLHomeStore.load().activeID, historyScope = store.historyScope
        func current() throws {
            try Task.checkCancellation()
            guard LocalHTMLHomeStore.load().activeID == homeID, store.historyScope == historyScope else { throw CancellationError() }
        }
        try current()
        switch method {
        case "app.search": store.searchVideos(string(payload, "keyword")); return [:] as [String: String]
        case "app.openVod": store.section = .sites; return [:] as [String: String]
        case "app.openLive": store.section = .live; return [:] as [String: String]
        case "app.openKeep": store.section = .favorites; return [:] as [String: String]
        case "app.openSetting":
            if let openRoute { openRoute(Route { AnyView(LocalHomeSettingsView()) }) }
            else { store.section = .settings }
            return [:] as [String: String]
        case "app.history":
            return store.visibleHistory.map { entry -> [String: Any] in
                let context = entry.context
                return ["id": entry.id, "title": context.displayTitle, "name": context.displayTitle,
                        "poster": context.poster?.absoluteString ?? "", "position": entry.position, "duration": entry.duration,
                        "completed": entry.completed, "updatedAt": ISO8601DateFormatter().string(from: entry.updatedAt),
                        "episodeName": context.episodeName, "siteKey": context.sourceKey,
                        "request": ["sourceId": context.origin.absoluteString, "siteKey": context.sourceKey, "siteName": context.sourceName,
                                    "id": context.videoID, "title": context.displayTitle, "flag": context.episodeFlag,
                                    "episodeName": context.episodeName, "historyScope": context.libraryScope ?? "", "poster": context.poster?.absoluteString ?? ""],
                        "vod": ["id": context.videoID, "name": context.displayTitle, "poster": context.poster?.absoluteString ?? "", "siteKey": context.sourceKey]]
            }
        case "player.playVod":
            guard let config = store.subscription,
                  let site = config.sites.first(where: { $0.key == string(payload, "siteKey") || $0.sourceKey == string(payload, "siteKey") }),
                  site.canBrowse(jarURL: config.spiderURL), !store.hiddenSources.contains(site, origin: config.origin) else {
                throw LocalHTMLHomeError("请先添加并启用对应站点")
            }
            guard let openRoute else { throw LocalHTMLHomeError("当前页面无法打开详情，请返回首页重试") }
            let id = string(payload, "vodId")
            guard !id.isEmpty else { throw LocalHTMLHomeError("首页影片标识为空") }
            let video = Video(id: id, name: string(payload, "title"), poster: poster(payload))
            let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
            openRoute(Route { AnyView(VideoDetailView(video: video, client: client)) })
            return [:] as [String: String]
        case "player.playUrl":
            let media = try normalizedMedia(string(payload, "url"), audio: string(payload, "audioUrl"))
            if media.audioURL != nil || bool(payload, "isLive") || string(payload, "url").lowercased().hasPrefix("data:") {
                var inline = payload
                inline["episodes"] = [["name": string(payload, "title"), "url": string(payload, "url"), "audioUrl": string(payload, "audioUrl")]]
                return try await playInline(inline, home: home, store: store, current: current)
            }
            let headers = try mergedHeaders(payload)
            let request = MediaPushRequest(input: media.url.absoluteString, title: string(payload, "title"), headers: headers)
            let record = try LocalMediaLibrary.shared.register(request, mode: bool(payload, "sniff") ? .sniff : .direct)
            var client = CatalogClient(site: record.site, origin: LocalMediaLibrary.origin)
            if let config = store.subscription { client = client.applying(config) }
            let video = record.video.keepingPoster(poster(payload))
            guard let episode = video.episodes.first else { throw LocalHTMLHomeError("首页没有可播放的资源") }
            let choice = PlaybackChoice(id: 0, name: episode.name, address: media.url.absoluteString,
                playback: PlaybackDescriptor(format: format(media.format, fallback: string(payload, "format")), isLive: false))
            let plan = PlaybackPlan(choices: [choice], headers: headers, group: episode.flag, requiresWebDetection: bool(payload, "sniff"))
            client = client.withLocalPlaybackPlans([episode.id: plan])
            let resolved = try await client.playback(episode)
            try current()
            store.playing = store.catalogChannel(resolved, video: video, episode: episode, client: client)
            return response(store.playing, title: video.name)
        case "player.playVodInline": return try await playInline(payload, home: home, store: store, current: current)
        case "pan.check":
            guard let rows = payload["items"] as? [[String: Any]], !rows.isEmpty, rows.count <= 20 else { throw LocalHTMLHomeError("每批检测需要 1 至 20 条链接") }
            let items = try rows.enumerated().map { index, row in
                let url = try LocalHTMLHomePolicy.address(string(row, "url")).absoluteString
                return PanSearchItem(id: "html-home-\(index)", title: "", url: url, input: url,
                    diskType: diskType(string(row, "diskType", "type")), password: string(row, "password", "pwd"))
            }
            let settings = PanSearchSettings.load()
            try await settings.configure(); try current()
            let result = try await PanSearchService.check(items, refresh: false)
            try current()
            return ["enabled": result.enabled, "results": result.enabled ? items.map { item -> [String: String] in
                let status = result.items.first { $0.id == item.id }
                return ["id": item.id, "state": status?.state.rawValue ?? "uncertain", "summary": status?.summary ?? "暂时无法确认"]
            } : []]
        case "pan.play":
            var raw = string(payload, "url")
            if raw.lowercased().hasPrefix("push://") { raw = String(raw.dropFirst(7)) }
            var share = try LocalHTMLHomePolicy.address(raw)
            if string(payload, "type") == "http" {
                var direct = payload; direct["url"] = share.absoluteString; direct["sniff"] = true
                direct["title"] = string(payload, "title", "name", "vod_name")
                return try await invoke("player.playUrl", payload: direct, store: store, openRoute: openRoute)
            }
            let kind = diskType(string(payload, "type")), password = String(string(payload, "password", "pwd").prefix(100))
            let keys = ["quark":"pwd", "baidu":"pwd", "123":"pwd", "uc":"pwd", "xunlei":"pwd", "115":"password", "pikpak":"pass_code", "guangya":"code"]
            if !password.isEmpty, let key = keys[kind], var components = URLComponents(url: share, resolvingAgainstBaseURL: false) {
                let remaining = (components.queryItems ?? []).filter { $0.name != key }
                components.queryItems = [URLQueryItem(name: key, value: password)] + remaining
                if let value = components.url { share = value }
            }
            guard let config = store.subscription else { throw LocalHTMLHomeError("请先导入包含网盘推送站点的订阅") }
            let sources = MediaPush.sources(config.sites).filter { $0.canBrowse(jarURL: config.spiderURL) }
            guard let site = sources.first(where: { $0.origin(or: config.origin).absoluteString == historyScope }) ?? sources.first else { throw LocalHTMLHomeError("当前订阅没有可用的推送站点") }
            let base = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
            let request = MediaPushRequest(input: share.absoluteString, title: string(payload, "title", "name", "vod_name"))
            let model = MediaPushModel()
            await model.resolve(request, client: base); try current()
            guard let found = model.video else { throw LocalHTMLHomeError(model.error ?? "网盘未返回可播放资源") }
            let video = found.keepingPoster(poster(payload))
            if video.isFolder {
                guard let openRoute else { throw LocalHTMLHomeError("请从盘搜结果打开此目录") }
                openRoute(Route { AnyView(SiteView(site: site, origin: config.origin, jarURL: config.spiderURL, folder: video)) })
                return [:] as [String: String]
            }
            guard let episode = video.episodes.first else { throw LocalHTMLHomeError("网盘未返回可播放文件") }
            var seen = Set<String>()
            let client = base.withPushInput(request.input, flags: video.episodes.map(\.flag).filter { seen.insert($0).inserted })
            let resolved = try await client.playback(episode); try current()
            try PushMediaLibrary.shared.register(request, video: video, client: base)
            store.playing = store.catalogChannel(resolved, video: video, episode: episode, client: client)
            return response(store.playing, title: video.name)
        case "player.status":
            let session = PlaybackSession.sharedLocal
            let active = store.playing != nil && session.activeChannelID == store.playing?.id
            return ["playing": active && !session.paused && !session.loading,
                    "title": store.playing?.historyContext?.displayTitle ?? store.playing?.name ?? "",
                    "position": active ? session.position : 0, "duration": active ? session.duration : 0]
        case "player.control":
            let action = string(payload, "action"), session = PlaybackSession.sharedLocal
            switch action {
            case "play", "pause":
                if let channel = store.playing, session.activeChannelID == channel.id, session.paused != (action == "pause") { session.togglePlayback() }
            case "stop": store.cancelEpisodeSelection(); session.stop(); store.playing = nil
            case "next", "prev", "previous":
                if let channel = store.playing {
                    if let episode = action == "next" ? store.nextEpisode(after: channel) : store.previousEpisode(before: channel) { store.selectEpisode(episode, from: channel) }
                    else if let file = action == "next" ? store.nextFile(after: channel) : store.previousFile(before: channel) { store.playing = file }
                }
            default: throw LocalHTMLHomeError("不支持的播放控制")
            }
            return [:] as [String: String]
        default: throw LocalHTMLHomeError("暂不支持此首页功能：" + method)
        }
    }

    private static func playInline(_ payload: [String: Any], home: LocalHTMLHomeSource?, store: Store, current: () throws -> Void) async throws -> Any {
        guard let rows = payload["episodes"] as? [[String: Any]] else { throw LocalHTMLHomeError("首页播放列表无效") }
        let index = try HTMLHomePlayback.episodeIndex(payload, episodes: rows)
        let title = string(payload, "title", "vod_name").isEmpty ? "HTML 首页" : string(payload, "title", "vod_name")
        let vodID = string(payload, "vod_id"), flag = string(payload, "vod_play_from").isEmpty ? "HTML 首页" : string(payload, "vod_play_from")
        let live = bool(payload, "isLive") || flag == "直播" || vodID.range(of: "^bililive_\\d+$", options: .regularExpression) != nil
        let fallback = originalWorkURL(vodID, home: home)
        let key = (home?.id ?? "html") + "\n" + (vodID.isEmpty ? title + "\n" + original(rows[index], fallback: fallback) : vodID)
        let id = "html-media-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        var episodes: [Episode] = [], plans: [String: PlaybackPlan] = [:]
        for (offset, row) in rows.enumerated() {
            let name = string(row, "name").isEmpty ? "第\(offset + 1)集" : string(row, "name")
            let episode = Episode(id: id + "-\(offset)", name: name, address: original(row, fallback: fallback), flag: flag, videoID: id)
            episodes.append(episode)
            if bool(row, "resolve"), string(row, "mediaUrl").isEmpty { continue }
            do {
                let media = try normalizedMedia(string(row, "mediaUrl", "url"), audio: string(row, "audioUrl", "audioURL"))
                let headers = try mergedHeaders(payload, row)
                let descriptor = PlaybackDescriptor(format: format(media.format, fallback: string(row, "format").isEmpty ? string(payload, "format") : string(row, "format")),
                    audioURL: media.audioURL, audioHeaders: headers, isLive: live)
                plans[episode.id] = PlaybackPlan(choices: [PlaybackChoice(id: 0, name: name, address: media.url.absoluteString, playback: descriptor)],
                    headers: headers, group: flag, requiresWebDetection: false)
            } catch { if offset == index { throw error } }
        }
        let selected = episodes[index]
        guard plans[selected.id] != nil else { throw LocalHTMLHomeError("此集需要首页解析，请在页面中重新选择") }
        let video = Video(id: id, name: title, poster: poster(payload), episodes: episodes)
        let reference = home.map { home in
            HTMLHomePlayback.History(sourceID: home.id, workID: vodID, isLive: live,
                episodes: zip(rows, episodes).map { row, episode in
                    HTMLHomePlayback.EpisodeReference(id: episode.id, name: episode.name, pageURL: episode.address,
                        resolverURL: HTMLHomePlayback.resolverIdentity(string(row, "resolverURL", "url"), pageURL: episode.address,
                            mediaURL: string(row, "mediaUrl")))
                })
        }
        try current()
        let record = try LocalMediaLibrary.shared.registerHTML(MediaPushRequest(input: selected.address, title: title), video: video, htmlHome: reference)
        var client = CatalogClient(site: record.site, origin: LocalMediaLibrary.origin)
        if let reference { client = client.withLocalPlaybackPlans(plans, resolver: playbackResolver(reference)) }
        else { client = client.withLocalPlaybackPlans(plans) }
        if let config = store.subscription { client = client.applying(config) }
        let resolved = try await client.playback(selected); try current()
        store.playing = store.catalogChannel(resolved, video: video, episode: selected, client: client)
        return response(store.playing, title: title)
    }
    /// Watching reuses the catalog identity, while each selection asks the
    /// owning HTML source for fresh media and headers before playback begins.
    static func restoredClient(_ record: LocalMediaLibrary.Record) throws -> CatalogClient {
        let homes = LocalHTMLHomeStore.load()
        let reference: HTMLHomePlayback.History
        if let saved = record.htmlHome {
            guard homes.sources.contains(where: { $0.id == saved.sourceID }) else {
                throw LocalHTMLHomeError("这条观看记录的 HTML 来源已删除，请重新导入对应首页")
            }
            reference = saved
        } else {
            guard let source = legacySource(record, homes: homes) else {
                throw LocalHTMLHomeError("旧观看记录无法确认原 HTML 来源，请在对应首页重新播放一次以保存来源")
            }
            reference = HTMLHomePlayback.History(sourceID: source.id, workID: legacyWorkID(record.request.input),
                isLive: record.video.episodes.first?.flag == "直播", episodes: record.video.episodes.map {
                    .init(id: $0.id, name: $0.name, pageURL: $0.address, resolverURL: $0.address)
                })
        }
        return CatalogClient(site: record.site, origin: LocalMediaLibrary.origin)
            .withLocalPlaybackPlans([:], resolver: playbackResolver(reference))
    }
    private static func playbackResolver(_ reference: HTMLHomePlayback.History) -> @Sendable (Episode) async throws -> PlaybackPlan {
        { episode in try await resolve(episode, reference: reference) }
    }
    private static func resolve(_ episode: Episode, reference: HTMLHomePlayback.History) async throws -> PlaybackPlan {
        try Task.checkCancellation()
        guard let source = LocalHTMLHomeStore.load().sources.first(where: { $0.id == reference.sourceID }) else {
            throw LocalHTMLHomeError("这条观看记录的 HTML 来源已删除，请重新导入对应首页")
        }
        guard let saved = reference.episodes.first(where: { $0.id == episode.id && $0.name == episode.name && $0.pageURL == episode.address }) else {
            throw LocalHTMLHomeError("保存的这一集已不在 HTML 播放列表中")
        }
        let payload = try await LocalHTMLHomeBridge.resolveHistory(source: source, workID: reference.workID, episode: saved)
        try Task.checkCancellation()
        guard LocalHTMLHomeStore.load().sources.contains(source) else { throw CancellationError() }
        let media = try normalizedMedia(string(payload, "mediaUrl", "url"), audio: string(payload, "audioUrl", "audioURL"))
        let headers = try mergedHeaders(payload)
        let descriptor = PlaybackDescriptor(format: format(media.format, fallback: string(payload, "format")),
            audioURL: media.audioURL, audioHeaders: headers, isLive: reference.isLive)
        return PlaybackPlan(choices: [PlaybackChoice(id: 0, name: episode.name, address: media.url.absoluteString, playback: descriptor)],
            headers: headers, group: episode.flag, requiresWebDetection: bool(payload, "sniff"))
    }
    private static func legacyWorkID(_ input: String) -> String {
        guard let url = URL(string: input), let host = url.host?.lowercased(), host == "www.bilibili.com" || host == "bilibili.com" else { return "" }
        let value = url.lastPathComponent
        if value.range(of: "^BV[A-Za-z0-9]+$", options: .regularExpression) != nil { return "bili_" + value }
        if value.hasPrefix("ss"), value.dropFirst(2).allSatisfy(\.isNumber) { return "pgc_" + value.dropFirst(2) }
        return ""
    }
    private static func legacySource(_ record: LocalMediaLibrary.Record, homes: LocalHTMLHomeStore) -> LocalHTMLHomeSource? {
        let inferred = legacyWorkID(record.request.input)
        var workIDs = [record.video.name + "\n" + record.request.input]
        if !inferred.isEmpty { workIDs += [inferred, inferred.replacingOccurrences(of: "pgc_", with: "pgc1_")] }
        workIDs += aggregationWorkIDs(record.request.input)
        let exact = homes.sources.filter { source in
            workIDs.contains { workID in
                "html-media-" + SHA256.hash(data: Data((source.id + "\n" + workID).utf8)).map { String(format: "%02x", $0) }.joined() == record.video.id
            }
        }
        if exact.count == 1 { return exact[0] }
        let byPage = homes.sources.filter { source in
            record.request.input == source.address || record.request.input == "https://html-home.invalid/" + source.id
        }
        return byPage.count == 1 ? byPage[0] : nil
    }
    /// Older aggregation records already hash their homepage and adapter work ID.
    /// Recover that exact hash from the public original page, without guessing
    /// from whichever homepage happens to be selected now.
    private static func aggregationWorkIDs(_ input: String) -> [String] {
        guard let url = URL(string: input), let host = url.host?.lowercased() else { return [] }
        let segments = url.pathComponents.filter { $0 != "/" }
        var candidates: [(String, String)] = []
        if let index = segments.firstIndex(of: "videos"), segments.indices.contains(index + 1) {
            let code = segments[index + 1].uppercased()
            if host == "whos.tv" || host.hasSuffix(".whos.tv") { candidates.append(("whos", code)) }
            if host == "jable.tv" || host.hasSuffix(".jable.tv") { candidates.append(("jable", code)) }
        }
        if host == "missav.ws" || host == "missav.com" || host.hasSuffix(".missav.ws"), let code = segments.last {
            candidates.append(("missav", code.uppercased()))
            if let range = code.range(of: "^[a-z]+-?\\d+", options: [.regularExpression, .caseInsensitive]) {
                let normalized = String(code[range]).replacingOccurrences(of: "([a-z]+)-?(\\d+)", with: "$1-$2", options: [.regularExpression, .caseInsensitive])
                candidates.append(("missav", normalized.uppercased()))
            }
        }
        if host == "hanime1.me", let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
            candidates.append(("hanime", id))
        }
        if host.hasSuffix("pornhub.com"), let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "viewkey" })?.value {
            candidates.append(("ph", id))
        }
        if host == "supjav.com", let id = segments.last?.split(separator: ".").first, id.allSatisfy(\.isNumber) { candidates.append(("supjav", String(id))) }
        if host == "123av.com", let index = segments.firstIndex(of: "v"), segments.indices.contains(index + 1) {
            let slug = segments[index + 1]
            candidates.append(("av123", slug.uppercased()))
            if let range = slug.range(of: "^[a-z]+-?\\d+", options: [.regularExpression, .caseInsensitive]) {
                let code = String(slug[range]).replacingOccurrences(of: "([a-z]+)-?(\\d+)", with: "$1-$2", options: [.regularExpression, .caseInsensitive])
                candidates.append(("av123", code.uppercased()))
            }
        }
        return candidates.map { $0.0 + "_" + $0.1 }
    }
    private static func normalizedMedia(_ input: String, audio: String) throws -> (url: URL, audioURL: URL?, format: String) {
        let media = try HTMLHomePlayback.media(input)
        let url = try LocalHTMLHomePolicy.address(media.url.absoluteString)
        let track = media.audioURL?.absoluteString ?? audio
        return (url, track.isEmpty ? nil : try LocalHTMLHomePolicy.address(track), media.format)
    }
    private static func original(_ item: [String: Any], fallback: String) -> String {
        if let value = try? LocalHTMLHomePolicy.address(string(item, "pageUrl")) { return value.absoluteString }
        let value = string(item, "url"), media = string(item, "mediaUrl")
        if !value.isEmpty, (!media.isEmpty && value != media || bool(item, "resolve")),
           let original = try? LocalHTMLHomePolicy.address(value) { return original.absoluteString }
        return fallback
    }
    private static func originalWorkURL(_ id: String, home: LocalHTMLHomeSource?) -> String {
        if id.range(of: "^bili_BV[A-Za-z0-9]+$", options: .regularExpression) != nil { return "https://www.bilibili.com/video/" + id.dropFirst(5) }
        for prefix in ["pgc1_", "pgc_"] where id.hasPrefix(prefix) {
            let season = id.dropFirst(prefix.count)
            if !season.isEmpty, season.allSatisfy(\.isNumber) { return "https://www.bilibili.com/bangumi/play/ss" + season }
        }
        if let address = home?.address, let url = try? LocalHTMLHomePolicy.address(address) { return url.absoluteString }
        return "https://html-home.invalid/" + (home?.id ?? "local")
    }
    private static func mergedHeaders(_ values: [String: Any]...) throws -> [String: String] {
        var result: [String: String] = [:]
        for fields in values {
            for key in ["header", "headers"] {
                guard let raw = fields[key], !(raw is NSNull) else { continue }
                let headers: [String: String]
                if let dictionary = raw as? [String: String] { headers = dictionary }
                else if let text = raw as? String, let data = text.data(using: .utf8), let dictionary = try? JSONDecoder().decode([String: String].self, from: data) { headers = dictionary }
                else { throw LocalHTMLHomeError("首页请求头无效") }
                for (name, value) in try LocalHTMLHomePolicy.headers(headers) {
                    for old in result.keys.filter({ $0.caseInsensitiveCompare(name) == .orderedSame }) { result.removeValue(forKey: old) }
                    result[name] = value
                }
            }
        }
        return result
    }
    private static func poster(_ payload: [String: Any]) -> URL? { try? LocalHTMLHomePolicy.address(string(payload, "pic", "vod_pic", "poster", "image", "cover")) }
    private static func format(_ normalized: String, fallback: String) -> String {
        if !normalized.isEmpty { return normalized }
        switch fallback.lowercased() { case "application/dash+xml": return "mpd"; case "application/vnd.apple.mpegurl", "application/x-mpegurl", "hls": return "m3u8"; default: return fallback }
    }
    private static func string(_ payload: [String: Any], _ keys: String...) -> String {
        for key in keys { if let value = payload[key] as? String, !value.isEmpty { return value }; if let value = payload[key] as? NSNumber { return value.stringValue } }
        return ""
    }
    private static func bool(_ payload: [String: Any], _ key: String) -> Bool { payload[key] as? Bool == true }
    private static func diskType(_ value: String) -> String { value == "p115" ? "115" : value == "p123" ? "123" : value }
    private static func response(_ channel: Channel?, title: String) -> [String: Any] {
        ["id": channel?.id ?? "", "title": title, "url": channel?.url.absoluteString ?? "", "audioUrl": channel?.playback?.audioURL?.absoluteString ?? "", "isLive": channel?.playback?.isLive == true]
    }
}
#endif
