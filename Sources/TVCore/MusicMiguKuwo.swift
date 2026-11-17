import CryptoKit
import Foundation

// Migu and Kuwo, from the BakaMusic plugins (github.com/Zencok/baka-plugins, 2026-10-14). In a
// test of 14 songs from this Mac, Migu's own servers played 12 in full (all of Jay Chou's, which
// the QQ channels no longer reach) and Kuwo through Nianxin or Xinghai played all 14, mostly FLAC.

/// Migu's app search. A Migu song needs two IDs to play, so its song ID is "contentId_copyrightId".
public struct MiguMusicCatalog: MusicCatalogSource {
    public let platform = MusicPlatform.migu
    let transport: MusicTransport
    static let pageSize = 20
    static let timeout: TimeInterval = 6
    /// The Android app's device ID and signing constants, as its search requests carry them.
    static let deviceID = "963B7AA0D21511ED807EE5846EC87D20"
    static let signing = "6cdc72a439cef99a3418d2a78aa28c73yyapp2d16148780a1dcc7408e06336b98cfd50"
    static let appAgent = "Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30"
    public init(transport: MusicTransport = URLSessionMusicTransport()) { self.transport = transport }

    public func search(_ query: String, page: Int) async throws -> [MusicTrack] {
        // The signed app catalog includes duration as well as both recording identifiers.
        // The older public catalog remains useful when that endpoint is temporarily unavailable.
        do { return try await signedSearch(query, page: page) }
        catch {
            try Task.checkCancellation()
            if MusicProviderError(error) == .cancelled { throw error }
            return try Self.parse(try await publicSearch(query, type: "song", page: page))
        }
    }

    private func signedSearch(_ query: String, page: Int) async throws -> [MusicTrack] {
        let time = String(Int(Date().timeIntervalSince1970 * 1000))
        let sign = Insecure.MD5.hash(data: Data((query + Self.signing + Self.deviceID + time).utf8)).map { String(format: "%02x", $0) }.joined()
        let url = MusicHTTP.url("https://jadeite.migu.cn/music_search/v3/search/searchAll", [
            ("isCorrect", "0"), ("isCopyright", "1"),
            ("searchSwitch", #"{"song":1,"album":0,"singer":0,"tagSong":1,"mvSong":0,"bestShow":1,"songlist":0,"lyricSong":0}"#),
            ("pageSize", String(Self.pageSize)), ("text", query), ("pageNo", String(max(1, page))), ("sort", "0"), ("sid", "USS"),
        ])
        let request = MusicHTTP.request(url, timeout: Self.timeout, headers: [
            "uiVersion": "A_music_3.6.1", "deviceId": Self.deviceID, "timestamp": time, "sign": sign, "channel": "0146921",
            "User-Agent": Self.appAgent,
        ])
        return try Self.parse(try await MusicHTTP.json(transport, request, timeout: Self.timeout))
    }

    static func parse(_ json: JSONValue) throws -> [MusicTrack] {
        guard json["code"]?.string == "000000" else {
            throw MusicProviderError.invalidResponse("Migu search code \(json["code"]?.string ?? "-")")
        }
        // The signed endpoint groups other versions; the public endpoint uses flat result rows.
        guard let rows = json[path: "songResultData", "result"]?.array ?? json[path: "songResultData", "resultList"]?.array
                ?? json["musics"]?.array ?? json[path: "data", "songsData", "items"]?.array else {
            if json[path: "songResultData", "totalCount"]?.int == 0 { return [] }
            throw MusicProviderError.invalidResponse("Migu search has no song list")
        }
        return rows.flatMap { $0.array ?? [$0] }.compactMap(track)
    }

    static func track(_ song: JSONValue) -> MusicTrack? {
        guard let copyright = MusicCatalogData.text(song, "copyrightId", "copyrightid"),
              let title = (song["name"]?.string ?? song["songName"]?.string).map(MusicText.plain), !title.isEmpty else { return nil }
        let content = MusicCatalogData.text(song, "contentId")
        let recording = song["songId"] ?? song["id"]
        let artists = MusicCatalogData.artists(song["singerList"] ?? song["singers"] ?? song["singer"] ?? song["singerName"])
        let album = song["albums"]?.array?.first
        let picture = MusicCatalogData.text(song, "img3", "img2", "img1", "cover", "coverUrl", "picL", "picM")
            ?? song["imgItems"]?.array?.first?["img"]?.string ?? song["albumImgs"]?.array?.first?["img"]?.string
        var track = MusicTrack(platform: .migu, songID: content.map { $0 + "_" + copyright } ?? copyright, title: title, artists: artists,
                               album: MusicCatalogData.text(song, "album", "albumName") ?? album?["name"]?.string,
                               duration: MusicCatalogData.duration(song["duration"]),
                               artwork: MusicCatalogData.artwork(picture, base: "https://d.musicapp.migu.cn/"))
        var info = MusicCatalogData.info(track, songmid: recording ?? .string(copyright))
        info["songId"] = recording ?? .string(copyright); info["copyrightId"] = .string(copyright)
        info["contentId"] = content.map(JSONValue.string)
        info["albumId"] = song["albumId"] ?? song["albumid"] ?? album?["id"]
        for key in ["lyricUrl", "lrcUrl", "trcUrl", "mrcUrl"] {
            if let value = MusicCatalogData.publicMetadataURL(song[key]?.string) { info[key] = .string(value) }
        }
        var types: [String: JSONValue] = [:]
        for format in song["audioFormats"]?.array ?? song["newRateFormats"]?.array ?? song["rateFormats"]?.array ?? [] {
            let type: String?
            switch format["formatType"]?.string {
            case "PQ": type = "128k"
            case "HQ": type = "320k"
            case "SQ": type = "flac"
            case "ZQ", "ZQ24": type = "flac24bit"
            default: type = nil
            }
            if let type {
                var fields: [String: JSONValue] = [:]
                if let size = format["asize"] ?? format["androidSize"] ?? format["size"] { fields["size"] = size }
                if let code = format["aformat"] ?? format["androidFormat"] ?? format["format"] { fields["format"] = code }
                types[type] = .object(fields)
            }
        }
        MusicCatalogData.qualityFields(types, in: &info)
        track.setLXInfo(info, for: .migu)
        return track
    }

    /// The two IDs in a Migu song ID.
    static func ids(_ songID: String) -> (content: String, copyright: String)? {
        let parts = songID.split(separator: "_", maxSplits: 1).map(String.init)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty ? (parts[0], parts[1]) : nil
    }
}

/// Migu's own playback addresses, as its web player asks for them. The answer names the 128 kbps
/// file; the same song's FLAC and 320 kbps files sit at sibling paths on the same server, so
/// those are tried first, each confirmed with a HEAD request.
public struct MiguProvider: MusicStreamProvider {
    public let id = MusicProviderID.migu
    public let platforms: Set<MusicPlatform> = [.migu]
    let transport: MusicTransport
    static let timeout: TimeInterval = 8
    static let checkTimeout: TimeInterval = 4
    /// The key the web player's answers are scrambled with.
    static let key = Array("Jk8qzuePiJ1qE3mDYhLQ3T73DtDoAhLP".utf8)
    /// Path and extension of each tier, best first; the answer is always the last.
    static let tiers: [(name: String, path: String, ext: String)] = [
        ("SQ", "歌曲下载/flac", ".flac"), ("HQ", "标清高清/MP3_320_16_Stero", ".mp3"), ("PQ", "标清高清/MP3_128_16_Stero", ".mp3"),
    ]
    public init(transport: MusicTransport = URLSessionMusicTransport()) { self.transport = transport }

