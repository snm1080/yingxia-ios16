import CommonCrypto
import CryptoKit
import Foundation

extension KuwoMusicCatalog: MusicCollectionSource, MusicBrowseSource {
    static let chartPrefix = "toplist:"

    public func searchCollections(_ query: String, kind: MusicCollection.Kind, page: Int) async throws -> [MusicCollection] {
        let json = try await kuwoJSON(MusicHTTP.url("https://search.kuwo.cn/r.s", [
            ("all", query), ("pn", String(max(1, page) - 1)), ("rn", String(Self.pageSize)), ("ft", kind.rawValue),
            ("rformat", "json"), ("encoding", "utf8"), ("client", "kt"), ("vipver", "MUSIC_9.1.1.2_BCS2"),
        ]))
        guard let rows = json[kind == .album ? "albumlist" : "abslist"]?.array else {
            if json["total"]?.int == 0 || json["TOTAL"]?.int == 0 { return [] }
            throw MusicProviderError.invalidResponse("Kuwo search has no collection list")
        }
        return rows.compactMap { Self.collection($0, kind: kind) }
    }

    static func collection(_ row: JSONValue, kind: MusicCollection.Kind) -> MusicCollection? {
        let id = kind == .album ? MusicCatalogData.text(row, "albumid", "id") : MusicCatalogData.text(row, "playlistid", "id")
        guard let id, let title = MusicCatalogData.text(row, "name", "title") else { return nil }
        return MusicCollection(kind: kind, platform: .kuwo, collectionID: id, title: MusicText.plain(title),
                               subtitle: MusicCatalogData.text(row, "artist", "nickname").map(MusicText.plain),
                               artwork: MusicCatalogData.artwork(MusicCatalogData.text(row, "hts_img", "hts_pic", "img", "pic"),
                                                                 base: "https://img4.kuwo.cn/star/albumcover/"),
                               trackCount: row["musicnum"]?.int ?? row["musiccnt"]?.int ?? row["songnum"]?.int,
                               year: row["pub"]?.string.map { String($0.prefix(4)) })
    }

    public func tracks(of collection: MusicCollection) async throws -> [MusicTrack] {
        let chart = collection.collectionID.hasPrefix(Self.chartPrefix)
        let id = chart ? String(collection.collectionID.dropFirst(Self.chartPrefix.count)) : collection.collectionID
        try MusicCatalogData.validID(id)
        return try await MusicCollections.loadPages { page, _ in
            let json: JSONValue
            if chart { json = try await chartPage(id, page: page) }
            else if collection.kind == .album {
                json = try await kuwoJSON(MusicHTTP.url("https://search.kuwo.cn/r.s", [
                    ("stype", "albuminfo"), ("albumid", id), ("pn", String(page - 1)), ("rn", "100"),
                    ("encoding", "utf8"), ("vipver", "MUSIC_9.1.0"),
                ]))
            } else {
                // The anonymous playlist catalog is the provider's legacy HTTP service.
                json = try await kuwoJSON(MusicHTTP.url("http://nplserver.kuwo.cn/pl.svc", [
                    ("op", "getlistinfo"), ("pid", id), ("pn", String(page - 1)), ("rn", "100"), ("encode", "utf8"),
                    ("keyset", "pl2012"), ("identity", "kuwo"), ("pcmp4", "1"), ("vipver", "MUSIC_9.0.5.0_W1"), ("newver", "1"),
                ]))
            }
            return try MusicCollectionPage(rows: json["musiclist"]?.array,
                                           total: json["total"]?.int ?? json["totalnum"]?.int ?? json["songnum"]?.int,
                                           parse: Self.track)
        }
    }

