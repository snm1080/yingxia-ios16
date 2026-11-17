import Foundation

extension NeteaseMusicCatalog: MusicCollectionSource {
    public func searchCollections(_ query: String, kind: MusicCollection.Kind, page: Int) async throws -> [MusicCollection] {
        let json = try await searchJSON(query, type: kind == .album ? "10" : "1000", page: page)
        let key = kind == .album ? "albums" : "playlists"
        let count = kind == .album ? "albumCount" : "playlistCount"
        guard json[path: "result", key]?.array != nil || json[path: "result", count]?.int == 0
                || json["result"]?.object?.isEmpty == true else {
            throw MusicProviderError.invalidResponse("NetEase search has no collection list")
        }
        return Self.parseCollections(json, kind: kind)
    }

    public func tracks(of collection: MusicCollection) async throws -> [MusicTrack] {
        try MusicCatalogData.validID(collection.collectionID)
        switch collection.kind {
        case .album:
            let json = try await neteaseJSON(URL(string: "https://music.163.com/api/v1/album/\(collection.collectionID)")!)
            let rows = json["songs"]?.array ?? json[path: "album", "songs"]?.array
            let page = try MusicCollectionPage(rows: rows, total: json[path: "album", "size"]?.int ?? rows?.count,
                                              hasMore: false, parse: Self.track)
            return try await MusicCollections.loadPages { _, _ in page }
        case .playlist:
            let json = try await neteaseJSON(MusicHTTP.url("https://music.163.com/api/v6/playlist/detail", [("id", collection.collectionID), ("n", "1000")]))
            guard let rows = json[path: "playlist", "tracks"]?.array else { throw MusicProviderError.invalidResponse("NetEase playlist has no tracks") }
            let ids = (json[path: "playlist", "trackIds"]?.array ?? []).compactMap { $0["id"]?.string }
            let total = json[path: "playlist", "trackCount"]?.int ?? (ids.isEmpty ? rows.count : ids.count)
            guard total <= MusicCollections.trackLimit, ids.count <= MusicCollections.trackLimit else {
                throw MusicProviderError.invalidResponse("collection exceeds \(MusicCollections.trackLimit) tracks")
            }
            guard !ids.isEmpty else {
                let page = try MusicCollectionPage(rows: rows, total: total, hasMore: false, parse: Self.track)
                return try await MusicCollections.loadPages { _, _ in page }
            }
            var byID: [String: MusicTrack] = [:]
            for track in rows.compactMap(Self.track) { if let id = track.ids[.netease] { byID[id] = track } }
            let wanted = ids.filter { byID[$0] == nil }
            for start in stride(from: 0, to: wanted.count, by: 100) {
                try Task.checkCancellation()
                let ids = wanted[start..<min(wanted.count, start + 100)]
                let url = MusicHTTP.url("https://music.163.com/api/song/detail/", [("ids", "[" + ids.joined(separator: ",") + "]")])
                for track in (try await neteaseJSON(url)["songs"]?.array ?? []).compactMap(Self.track) {
                    if let id = track.ids[.netease] { byID[id] = track }
                }
            }
            let tracks = ids.compactMap { byID[$0] }
            guard tracks.count == ids.count, tracks.count == total else {
                throw MusicProviderError.invalidResponse("NetEase playlist is missing track details")
            }
            return tracks
        }
    }

    func searchJSON(_ query: String, type: String, page: Int) async throws -> JSONValue {
        var request = MusicHTTP.request(URL(string: "https://music.163.com/api/search/get/web")!, timeout: Self.timeout,
                                        headers: ["Referer": "https://music.163.com/", "Content-Type": "application/x-www-form-urlencoded"])
        request.httpMethod = "POST"
        request.httpBody = Data((URLComponents(url: MusicHTTP.url("https://music.163.com/", [
            ("s", query), ("type", type), ("limit", String(Self.pageSize)), ("offset", String((max(1, page) - 1) * Self.pageSize)),
        ]), resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "").utf8)
        let json = try await MusicHTTP.json(transport, request, timeout: Self.timeout)
        if let code = json["code"]?.int, code != 200 { throw MusicProviderError.invalidResponse("NetEase search code \(code)") }
        return json
    }

    func neteaseJSON(_ url: URL) async throws -> JSONValue {
        let request = MusicHTTP.request(url, timeout: Self.timeout, headers: ["Referer": "https://music.163.com/"])
        let json = try await MusicHTTP.json(transport, request, timeout: Self.timeout, limit: 8 * 1024 * 1024)
        if let code = json["code"]?.int, code != 200 { throw MusicProviderError.invalidResponse("NetEase code \(code)") }
        return json
    }

    static func parseCollections(_ json: JSONValue, kind: MusicCollection.Kind) -> [MusicCollection] {
        switch kind {
        case .album: (json[path: "result", "albums"]?.array ?? []).compactMap(album)
        case .playlist: (json[path: "result", "playlists"]?.array ?? []).compactMap(playlist)
        }
    }

    /// An album as search results and new releases list it.
    static func album(_ album: JSONValue) -> MusicCollection? {
        guard let id = album["id"]?.string, let name = album["name"]?.string else { return nil }
        let year = album["publishTime"]?.double.map { Date(timeIntervalSince1970: $0 / 1000).formatted(.dateTime.year()) }
        return MusicCollection(kind: .album, platform: .netease, collectionID: id, title: name,
                               subtitle: album[path: "artist", "name"]?.string,
                               artwork: album["picUrl"]?.string.flatMap { URL(string: $0 + "?param=300y300") },
                               trackCount: album["size"]?.int, year: year)
    }

    /// A playlist as search results, charts and recommendations list it (recommendations name the cover `picUrl`).
    static func playlist(_ list: JSONValue) -> MusicCollection? {
        guard let id = list["id"]?.string, let name = list["name"]?.string else { return nil }
        // Cover URLs carry watermark parameters; the plain image is enough.
        let cover = (list["coverImgUrl"]?.string ?? list["picUrl"]?.string).map { $0.components(separatedBy: "?")[0] + "?param=300y300" }
        return MusicCollection(kind: .playlist, platform: .netease, collectionID: id, title: name,
                               subtitle: list[path: "creator", "nickname"]?.string, artwork: cover.flatMap(URL.init(string:)),
                               trackCount: list["trackCount"]?.int)
    }
}