    public func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        guard let ids = MiguMusicCatalog.ids(songID) else { throw MusicProviderError.noResource }
        let url = MusicHTTP.url("https://c.musicapp.migu.cn/strategy/listen-url/h5/v2.4", [
            ("contentId", ids.content), ("copyrightId", ids.copyright), ("resourceType", "2"), ("netType", "01"),
            ("toneFlag", "PQ"), ("scene", ""), ("lowerQualityContentId", ids.content),
        ])
        let request = MusicHTTP.request(url, timeout: Self.timeout, headers: [
            "birth": "h5page", "channel": "014X031", "Referer": "https://y.migu.cn/", "location-data": "30.6698676660,104.1229614820",
        ])
        let response = try await MusicHTTP.withTimeout(Self.timeout) { try await transport.send(request, limit: MusicHTTP.jsonLimit) }
        guard (200..<300).contains(response.status) else { throw MusicProviderError.invalidResponse("Migu HTTP \(response.status)") }
        let base = try Self.address(Self.unscramble(response.body))
        // The answer is always PQ; the tiers above it are sibling paths, each confirmed first.
        for tier in Self.tiers(for: quality) {
            guard let better = Self.retone(base, to: tier.name), await exists(better) else { continue }
            return ResolvedMusicStream(url: better, claimedQuality: tier.name, upstream: "migu")
        }
        return ResolvedMusicStream(url: base, claimedQuality: "PQ", upstream: "migu")
    }

    /// The tiers above PQ to try: lossless falls back to 320 kbps, High asks for 320 kbps, and
    /// Standard keeps the 128 kbps answer.
    static func tiers(for quality: MusicAudioQuality) -> [(name: String, path: String, ext: String)] {
        switch quality {
        case .lossless: Array(tiers.dropLast())
        case .high: [tiers[1]]
        case .standard: []
        }
    }

    private func exists(_ url: URL) async -> Bool {
        var head = MusicHTTP.request(url, timeout: Self.checkTimeout)
        head.httpMethod = "HEAD"
        let request = head
        let response = try? await MusicHTTP.withTimeout(Self.checkTimeout) { try await transport.send(request, limit: 0) }
        return response.map { (200..<400).contains($0.status) } ?? false
    }

