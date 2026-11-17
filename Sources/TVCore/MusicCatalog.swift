import Foundation

/// A catalog's song search. It only finds songs: a song a catalog lists may still have no audio.
public protocol MusicCatalogSource: Sendable {
    var platform: MusicPlatform { get }
    /// One page of results, 1-based, in the catalog's own order.
    func search(_ query: String, page: Int) async throws -> [MusicTrack]
}

/// QQ Music's keyword search, as its mobile app asks it. The desktop method answered code 2001
/// to anonymous callers in testing (2026-10-13); the mobile one returned results.
public struct QQMusicCatalog: MusicCatalogSource {
    public let platform = MusicPlatform.qq
    let transport: MusicTransport
    static let pageSize = 20
    static let timeout: TimeInterval = 6
    public init(transport: MusicTransport = URLSessionMusicTransport()) { self.transport = transport }

    public func search(_ query: String, page: Int) async throws -> [MusicTrack] {
        let json = try await call(module: "music.search.SearchCgiService", method: "DoSearchForQQMusicMobile", param: [
            "query": query, "num_per_page": Self.pageSize, "page_num": max(1, page), "search_type": 0,
            "searchid": String(UInt64.random(in: 1_000_000_000...9_999_999_999)),
        ])
        return try Self.parse(json)
    }

    static func parse(_ json: JSONValue) throws -> [MusicTrack] {
        let code = json[path: "req", "code"]?.int ?? json["code"]?.int
        guard code == 0 else { throw MusicProviderError.invalidResponse("QQ search code \(code.map(String.init) ?? "-")") }
        guard let songs = json[path: "req", "data", "body", "item_song"]?.array
                ?? json[path: "req", "data", "body", "song", "list"]?.array else {
            if json[path: "req", "data", "meta", "sum"]?.int == 0 { return [] }
            throw MusicProviderError.invalidResponse("QQ search has no song list")
        }
        return songs.compactMap(track)
    }

    /// One song as QQ lists it in search results, albums and playlists.
    static func track(_ row: JSONValue) -> MusicTrack? {
        let song = row["songInfo"] ?? row["data"] ?? row
        guard let mid = MusicCatalogData.text(song, "mid", "songmid"),
              let title = MusicCatalogData.text(song, "title", "name", "songname").map(MusicText.plain), !title.isEmpty else { return nil }
        let artists = (song["singer"]?.array ?? []).compactMap { $0["name"]?.string }
        let albumMid = song[path: "album", "mid"]?.string ?? song["albummid"]?.string ?? ""
        var track = MusicTrack(platform: .qq, songID: mid, title: title, artists: artists,
                               album: song[path: "album", "name"]?.string ?? song["albumname"]?.string, duration: song["interval"]?.double,
                               artwork: albumMid.isEmpty ? nil : URL(string: "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg"))
        // "2005-11-01"; empty for some live recordings.
        track.year = song["time_public"]?.string.flatMap { Int($0.prefix(4)) }.flatMap { $0 > 1900 ? $0 : nil }
        track.genre = song["genre"]?.int.flatMap(MusicGenre.init(qqCode:))
        track.language = song["language"]?.int.flatMap(MusicLanguage.init(qqCode:))
        var info = MusicCatalogData.info(track, songmid: .string(mid))
        info["songId"] = song["id"] ?? song["songid"]
        info["albumId"] = song[path: "album", "id"] ?? song["albumid"]
        if !albumMid.isEmpty { info["albumMid"] = .string(albumMid); info["albummid"] = .string(albumMid) }
        // A missing media MID must stay missing so legacy rows trigger exact metadata hydration.
        // Filling it with songmid would turn a known different identifier into a false cache hit.
        info["strMediaMid"] = song[path: "file", "media_mid"] ?? song["strMediaMid"]
        var types: [String: JSONValue] = [:]
        for (type, field, oldField) in [("128k", "size_128mp3", "size128"), ("320k", "size_320mp3", "size320"),
                                       ("flac", "size_flac", "sizeflac"), ("flac24bit", "size_hires", "sizehires")] {
            if let size = song[path: "file", field]?.double ?? song[oldField]?.double, size > 0 {
                types[type] = .object(["size": .number(size)])
            }
        }
        MusicCatalogData.qualityFields(types, in: &info)
        track.setLXInfo(info, for: .qq)
        return track
    }
}

/// NetEase's public catalog searches independently of the selected audio source. GD Studio is
/// a fallback for catalog outages, so normal browsing never spends its audio request budget.
public struct NeteaseMusicCatalog: MusicCatalogSource {
    public let platform = MusicPlatform.netease
    let transport: MusicTransport
    let health: MusicHealth
    static let pageSize = 20
    static let timeout: TimeInterval = 6
    public init(transport: MusicTransport = URLSessionMusicTransport(), health: MusicHealth = .shared) {
        self.transport = transport; self.health = health
    }