    public func browseSections() async throws -> [MusicBrowseSection] {
        let json = try await kuwoJSON(URL(string: "https://wapi.kuwo.cn/api/pc/bang/list")!)
        func charts(_ rows: [JSONValue]) -> [MusicCollection] {
            rows.flatMap { row in
                var result: [MusicCollection] = []
                if let id = MusicCatalogData.text(row, "sourceid"), let name = row["name"]?.string {
                    result.append(.init(kind: .playlist, platform: .kuwo, collectionID: Self.chartPrefix + id,
                                        title: MusicText.plain(name), artwork: MusicCatalogData.artwork(MusicCatalogData.text(row, "pic2", "pic"))))
                }
                result += charts(row["child"]?.array ?? [])
                return result
            }
        }
        var seen = Set<String>()
        let lists = charts(json["child"]?.array ?? []).filter { seen.insert($0.id).inserted }
        guard !lists.isEmpty else { throw MusicProviderError.invalidResponse("Kuwo browse has no charts") }
        return [.init(id: MusicBrowse.charts, title: MusicBrowse.title(MusicBrowse.charts), collections: lists)]
    }

    func kuwoJSON(_ url: URL) async throws -> JSONValue {
        let request = MusicHTTP.request(url, timeout: Self.timeout, headers: ["Referer": "https://www.kuwo.cn/"])
        let json = try await MusicHTTP.json(transport, request, timeout: Self.timeout, limit: 8 * 1024 * 1024)
        if let result = json["result"]?.string, result != "ok" && result != "succ" {
            throw MusicProviderError.invalidResponse("Kuwo catalog failed")
        }
        return json
    }

    /// Kuwo's current chart API wraps JSON using its public SDK constants. Chart songs carry
    /// each recording's artwork in this response, avoiding a shared chart poster on every track.
    private func chartPage(_ id: String, page: Int) async throws -> JSONValue {
        let payload: [String: Any] = ["uid": "", "devId": "", "sFrom": "kuwo_sdk", "user_type": "AP",
                                      "carSource": "kwplayercar_ar_6.0.1.0_apk_keluze.apk", "id": id, "pn": page - 1, "rn": 100]
        let encrypted = try Self.chartCrypt(JSONSerialization.data(withJSONObject: payload), encrypt: true).base64EncodedString()
        let time = String(Int(Date().timeIntervalSince1970 * 1000)), appID = "y67sprxhhpws"
        let sign = Insecure.MD5.hash(data: Data((appID + encrypted + time).utf8)).map { String(format: "%02X", $0) }.joined()
        let url = MusicHTTP.url("https://wbd.kuwo.cn/api/bd/bang/bang_info", [
            ("data", encrypted), ("time", time), ("appId", appID), ("sign", sign),
        ])
        let request = MusicHTTP.request(url, timeout: Self.timeout, headers: ["Referer": "https://www.kuwo.cn/"])
        let response = try await MusicHTTP.withTimeout(Self.timeout) { try await transport.send(request, limit: 8 * 1024 * 1024) }
        guard response.status == 200, !response.truncated,
              let text = String(data: response.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = Data(base64Encoded: text.removingPercentEncoding ?? text) else {
            throw MusicProviderError.invalidResponse("Kuwo chart response unavailable")
        }
        let json = try MusicHTTP.decodeJSON(Self.chartCrypt(data, encrypt: false))
        guard json["code"]?.int == 200, let result = json["data"] else { throw MusicProviderError.invalidResponse("Kuwo chart unavailable") }
        return result
    }

    static func chartCrypt(_ data: Data, encrypt: Bool) throws -> Data {
        let key: [UInt8] = [0x70, 0x57, 0x27, 0x3d, 0xc7, 0xfa, 0x29, 0xbf, 0x39, 0x44, 0x2d, 0x72, 0xdd, 0x5e, 0x8c, 0xe4]
        let capacity = data.count + kCCBlockSizeAES128
        var output = Data(count: capacity), moved = 0
        let status = output.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { secret in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), secret.baseAddress, key.count, nil,
                            input.baseAddress, data.count, target.baseAddress, capacity, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw MusicProviderError.invalidResponse("Kuwo chart envelope invalid") }
        output.count = moved
        return output
    }
}
