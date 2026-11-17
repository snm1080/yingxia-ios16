import Foundation

/// Kugou's recording catalog. LX resolves each quality with its own file hash while songmid is
/// the numeric audio ID; those values must remain separate all the way through a merged queue.
public struct KugouMusicCatalog: MusicCatalogSource, MusicCollectionSource, MusicBrowseSource {
    public let platform = MusicPlatform.kugou
    let transport: MusicTransport
    static let pageSize = 20
    static let timeout: TimeInterval = 8
    static let chartPrefix = "toplist:"
    public init(transport: MusicTransport = URLSessionMusicTransport()) { self.transport = transport }

    public func search(_ query: String, page: Int) async throws -> [MusicTrack] {
        let json = try await kugouJSON(MusicHTTP.url("https://songsearch.kugou.com/song_search_v2", [
            ("keyword", query), ("page", String(max(1, page))), ("pagesize", String(Self.pageSize)),
            ("format", "json"), ("platform", "WebFilter"), ("filter", "2"),
        ]))
        return try Self.parse(json)
    }

    static func parse(_ json: JSONValue) throws -> [MusicTrack] {
        try successful(json)
        guard let rows = json[path: "data", "info"]?.array ?? json[path: "data", "lists"]?.array else {
            if json[path: "data", "total"]?.int == 0 { return [] }
            throw MusicProviderError.invalidResponse("Kugou search has no song list")
        }
        return rows.compactMap(track)
    }

    static func track(_ song: JSONValue) -> MusicTrack? {
        guard let hash = MusicCatalogData.text(song, "FileHash", "Hash", "hash") else { return nil }
        let filename = MusicCatalogData.text(song, "FileName", "filename") ?? ""
        let parts = filename.components(separatedBy: " - ")
        let fallbackName = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : filename
        let title = MusicText.plain(MusicCatalogData.text(song, "SongName", "songname", "name") ?? fallbackName)
        guard !title.isEmpty else { return nil }
        var artists = MusicCatalogData.artists(song["SingerName"] ?? song["singername"] ?? song["authors"] ?? song["Singers"])
        if artists.isEmpty, parts.count > 1 { artists = MusicCatalogData.artists(.string(parts[0])) }
        let picture = MusicCatalogData.text(song, "Image", "AlbumImage", "img", "album_sizable_cover")
            ?? song[path: "trans_param", "union_cover"]?.string
        var track = MusicTrack(platform: .kugou, songID: hash, title: title, artists: artists,
                               album: MusicCatalogData.text(song, "AlbumName", "album_name", "album"),
                               duration: MusicCatalogData.duration(song["Duration"] ?? song["duration"])
                                ?? song["timelen"]?.double.map { $0 / 1000 },
                               artwork: MusicCatalogData.artwork(picture))
        let audioID = song["Audioid"] ?? song["AudioID"] ?? song["audio_id"]
        var info = MusicCatalogData.info(track, songmid: audioID ?? .string(hash))
        info["hash"] = .string(hash); info["songId"] = audioID ?? .string(hash)
        info["albumId"] = song["AlbumID"] ?? song["album_id"]
        info["albumAudioId"] = song["MixSongID"] ?? song["album_audio_id"] ?? song["albumAudioId"]
        var types: [String: JSONValue] = [:]
        let formats: [(String, [String], [String])] = [
            ("128k", ["FileHash", "Hash", "hash"], ["FileSize", "filesize"]),
            ("320k", ["HQFileHash", "320hash", "hash_high"], ["HQFileSize", "320filesize", "filesize_high"]),
            ("flac", ["SQFileHash", "sqhash", "hash_super"], ["SQFileSize", "sqfilesize", "filesize_super"]),
            ("flac24bit", ["ResFileHash", "res_hash"], ["ResFileSize", "res_filesize"]),
        ]
        for (quality, hashes, sizes) in formats {
            guard let value = hashes.lazy.compactMap({ song[$0]?.string }).first(where: { !$0.isEmpty }) else { continue }
            var detail: [String: JSONValue] = ["hash": .string(value)]
            if let size = sizes.lazy.compactMap({ song[$0]?.double }).first(where: { $0 > 0 }) { detail["size"] = .number(size) }
            types[quality] = .object(detail)
        }
        MusicCatalogData.qualityFields(types, in: &info)
        track.setLXInfo(info, for: .kugou)
        track.year = MusicCatalogData.text(song, "PublishDate", "PublishTime", "publishtime").flatMap { Int($0.prefix(4)) }
        return track
    }

    public func searchCollections(_ query: String, kind: MusicCollection.Kind, page: Int) async throws -> [MusicCollection] {
        // This public legacy catalog has no working TLS listener; these requests carry no cookies,
        // source keys or user credentials. The other Kugou endpoints use HTTPS.
        let type = kind == .album ? "album" : "special"
        let json = try await kugouJSON(MusicHTTP.url("http://mobilecdn.kugou.com/api/v3/search/" + type, [
            ("keyword", query), ("page", String(max(1, page))), ("pagesize", String(Self.pageSize)), ("showtype", "10"), ("format", "json"),
        ]))
        guard let rows = json[path: "data", "info"]?.array else {
            if json[path: "data", "total"]?.int == 0 { return [] }
            throw MusicProviderError.invalidResponse("Kugou search has no collection list")
        }
        return rows.compactMap { Self.collection($0, kind: kind) }
    }

