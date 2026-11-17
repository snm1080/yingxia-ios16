import Foundation

extension MiguMusicCatalog: MusicCollectionSource, MusicBrowseSource {
    static let chartPrefix = "toplist:"

    func publicSearch(_ query: String, type: String, page: Int) async throws -> JSONValue {
        try await miguJSON(MusicHTTP.url("https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do", [
            ("text", query), ("pageNo", String(max(1, page))), ("pageSize", String(Self.pageSize)),
            ("searchSwitch", "{\"" + type + "\":1}"),
        ]))
    }

    public func searchCollections(_ query: String, kind: MusicCollection.Kind, page: Int) async throws -> [MusicCollection] {
        let json = try await publicSearch(query, type: kind == .album ? "album" : "songList", page: page)
        let result = json[kind == .album ? "albumResultData" : "songListResultData"]
        guard let rows = result?["result"]?.array ?? result?["resultList"]?.array else {
            if result?["totalCount"]?.int == 0 { return [] }
            throw MusicProviderError.invalidResponse("Migu search has no collection list")
        }
        return rows.compactMap { Self.collection($0, kind: kind) }
    }

    static func collection(_ row: JSONValue, kind: MusicCollection.Kind) -> MusicCollection? {
        guard let id = MusicCatalogData.text(row, "id", "albumId", "musicListId"),
              let name = MusicCatalogData.text(row, "name", "title") else { return nil }
        let artwork = row["imgItems"]?.array?.first?["img"]?.string ?? row["musicListPicUrl"]?.string
        let owner = MusicCatalogData.artists(row["singer"] ?? row["userName"]).joined(separator: " / ")
        return MusicCollection(kind: kind, platform: .migu, collectionID: id, title: MusicText.plain(name),
                               subtitle: owner, artwork: MusicCatalogData.artwork(artwork, base: "https://d.musicapp.migu.cn/"),
                               trackCount: row["musicNum"]?.int, year: row["publishDate"]?.string.map { String($0.prefix(4)) })
    }

    public func tracks(of collection: MusicCollection) async throws -> [MusicTrack] {
        if collection.collectionID.hasPrefix(Self.chartPrefix) {
            return try await chartTracks(String(collection.collectionID.dropFirst(Self.chartPrefix.count)))
        }
        try MusicCatalogData.validID(collection.collectionID)
        // Search may return a digital-album product ID. Resolve it once to materialId before
        // requesting the actual ordered song pages; using the product as albumId returns {}.
        var albumID = collection.collectionID
        var first = try await songPage(kind: collection.kind, id: albumID, page: 1)
        var expectedTotal = (first["data"] ?? first)["totalCount"]?.int
        if collection.kind == .album, (first["data"] ?? first)["songList"]?.array == nil {
            let detail = try await miguJSON(MusicHTTP.url("https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do", [
                ("resourceId", collection.collectionID), ("resourceType", "5"),
            ]))
            guard let album = detail["resource"]?.array?.first,
                  let materialID = album["materialId"]?.string, !materialID.isEmpty else {
                throw MusicProviderError.invalidResponse("Migu album identity unavailable")
            }
            albumID = materialID
            expectedTotal = album["totalCount"]?.int
            first = try await songPage(kind: .album, id: albumID, page: 1)
        }
        if collection.kind == .album, expectedTotal == nil {
            let detail = try await miguJSON(MusicHTTP.url("https://app.c.nf.migu.cn/MIGUM3.0/resource/album/v2.0", [("albumId", albumID)]))
            expectedTotal = (detail["data"] ?? detail)["totalCount"]?.int
        }
        let resolvedID = albumID, firstPage = first, fallbackTotal = expectedTotal
        return try await MusicCollections.loadPages { page, _ in
            let json = page == 1 ? firstPage : try await songPage(kind: collection.kind, id: resolvedID, page: page)
            let meta = json["data"] ?? json
            return try MusicCollectionPage(rows: meta["songList"]?.array,
                                           total: meta["totalCount"]?.int ?? fallbackTotal,
                                           hasMore: MusicCatalogData.bool(meta["hasNext"]), parse: Self.track)
        }
    }

    private func songPage(kind: MusicCollection.Kind, id: String, page: Int) async throws -> JSONValue {
        try await miguJSON(MusicHTTP.url(kind == .album
            ? "https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/queryAlbumSong"
            : "https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0", [
                (kind == .album ? "albumId" : "playlistId", id), ("pageNo", String(page)), ("pageSize", "50"),
            ]))
    }

    public func browseSections() async throws -> [MusicBrowseSection] {
        let json = try await miguJSON(URL(string: "https://app.c.nf.migu.cn/pc/bmw/rank/rank-index/v1.0")!)
        func charts(_ rows: [JSONValue]) -> [MusicCollection] {
            rows.flatMap { row in
                var result: [MusicCollection] = []
                if let id = row["rankId"]?.string, let title = row["rankName"]?.string {
                    result.append(.init(kind: .playlist, platform: .migu, collectionID: Self.chartPrefix + id,
                                        title: MusicText.plain(title), artwork: MusicCatalogData.artwork(row["imageUrl"]?.string)))
                }
                result += charts(row["contents"]?.array ?? [])
                return result
            }
        }
        var seen = Set<String>()
        let lists = charts(json[path: "data", "contents"]?.array ?? []).filter { seen.insert($0.id).inserted }
        guard !lists.isEmpty else { throw MusicProviderError.invalidResponse("Migu browse has no charts") }
        return [.init(id: MusicBrowse.charts, title: MusicBrowse.title(MusicBrowse.charts), collections: lists)]
    }

    private func chartTracks(_ id: String) async throws -> [MusicTrack] {
        try MusicCatalogData.validID(id)
        let json = try await miguJSON(MusicHTTP.url("https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/querycontentbyId.do", [
            ("columnId", id), ("needAll", "0"),
        ]))
        let rows = json[path: "columnInfo", "contents"]?.array?.compactMap { $0["objectInfo"] }
        let page = try MusicCollectionPage(rows: rows, total: json[path: "columnInfo", "contentsCount"]?.int ?? rows?.count,
                                          hasMore: false, parse: Self.track)
        return try await MusicCollections.loadPages { _, _ in page }
    }

    func miguJSON(_ url: URL) async throws -> JSONValue {
        let request = MusicHTTP.request(url, timeout: Self.timeout, headers: ["Referer": "https://m.music.migu.cn/", "channel": "0146921"])
        let json = try await MusicHTTP.json(transport, request, timeout: Self.timeout, limit: 8 * 1024 * 1024)
        if let code = json["code"]?.string, code != "000000" {
            throw MusicProviderError.invalidResponse("Migu catalog code \(code)")
        }
        return json
    }
}