    /// The web player's answer: "AB CD 01", an offset byte, then JSON with each byte shifted by
    /// the offset less a key byte.
    static func unscramble(_ data: Data) throws -> JSONValue {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xAB, bytes[1] == 0xCD, bytes[2] == 0x01 else {
            throw MusicProviderError.invalidResponse("Migu answer format")
        }
        let offset = Int(bytes[3])
        let plain = bytes.dropFirst(4).enumerated().map { index, byte in
            UInt8((Int(byte) + offset - Int(key[index % key.count]) + 512) % 256)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(plain)) else {
            throw MusicProviderError.invalidResponse("Migu answer not JSON")
        }
        return json
    }

    static func address(_ json: JSONValue) throws -> URL {
        guard json["code"]?.string == "000000" else {
            // A song Migu holds no rights to here answers with a message instead of an address.
            throw MusicProviderError.noResource
        }
        guard var text = json[path: "data", "url"]?.string ?? json[path: "data", "playUrl"]?.string, !text.isEmpty else {
            throw MusicProviderError.noResource
        }
        if text.hasPrefix("//") { text = "https:" + text }
        guard let url = URL(string: text.replacingOccurrences(of: "+", with: "%2B")), url.host() != nil else {
            throw MusicProviderError.noResource
        }
        return url
    }

    /// The address of another tier of the same file: the tier's folder and extension, without the
    /// 128 kbps answer's signature, which the other tiers do not need.
    static func retone(_ url: URL, to name: String) -> URL? {
        guard let source = tiers.last, let target = tiers.first(where: { $0.name == name }),
              let sourcePath = source.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let targetPath = target.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let bare = url.absoluteString.components(separatedBy: "?")[0]
        guard bare.contains(sourcePath), bare.hasSuffix(source.ext) else { return nil }
        return URL(string: String(bare.replacingOccurrences(of: sourcePath, with: targetPath).dropLast(source.ext.count)) + target.ext)
    }
}

/// Kuwo's own search, as its Android app asks it.
public struct KuwoMusicCatalog: MusicCatalogSource {
    public let platform = MusicPlatform.kuwo
    let transport: MusicTransport
    static let pageSize = 20
    static let timeout: TimeInterval = 6
    public init(transport: MusicTransport = URLSessionMusicTransport()) { self.transport = transport }

    public func search(_ query: String, page: Int) async throws -> [MusicTrack] {
        let url = MusicHTTP.url("https://search.kuwo.cn/r.s", [
            ("client", "kt"), ("all", query), ("pn", String(max(1, page) - 1)), ("rn", String(Self.pageSize)), ("uid", "2574109560"),
            ("ver", "kwplayer_ar_8.5.4.2"), ("vipver", "1"), ("ft", "music"), ("cluster", "0"), ("strategy", "2012"),
            ("encoding", "utf8"), ("rformat", "json"), ("vermerge", "1"), ("mobi", "1"),
        ])
        return try Self.parse(try await kuwoJSON(url))
    }

    static func parse(_ json: JSONValue) throws -> [MusicTrack] {
        guard let songs = json["abslist"]?.array ?? json[path: "data", "list"]?.array else {
            if json["TOTAL"]?.int == 0 { return [] }
            throw MusicProviderError.invalidResponse("Kuwo search: no list")
        }
        return songs.compactMap(track)
    }

    static func track(_ song: JSONValue) -> MusicTrack? {
        guard let rid = MusicCatalogData.text(song, "MUSICRID", "musicrid", "rid", "id"),
              case let id = rid.replacingOccurrences(of: "MUSIC_", with: ""), !id.isEmpty,
              let title = MusicCatalogData.text(song, "NAME", "SONGNAME", "name", "songname").map(MusicText.plain), !title.isEmpty else { return nil }
        let artists = MusicCatalogData.artists(song["ARTIST"] ?? song["artist"])
        let picture = MusicCatalogData.text(song, "albumpic", "hts_albumpic", "web_albumpic_short", "pic", "pic120", "img", "PICPATH")?
            .replacingOccurrences(of: "/120/", with: "/500/")
        let cover = MusicCatalogData.artwork(picture?.hasPrefix("120/") == true ? "500/" + String(picture!.dropFirst(4)) : picture,
                                            base: "https://img4.kuwo.cn/star/albumcover/")
        var track = MusicTrack(platform: .kuwo, songID: id, title: title, artists: artists,
                               album: MusicCatalogData.text(song, "ALBUM", "album").map(MusicText.plain),
                               duration: MusicCatalogData.duration(song["DURATION"] ?? song["duration"]), artwork: cover)
        var info = MusicCatalogData.info(track, songmid: .string(id))
        info["songId"] = .string(id); info["albumId"] = song["ALBUMID"] ?? song["albumid"] ?? song["albumId"]
        let formats = (MusicCatalogData.text(song, "FORMATS", "formats", "format") ?? "").uppercased()
        var types: [String: JSONValue] = [:]
        for (type, marker) in [("128k", "MP3"), ("320k", "MP3H"), ("flac", "ALFLAC"), ("flac24bit", "HIRFLAC")] where formats.contains(marker) {
            types[type] = .object([:])
        }
        MusicCatalogData.qualityFields(types, in: &info)
        track.setLXInfo(info, for: .kuwo)
        return track
    }
}