    static func collection(_ row: JSONValue, kind: MusicCollection.Kind) -> MusicCollection? {
        let identifier = kind == .album ? MusicCatalogData.text(row, "albumid", "AlbumID") : MusicCatalogData.text(row, "specialid", "SpecialID")
        let title = kind == .album ? MusicCatalogData.text(row, "albumname", "AlbumName", "name") : MusicCatalogData.text(row, "specialname", "name")
        guard let id = identifier, let title else { return nil }
        return MusicCollection(kind: kind, platform: .kugou, collectionID: id, title: MusicText.plain(title),
                               subtitle: MusicCatalogData.text(row, "singername", "nickname"),
                               artwork: MusicCatalogData.artwork(row["imgurl"]?.string), trackCount: row["songcount"]?.int,
                               year: row["publishtime"]?.string.map { String($0.prefix(4)) })
    }

    public func tracks(of collection: MusicCollection) async throws -> [MusicTrack] {
        let chart = collection.collectionID.hasPrefix(Self.chartPrefix)
        let id = chart ? String(collection.collectionID.dropFirst(Self.chartPrefix.count)) : collection.collectionID
        try MusicCatalogData.validID(id)
        return try await MusicCollections.loadPages { page, _ in
            let json: JSONValue
            let rows: [JSONValue]?, total: Int?
            if chart {
                // The mobile web view stops after 150 rows even though it advertises 500.
                // The app catalog returns every chart page and the same recording hashes.
                json = try await kugouJSON(MusicHTTP.url("http://mobilecdn.kugou.com/api/v3/rank/song", [
                    ("rankid", id), ("format", "json"), ("page", String(page)), ("pagesize", "100"),
                ]))
                rows = json[path: "data", "info"]?.array; total = json[path: "data", "total"]?.int
            } else {
                let type = collection.kind == .album ? "album" : "special"
                json = try await kugouJSON(MusicHTTP.url("http://mobilecdn.kugou.com/api/v3/" + type + "/song", [
                    (collection.kind == .album ? "albumid" : "specialid", id), ("page", String(page)),
                    ("pagesize", "100"), ("format", "json"),
                ]))
                rows = json[path: "data", "info"]?.array; total = json[path: "data", "total"]?.int
            }
            return try MusicCollectionPage(rows: rows, total: total) { row in
                guard var track = Self.track(row) else { return nil }
                if collection.kind == .album, track.album == nil { track.album = collection.title }
                return track
            }
        }
    }

    public func browseSections() async throws -> [MusicBrowseSection] {
        async let charts = try? kugouJSON(URL(string: "https://m.kugou.com/rank/list&json=true")!)
        async let lists = try? kugouJSON(URL(string: "https://m.kugou.com/plist/index&json=true")!)
        async let albums = try? kugouJSON(MusicHTTP.url("http://mobilecdn.kugou.com/api/v3/album/list", [
            ("page", "1"), ("pagesize", String(MusicBrowse.shelfSize)), ("format", "json"), ("type", "1"),
        ]))
        let answers = await (charts, lists, albums)
        try Task.checkCancellation()
        var sections: [MusicBrowseSection] = []
        let top = (answers.0?[path: "rank", "list"]?.array ?? []).compactMap { row -> MusicCollection? in
            guard let id = row["rankid"]?.string, let name = row["rankname"]?.string else { return nil }
            return MusicCollection(kind: .playlist, platform: .kugou, collectionID: Self.chartPrefix + id,
                                   title: MusicText.plain(name), artwork: MusicCatalogData.artwork(MusicCatalogData.text(row, "imgurl", "img_cover", "img_9")))
        }
        let playlists = (answers.1?[path: "plist", "list", "info"]?.array ?? answers.1?[path: "plist", "list"]?.array ?? [])
            .compactMap { Self.collection($0, kind: .playlist) }
        let newAlbums = (answers.2?[path: "data", "info"]?.array ?? []).compactMap { Self.collection($0, kind: .album) }
        for (id, items) in [(MusicBrowse.charts, top), (MusicBrowse.playlists, playlists), (MusicBrowse.albums, newAlbums)] where !items.isEmpty {
            sections.append(.init(id: id, title: MusicBrowse.title(id), collections: Array(items.prefix(MusicBrowse.shelfSize * 2))))
        }
        guard !sections.isEmpty else { throw MusicProviderError.invalidResponse("Kugou browse has no shelves") }
        return sections
    }

    func kugouJSON(_ url: URL) async throws -> JSONValue {
        let request = MusicHTTP.request(url, timeout: Self.timeout, headers: ["Referer": "https://m.kugou.com/"])
        let json = try await MusicHTTP.json(transport, request, timeout: Self.timeout, limit: 8 * 1024 * 1024)
        try Self.successful(json)
        return json
    }

    static func successful(_ json: JSONValue) throws {
        if let status = json["status"]?.int, status != 1 {
            throw MusicProviderError.invalidResponse("Kugou catalog code \(json["errcode"]?.int ?? json["error_code"]?.int ?? status)")
        }
    }
}
