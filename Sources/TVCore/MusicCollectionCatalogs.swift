import Foundation

extension QQMusicCatalog: MusicCollectionSource {
    public func searchCollections(_ query: String, kind: MusicCollection.Kind, page: Int) async throws -> [MusicCollection] {
        let json = try await call(module: "music.search.SearchCgiService", method: "DoSearchForQQMusicMobile", param: [
            "query": query, "num_per_page": Self.pageSize, "page_num": max(1, page), "search_type": kind == .album ? 2 : 3,
            "searchid": String(UInt64.random(in: 1_000_000_000...9_999_999_999)),
        ])
        let field = kind == .album ? "item_album" : "item_songlist"
        guard json[path: "req", "data", "body", field]?.array != nil || json[path: "req", "data", "meta", "sum"]?.int == 0 else {
            throw MusicProviderError.invalidResponse("QQ search has no collection list")
        }
        return Self.parseCollections(json, kind: kind)
    }

    public func tracks(of collection: MusicCollection) async throws -> [MusicTrack] {
        if let chart = Self.chartID(collection) { return try await chartTracks(chart) }
        try MusicCatalogData.validID(collection.collectionID)
        switch collection.kind {
        case .album:
            return try await MusicCollections.loadPages { _, offset in
                let json = try await call(module: "music.musichallAlbum.AlbumSongList", method: "GetAlbumSongList",
                                          param: ["albumMid": collection.collectionID, "begin": offset, "num": 100, "order": 2])
                let data = json[path: "req", "data"]
                return try MusicCollectionPage(rows: data?["songList"]?.array, total: data?["totalNum"]?.int, parse: Self.track)
            }
        case .playlist:
            guard let id = Int(collection.collectionID) else { throw MusicProviderError.invalidResponse("invalid QQ playlist ID") }
            return try await MusicCollections.loadPages { _, offset in
                let json = try await call(module: "music.srfDissInfo.aiDissInfo", method: "uniform_get_Dissinfo", param: [
                    "disstid": id, "userinfo": 1, "tag": 1, "is_pc": 1, "orderlist": 1,
                    "song_begin": offset, "song_num": 100, "onlysonglist": 0,
                ])
                let data = json[path: "req", "data"]
                return try MusicCollectionPage(rows: data?["songlist"]?.array,
                                               total: data?["total_song_num"]?.int ?? data?[path: "dirinfo", "songnum"]?.int,
                                               parse: Self.track)
            }
        }
    }

    /// One anonymous call to QQ's music gateway; a code other than 0 is a failure.
    func call(module: String, method: String, param: [String: Any]) async throws -> JSONValue {
        let body: [String: Any] = ["comm": ["ct": 11, "cv": "1003006", "uin": "0"], "req": ["module": module, "method": method, "param": param]]
        var request = MusicHTTP.request(URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!, timeout: Self.timeout,
                                        headers: ["Referer": "https://y.qq.com/", "Content-Type": "application/json"])
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await MusicHTTP.json(transport, request, timeout: Self.timeout, limit: 8 * 1024 * 1024)
        let code = json[path: "req", "code"]?.int ?? json["code"]?.int
        guard code == 0 else { throw MusicProviderError.invalidResponse("QQ \(method) code \(code.map(String.init) ?? "-")") }
        return json
    }

    static func parseCollections(_ json: JSONValue, kind: MusicCollection.Kind) -> [MusicCollection] {
        let body = json[path: "req", "data", "body"]
        switch kind {
        case .album:
            return (body?["item_album"]?.array ?? []).compactMap { album in
                guard let mid = album["albummid"]?.string ?? album["albumMID"]?.string, !mid.isEmpty,
                      let name = album["name"]?.string ?? album["albumName"]?.string else { return nil }
                let singers = (album["singer_list"]?.array ?? []).compactMap { $0["name"]?.string }
                return MusicCollection(kind: .album, platform: .qq, collectionID: mid, title: MusicText.plain(name),
                                       subtitle: singers.isEmpty ? album["singer"]?.string.map(MusicText.plain) : singers.joined(separator: " / "),
                                       artwork: URL(string: "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(mid).jpg"),
                                       trackCount: album["song_num"]?.int, year: album["publish_date"]?.string.map { String($0.prefix(4)) })
            }
        case .playlist:
            return (body?["item_songlist"]?.array ?? []).compactMap { list in
                guard let id = list["dissid"]?.string, !id.isEmpty, let name = list["dissname"]?.string else { return nil }
                return MusicCollection(kind: .playlist, platform: .qq, collectionID: id, title: MusicText.plain(name),
                                       subtitle: list["nickname"]?.string.map(MusicText.plain),
                                       artwork: (list["logo"]?.string ?? list["imgurl"]?.string).flatMap(URL.init(string:)),
                                       trackCount: list["songnum"]?.int ?? list["song_count"]?.int)
            }
        }
    }

    static func parseAlbum(_ json: JSONValue) -> ([MusicTrack], Int) {
        let data = json[path: "req", "data"]
        let songs = (data?["songList"]?.array ?? []).compactMap { $0["songInfo"].flatMap(track) }
        return (songs, data?["totalNum"]?.int ?? songs.count)
    }

    static func parsePlaylist(_ json: JSONValue) -> [MusicTrack] {
        (json[path: "req", "data", "songlist"]?.array ?? []).compactMap(track)
    }
}