    public func search(_ query: String, page: Int) async throws -> [MusicTrack] {
        do {
            let result = try await searchJSON(query, type: "1", page: page)
            guard let songs = result[path: "result", "songs"]?.array else {
                if result[path: "result", "songCount"]?.int == 0 || result["result"]?.object?.isEmpty == true { return [] }
                throw MusicProviderError.invalidResponse("NetEase search has no song list")
            }
            var tracks = songs.compactMap(Self.track)
            let missing = tracks.filter { $0.artwork == nil }.compactMap { $0.ids[.netease] }
            if !missing.isEmpty, let details = try? await details(missing) {
                for index in tracks.indices {
                    guard let id = tracks[index].ids[.netease], let detail = details[id] else { continue }
                    tracks[index].artwork = tracks[index].artwork ?? detail.artwork
                    tracks[index].duration = tracks[index].duration ?? detail.duration
                }
            }
            return tracks
        } catch {
            try Task.checkCancellation()
            if MusicProviderError(error) == .cancelled { throw error }
            return try await searchGD(query, page: page)
        }
    }

    private func searchGD(_ query: String, page: Int) async throws -> [MusicTrack] {
        try await health.admit("gdstudio")
        let url = MusicHTTP.url("https://music-api.gdstudio.xyz/api.php", [
            ("types", "search"), ("source", "netease"), ("name", query), ("count", String(Self.pageSize)), ("pages", String(page)),
        ])
        var tracks = try Self.parse(try await MusicHTTP.json(transport, MusicHTTP.request(url, timeout: Self.timeout), timeout: Self.timeout))
        guard !tracks.isEmpty else { return [] }
        // Without durations a NetEase song can't be told from a preview, nor merged with QQ's by length.
        if let details = try? await details(tracks.compactMap { $0.ids[.netease] }) {
            for index in tracks.indices {
                guard let id = tracks[index].ids[.netease], let detail = details[id] else { continue }
                tracks[index].duration = tracks[index].duration ?? detail.duration
                tracks[index].artwork = tracks[index].artwork ?? detail.artwork
            }
        }
        return tracks
    }

    static func parse(_ json: JSONValue) throws -> [MusicTrack] {
        guard let songs = json.array else {
            throw MusicProviderError.invalidResponse("GD search: \(json["error"]?.string ?? json["msg"]?.string ?? "not a list")")
        }
        return songs.compactMap { song in
            guard let id = song["id"]?.string, !id.isEmpty, let title = song["name"]?.string, !title.isEmpty else { return nil }
            let artists = song["artist"]?.array?.compactMap(\.string) ?? song["artist"]?.string.map { [$0] } ?? []
            return MusicTrack(platform: .netease, songID: id, title: title, artists: artists, album: song["album"]?.string)
        }
    }

    struct Detail: Equatable { var duration: Double?; var artwork: URL? }

    func details(_ ids: [String]) async throws -> [String: Detail] {
        let url = MusicHTTP.url("https://music.163.com/api/song/detail/", [("ids", "[" + ids.joined(separator: ",") + "]")])
        let request = MusicHTTP.request(url, timeout: Self.timeout, headers: ["Referer": "https://music.163.com/"])
        return Self.parseDetails(try await MusicHTTP.json(transport, request, timeout: Self.timeout))
    }

    /// One song as NetEase lists it in details, albums and playlists (old and new field names).
    static func track(_ song: JSONValue) -> MusicTrack? {
        guard let id = song["id"]?.string, !id.isEmpty, let title = song["name"]?.string, !title.isEmpty else { return nil }
        let artists = (song["ar"]?.array ?? song["artists"]?.array ?? []).compactMap { $0["name"]?.string }
        let album = song["al"] ?? song["album"]
        let milliseconds = song["dt"]?.double ?? song["duration"]?.double
        var track = MusicTrack(platform: .netease, songID: id, title: title, artists: artists, album: album?["name"]?.string,
                               duration: milliseconds.map { $0 / 1000 },
                               artwork: album?["picUrl"]?.string.flatMap { URL(string: $0 + "?param=300y300") })
        var info = MusicCatalogData.info(track, songmid: song["id"] ?? .string(id))
        info["songId"] = song["id"]; info["albumId"] = album?["id"]
        var types: [String: JSONValue] = [:]
        for (type, fields) in [("128k", ["l", "lMusic"]), ("320k", ["h", "hMusic"]), ("flac", ["sq", "sqMusic"]), ("flac24bit", ["hr", "hrMusic"])] {
            if let detail = fields.lazy.compactMap({ song[$0] }).first,
               let size = detail["size"]?.double, size > 0 { types[type] = .object(["size": .number(size)]) }
        }
        MusicCatalogData.qualityFields(types, in: &info)
        track.setLXInfo(info, for: .netease)
        track.year = album?["publishTime"]?.double.flatMap { $0 > 0 ? Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: $0 / 1000)) : nil }
        return track
    }

    static func parseDetails(_ json: JSONValue) -> [String: Detail] {
        var details: [String: Detail] = [:]
        for song in json["songs"]?.array ?? [] {
            guard let id = song["id"]?.string else { continue }
            let milliseconds = song["duration"]?.double ?? song["dt"]?.double
            let picture = (song[path: "album", "picUrl"] ?? song[path: "al", "picUrl"])?.string
            details[id] = Detail(duration: milliseconds.map { $0 / 1000 },
                                 artwork: picture.flatMap { URL(string: $0 + "?param=300y300") })
        }
        return details
    }
}
