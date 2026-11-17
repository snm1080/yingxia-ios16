import Foundation

/// Field differences between public catalog endpoints belong here, before a recording is handed
/// to an imported source. Only catalog identifiers and public metadata are persisted.
enum MusicCatalogData {
    static func text(_ value: JSONValue, _ keys: String...) -> String? {
        keys.lazy.compactMap { value[$0]?.string }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func duration(_ value: JSONValue?) -> Double? {
        if let number = value?.double { return number > 0 ? number : nil }
        guard let text = value?.string, text.contains(":") else { return nil }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == text.split(separator: ":").count else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        return seconds > 0 ? seconds : nil
    }

    static func artists(_ value: JSONValue?) -> [String] {
        if let rows = value?.array {
            return rows.compactMap { row in
                let name = row.string ?? text(row, "name", "singerName", "author_name")
                return name.map(MusicText.plain).flatMap { $0.isEmpty ? nil : $0 }
            }
        }
        guard let value else { return [] }
        guard let name = value.string ?? text(value, "name", "singerName") else { return [] }
        return MusicText.plain(name).components(separatedBy: CharacterSet(charactersIn: "&、"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func artwork(_ value: String?, base: String? = nil) -> URL? {
        guard var text = value, !text.isEmpty else { return nil }
        text = MusicText.entities(text).replacingOccurrences(of: "{size}", with: "500", options: .caseInsensitive)
            .replacingOccurrences(of: "%7Bsize%7D", with: "500", options: .caseInsensitive)
        if text.hasPrefix("//") { text = "https:" + text }
        else if !text.hasPrefix("http"), let base { text = base + (text.hasPrefix("/") ? String(text.dropFirst()) : text) }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func info(_ track: MusicTrack, songmid: JSONValue) -> [String: JSONValue] {
        var result: [String: JSONValue] = ["songmid": songmid, "name": .string(track.title),
                                         "singer": .string(track.artistLine)]
        if let album = track.album { result["albumName"] = .string(album) }
        if let duration = track.duration { result["interval"] = .number(duration) }
        if let artwork = track.artwork { result["img"] = .string(artwork.absoluteString) }
        return result
    }

    static func qualityFields(_ types: [String: JSONValue], in info: inout [String: JSONValue]) {
        guard !types.isEmpty else { return }
        info["_types"] = .object(types)
        info["types"] = .array(["128k", "320k", "flac", "flac24bit"].compactMap { type in
            guard var fields = types[type]?.object else { return nil }
            fields["type"] = .string(type)
            return .object(fields)
        })
    }

    /// Lyrics returned in a public catalog may be saved; authenticated stream URLs never are.
    static func publicMetadataURL(_ value: String?) -> String? {
        guard let url = artwork(value), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let sensitive = ["token", "sign", "auth", "key", "cookie", "credential", "expires"]
        guard !(parts.queryItems ?? []).contains(where: { item in sensitive.contains { item.name.lowercased().contains($0) } }) else { return nil }
        return url.absoluteString
    }

    static func validID(_ id: String) throws {
        guard !id.isEmpty, id.count <= 100, id.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }) else { throw MusicProviderError.invalidResponse("invalid collection identifier") }
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        if case .bool(let result) = value { return result }
        switch value.string?.lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }
}

struct MusicCollectionPage: Sendable {
    var tracks: [MusicTrack]
    var total: Int?
    var hasMore: Bool? = nil

    init(rows: [JSONValue]?, total: Int?, hasMore: Bool? = nil, parse: (JSONValue) -> MusicTrack?) throws {
        guard let rows else { throw MusicProviderError.invalidResponse("collection has no track list") }
        let tracks = rows.compactMap(parse)
        guard tracks.count == rows.count else { throw MusicProviderError.invalidResponse("collection has incomplete track metadata") }
        self.tracks = tracks; self.total = total; self.hasMore = hasMore
    }
}

extension MusicCollections {
    /// Offset-based APIs get the accepted row count; page-based APIs get the next page even if
    /// the server imposes a smaller page size. A partial or repeated page never replaces a queue.
    static func loadPages(_ fetch: @Sendable (Int, Int) async throws -> MusicCollectionPage) async throws -> [MusicTrack] {
        var tracks: [MusicTrack] = [], knownTotal: Int?, signatures = Set<[String]>()
        for page in 1...trackLimit {
            try Task.checkCancellation()
            let response = try await fetch(page, tracks.count)
            if let total = response.total {
                guard total >= 0, total <= trackLimit else { throw MusicProviderError.invalidResponse("collection exceeds \(trackLimit) tracks") }
                if let knownTotal, knownTotal != total { throw MusicProviderError.invalidResponse("collection size changed during loading") }
                knownTotal = total
            }
            guard knownTotal != nil || response.hasMore != nil else {
                throw MusicProviderError.invalidResponse("collection did not provide pagination metadata")
            }
            if !response.tracks.isEmpty {
                guard signatures.insert(response.tracks.map(\.id)).inserted else {
                    throw MusicProviderError.invalidResponse("collection repeated a track page")
                }
                tracks += response.tracks
                guard tracks.count <= trackLimit else { throw MusicProviderError.invalidResponse("collection exceeds \(trackLimit) tracks") }
            }
            let finished = response.hasMore == false || knownTotal.map { tracks.count >= $0 } == true
            if finished {
                guard knownTotal.map({ $0 == tracks.count }) ?? true, response.hasMore != true else {
                    throw MusicProviderError.invalidResponse("collection returned incomplete pagination")
                }
                return tracks
            }
            guard !response.tracks.isEmpty else { throw MusicProviderError.invalidResponse("collection ended before its advertised total") }
        }
        throw MusicProviderError.invalidResponse("collection exceeded page limit")
    }
}
