import Foundation
import CoreFoundation

public struct MusicLyricLine: Hashable, Codable, Sendable {
    /// Seconds from the start; 0 for every line of unsynced lyrics.
    public var time: Double
    /// Empty for an instrumental gap.
    public var text: String
    public var translation: String?
    public var romanization: String?
}

/// A song's lyrics, timed when the catalog has an LRC file, with a translation per line when it has one.
public struct MusicLyrics: Hashable, Codable, Sendable {
    public var lines: [MusicLyricLine]
    public var synced: Bool
    /// Where they came from; timing fits that catalog's recording.
    public var platform: MusicPlatform

    /// The line being sung at `time`: the last line starting at or before it.
    public func index(at time: Double) -> Int? {
        guard synced, let first = lines.first, time >= first.time else { return nil }
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].time <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private static let stamp = try! NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]")
    private static let tag = try! NSRegularExpression(pattern: "^\\[([a-zA-Z#]+):([^\\]]*)\\]\\s*$")

    /// Parses LRC text: one or more `[mm:ss.xx]` stamps per line, an `[offset:ms]` tag, metadata
    /// tags skipped. Text without stamps becomes unsynced lyrics. Nil when there are no words.
    public static func parse(_ lrc: String, translation: String? = nil, romanization: String? = nil, platform: MusicPlatform) -> MusicLyrics? {
        guard let normalized = MusicLyricPayload.text(.string(lrc)), !MusicLyricPayload.isURL(normalized) else { return nil }
        let (timed, plain, offset) = lines(of: normalized)
        if timed.isEmpty {
            let text = plain.filter { !$0.isEmpty }
            return text.isEmpty ? nil : MusicLyrics(lines: text.map { MusicLyricLine(time: 0, text: $0) }, synced: false, platform: platform)
        }
        var result = timed.map { MusicLyricLine(time: max(0, $0.time - offset), text: $0.text) }
            .enumerated().sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }.map(\.element)
        guard result.contains(where: { !$0.text.isEmpty }) else { return nil }
        func aligned(_ text: String?) -> [Int: String] {
            guard let text, let normalized = MusicLyricPayload.text(.string(text)), !MusicLyricPayload.isURL(normalized) else { return [:] }
            let (translated, _, ownOffset) = lines(of: normalized)
            // A companion without an offset follows the original file's offset. An explicit
            // companion offset belongs to its own timeline and must not be subtracted twice.
            let translatedOffset = normalized.range(of: #"\[offset\s*:"#, options: [.regularExpression, .caseInsensitive]) == nil ? offset : ownOffset
            let usable = translated.filter { !$0.text.isEmpty && $0.text != "//" }.map { (time: max(0, $0.time - translatedOffset), text: $0.text) }
            var matches: [Int: String] = [:]
            for index in result.indices where !result[index].text.isEmpty {
                let time = result[index].time
                if let match = usable.min(by: { abs($0.time - time) < abs($1.time - time) }), abs(match.time - time) < 0.35,
                   match.text != result[index].text {
                    matches[index] = match.text
                }
            }
            return matches
        }
        for (index, text) in aligned(translation) { result[index].translation = text }
        for (index, text) in aligned(romanization) { result[index].romanization = text }
        // Catalogs open with the title and credits as timed lines ("晴天 - 周杰伦", "词：周杰伦",
        // "编曲 : …"); they are not sung, so they go. Only the opening run: a sung line ends it.
        if let firstSung = result.firstIndex(where: { !isCredit($0.text) }), firstSung > 0 {
            result.removeFirst(firstSung)
        }
        // Repeated empty stamps add nothing.
        result = result.enumerated().filter { $0.offset == 0 || !($0.element.text.isEmpty && result[$0.offset - 1].text.isEmpty) }.map(\.element)
        return MusicLyrics(lines: result, synced: true, platform: platform)
    }

    private static let creditLine = try! NSRegularExpression(pattern: "^[^：:]{1,16}\\s*[：:]")

    /// A title line ("Song - Artist"), a credit ("Role: Name"), or an empty stamp.
    static func isCredit(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.contains(" - ") { return true }
        return creditLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func lines(of lrc: String) -> (timed: [(time: Double, text: String)], plain: [String], offset: Double) {
        var timed: [(time: Double, text: String)] = [], plain: [String] = [], offset = 0.0
        for raw in lrc.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            // YRC/KRC use millisecond line stamps and per-word timing. The player currently
            // highlights whole lines, so keep their real start time and strip only word stamps.
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: #"^\[\d+,\d+\]"#, options: .regularExpression) {
                let numbers = line[range].dropFirst().dropLast().split(separator: ",")
                if let first = numbers.first, let milliseconds = Double(first), milliseconds.isFinite, milliseconds >= 0, milliseconds < 604_800_000 {
                    let words = String(line[range.upperBound...]).replacingOccurrences(of: #"(?:<\d+,\d+(?:,\d+)?>|\(\d+,\d+(?:,\d+)?\))"#, with: "", options: .regularExpression)
                    line = String(format: "[%02d:%06.3f]", Int(milliseconds / 60000), milliseconds.truncatingRemainder(dividingBy: 60000) / 1000) + words
                } else { continue }
            }
            let range = NSRange(line.startIndex..., in: line)
            if let match = tag.firstMatch(in: line, range: range), let name = Range(match.range(at: 1), in: line), let value = Range(match.range(at: 2), in: line) {
                if line[name].lowercased() == "offset", let milliseconds = Double(line[value].trimmingCharacters(in: .whitespaces)), milliseconds.isFinite, abs(milliseconds) < 604_800_000 { offset = milliseconds / 1000 }
                continue
            }
            var times: [Double] = [], end = line.startIndex
            for match in stamp.matches(in: line, range: range) {
                guard let whole = Range(match.range, in: line), whole.lowerBound == end,
                      let minutes = Range(match.range(at: 1), in: line).flatMap({ Double(line[$0]) }),
                      let seconds = Range(match.range(at: 2), in: line).flatMap({ Double(line[$0]) }) else { break }
                var fraction = 0.0
                if let digits = Range(match.range(at: 3), in: line).map({ String(line[$0]) }), let value = Double(digits) {
                    fraction = value / pow(10, Double(digits.count))
                }
                times.append(minutes * 60 + seconds + fraction)
                end = whole.upperBound
            }
            let text = String(line[end...]).trimmingCharacters(in: .whitespaces)
            if times.isEmpty { plain.append(text) } else { timed += times.map { (time: $0, text: text) } }
        }
        return (timed, plain, offset)
    }
}

/// Lyrics returned by catalog endpoints or imported sources. Keep companions separate until
/// they are aligned to the original recording; an address is fetched, never displayed as text.
struct MusicLyricPayload: Sendable {
    var lyric: String
    var translation: String?
    var romanization: String?

    static func parse(_ value: JSONValue, depth: Int = 0) -> MusicLyricPayload? {
        guard depth < 6 else { return nil }
        if let object = value.object {
            func first(_ keys: [String]) -> String? { keys.compactMap { object[$0].flatMap { text($0) } }.first { !$0.isEmpty } }
            let translation = first(["tlyric", "translation", "trans", "tlrc", "tLrc", "translationLyric"])
            let romanization = first(["rlyric", "romanization", "romalrc", "roma", "rlrc", "rLrc"])
            if let lyric = first(["lyric", "lyrics", "lrc", "lyricText", "lrclist", "content", "text", "lyricUrl", "lrcUrl", "url"]) {
                return MusicLyricPayload(lyric: lyric, translation: translation, romanization: romanization)
            }
            for key in ["data", "result", "body"] {
                if let inner = object[key], var parsed = parse(inner, depth: depth + 1) {
                    parsed.translation = translation ?? parsed.translation
                    parsed.romanization = romanization ?? parsed.romanization
                    return parsed
                }
            }
            return nil
        }
        guard let lyric = text(value, depth: depth) else { return nil }
        return MusicLyricPayload(lyric: lyric)
    }

    static func isURL(_ text: String) -> Bool {
        text.range(of: #"^(?:https?:)?//\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func text(_ value: JSONValue, depth: Int = 0) -> String? {
        guard depth < 6 else { return nil }
        if let object = value.object {
            for key in ["lyric", "lyrics", "lrc", "text", "content", "lrclist", "data", "result", "url"] {
                if let inner = object[key], let text = text(inner, depth: depth + 1) { return text }
            }
            return nil
        }
        if let array = value.array {
            let lines = array.compactMap { item -> String? in
                if item["time"] != nil || item["t"] != nil {
                    guard let time = (item["time"] ?? item["t"])?.double, time.isFinite, time >= 0, time < 604_800,
                          let words = (item["lineLyric"] ?? item["text"] ?? item["words"])?.string else { return nil }
                    return String(format: "[%02d:%06.3f]", Int(time / 60), time.truncatingRemainder(dividingBy: 60)) + words
                }
                return text(item, depth: depth + 1)
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        guard case .string(let raw) = value, raw.utf8.count <= 2_000_000 else { return nil }
        var string = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard !string.isEmpty else { return nil }
        if let nested = try? JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)), nested != value {
            return text(nested, depth: depth + 1)
        }
        if string.count >= 12, !string.contains("["),
           let data = Data(base64Encoded: string.filter { !$0.isWhitespace }),
           let decoded = decode(data), decoded.contains("[") || decoded.contains("\n") {
            return text(.string(decoded), depth: depth + 1)
        }
        if !string.contains("\n"), string.contains("\\n") { string = string.replacingOccurrences(of: "\\r\\n", with: "\n").replacingOccurrences(of: "\\n", with: "\n") }
        string = MusicText.entities(string)
        let entity = try! NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|[0-9]+);"#)
        for match in entity.matches(in: string, range: NSRange(string.startIndex..., in: string)).reversed() {
            guard let digits = Range(match.range(at: 1), in: string), let whole = Range(match.range, in: string) else { continue }
            let raw = String(string[digits]), hex = raw.hasPrefix("x")
            if let number = UInt32(hex ? String(raw.dropFirst()) : raw, radix: hex ? 16 : 10), let scalar = UnicodeScalar(number) {
                string.replaceSubrange(whole, with: String(scalar))
            }
        }
        guard string.range(of: #"<(?:!doctype\s+html|html|head|body|script)\b"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        // An unrecognized JSON/error envelope is not a plain lyric.
        if string.hasPrefix("{"), string.hasSuffix("}") { return nil }
        return string
    }

    static func decode(_ data: Data, contentType: String? = nil) -> String? {
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        let charset = contentType?.lowercased().components(separatedBy: "charset=").last?.trimmingCharacters(in: CharacterSet(charactersIn: " \"';"))
        let encoding: String.Encoding
        switch charset {
        case "utf-16", "utf-16le": encoding = .utf16LittleEndian
        case "utf-16be": encoding = .utf16BigEndian
        case "gbk", "gb2312", "gb18030": encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5": encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        default: encoding = .utf8
        }
        return String(data: data, encoding: encoding)
    }

    func loaded(transport: MusicTransport, platform: MusicPlatform, headers: [String: String] = [:]) async throws -> MusicLyrics? {
        func load(_ text: String?) async throws -> String? {
            guard let text else { return nil }
            guard Self.isURL(text) else { return text }
            let address = text.hasPrefix("//") ? "https:" + text : text
            guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            let response = try await MusicHTTP.withTimeout(6) { try await transport.send(MusicHTTP.request(url, timeout: 6, headers: headers), limit: 1_000_001) }
            guard (200..<300).contains(response.status), response.body.count <= 1_000_000,
                  let value = Self.decode(response.body, contentType: response.headers["content-type"]) else { return nil }
            return Self.text(.string(value))
        }
        guard let original = try await load(lyric) else { return nil }
        let translated = try? await load(translation)
        let romanized = try? await load(romanization)
        try Task.checkCancellation()
        return MusicLyrics.parse(original, translation: translated, romanization: romanized, platform: platform)
    }
}

public protocol MusicLyricsSource: Sendable {
    var platform: MusicPlatform { get }
    /// Nil when the catalog has none for the song.
    func lyrics(songID: String) async throws -> MusicLyrics?
    func lyrics(songID: String, track: MusicTrack) async throws -> MusicLyrics?
}

extension MusicLyricsSource {
    public func lyrics(songID: String, track: MusicTrack) async throws -> MusicLyrics? { try await lyrics(songID: songID) }
}

extension QQMusicCatalog: MusicLyricsSource {
    public func lyrics(songID: String) async throws -> MusicLyrics? {
        let url = MusicHTTP.url("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", [("songmid", songID), ("format", "json"), ("nobase64", "1")])
        return Self.parseLyrics(try await MusicHTTP.json(transport, MusicHTTP.request(url, timeout: Self.timeout, headers: ["Referer": "https://y.qq.com/"]), timeout: Self.timeout))
    }

    static func parseLyrics(_ json: JSONValue) -> MusicLyrics? {
        guard (json["retcode"]?.int ?? json["code"]?.int ?? 0) == 0, let payload = MusicLyricPayload.parse(json) else { return nil }
        return MusicLyrics.parse(payload.lyric, translation: payload.translation, romanization: payload.romanization, platform: .qq)
    }
}

extension NeteaseMusicCatalog: MusicLyricsSource {
    public func lyrics(songID: String) async throws -> MusicLyrics? {
        Self.parseLyrics(try await neteaseJSON(MusicHTTP.url("https://music.163.com/api/song/lyric", [("id", songID), ("lv", "-1"), ("tv", "-1"), ("rv", "-1")])))
    }

    static func parseLyrics(_ json: JSONValue) -> MusicLyrics? {
        guard json["nolyric"] != .bool(true), json["uncollected"] != .bool(true),
              let lyric = json[path: "lrc", "lyric"]?.string ?? json[path: "yrc", "lyric"]?.string else { return nil }
        return MusicLyrics.parse(lyric, translation: json[path: "tlyric", "lyric"]?.string ?? json[path: "ytlrc", "lyric"]?.string,
                                 romanization: json[path: "romalrc", "lyric"]?.string ?? json[path: "yromalrc", "lyric"]?.string, platform: .netease)
    }
}

extension KuwoMusicCatalog: MusicLyricsSource {
    public func lyrics(songID: String) async throws -> MusicLyrics? {
        for endpoint in ["https://www.kuwo.cn/openapi/v1/www/lyric/getlyric", "https://m.kuwo.cn/newh5/singles/songinfoandlrc"] {
            try Task.checkCancellation()
            let url = MusicHTTP.url(endpoint, [("musicId", songID)])
            do {
                let json = try await MusicHTTP.json(transport, MusicHTTP.request(url, timeout: 4, headers: ["Referer": "https://www.kuwo.cn/"]), timeout: 4)
                if let found = Self.parseLyrics(json) { return found }
            } catch { try Task.checkCancellation() }
        }
        return nil
    }

    static func parseLyrics(_ json: JSONValue) -> MusicLyrics? {
        guard let payload = MusicLyricPayload.parse(json["data"] ?? json) else { return nil }
        return MusicLyrics.parse(payload.lyric, translation: payload.translation, romanization: payload.romanization, platform: .kuwo)
    }
}

extension KugouMusicCatalog: MusicLyricsSource {
    public func lyrics(songID: String) async throws -> MusicLyrics? {
        try await lyrics(songID: songID, track: MusicTrack(platform: .kugou, songID: songID, title: "", artists: []))
    }

    public func lyrics(songID: String, track: MusicTrack) async throws -> MusicLyrics? {
        let hash = track.lxInfo(for: .kugou)?["hash"]?.string ?? songID
        guard hash.range(of: #"^[a-fA-F0-9]{32}$"#, options: .regularExpression) != nil else { return nil }
        let headers = ["Referer": "https://www.kugou.com/"]
        var query = [("ver", "1"), ("man", "yes"), ("client", "pc"), ("hash", hash)]
        if let duration = track.duration, duration.isFinite, duration > 0, duration < 604_800 { query.append(("duration", String(Int(duration * 1000)))) }
        let search = try await MusicHTTP.json(transport, MusicHTTP.request(MusicHTTP.url("https://lyrics.kugou.com/search", query), timeout: 4, headers: headers), timeout: 4)
        // This search is bound to the recording's file hash. Check duration too when the
        // lyric service supplies it; a keyword-only hit must not replace a different version.
        let candidates = (search["candidates"]?.array ?? []).filter { candidate in
            if let foundHash = candidate["hash"]?.string, foundHash.caseInsensitiveCompare(hash) != .orderedSame { return false }
            if let expected = track.duration, let milliseconds = candidate["duration"]?.double, milliseconds > 0,
               abs(milliseconds / 1000 - expected) > MusicMatching.durationTolerance(expected) { return false }
            return true
        }
        for candidate in candidates.prefix(2) {
            try Task.checkCancellation()
            guard let id = candidate["id"]?.string, let key = candidate["accesskey"]?.string else { continue }
            let download = MusicHTTP.url("https://lyrics.kugou.com/download", [("ver", "1"), ("client", "pc"), ("id", id), ("accesskey", key), ("fmt", "lrc"), ("charset", "utf8")])
            let json = try await MusicHTTP.json(transport, MusicHTTP.request(download, timeout: 4, headers: headers), timeout: 4)
            if let payload = MusicLyricPayload.parse(json), let parsed = MusicLyrics.parse(payload.lyric, translation: payload.translation, romanization: payload.romanization, platform: .kugou) { return parsed }
        }
        return nil
    }
}

extension MiguMusicCatalog: MusicLyricsSource {
    public func lyrics(songID: String) async throws -> MusicLyrics? {
        try await lyrics(songID: songID, track: MusicTrack(platform: .migu, songID: songID, title: "", artists: []))
    }

    public func lyrics(songID: String, track: MusicTrack) async throws -> MusicLyrics? {
        let info = track.lxInfo(for: .migu) ?? [:]
        let headers = ["Referer": "https://music.migu.cn/"]
        // New app-search URLs can coexist with an expired lyricUrl from the older catalog.
        // Try both; losing the first address must not discard the second valid document.
        var seen = Set<String>()
        for field in ["lrcUrl", "lyricUrl"] {
            guard let address = info[field]?.string, seen.insert(address).inserted else { continue }
            if let found = try? await MusicLyricPayload(lyric: address, translation: info["trcUrl"]?.string).loaded(transport: transport, platform: .migu, headers: headers) { return found }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        let copyright = info["copyrightId"]?.string ?? Self.ids(songID)?.copyright ?? songID
        let resourceURL = MusicHTTP.url("https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do", [("copyrightId", copyright), ("resourceType", "2")])
        if let resource = try? await MusicHTTP.json(transport, MusicHTTP.request(resourceURL, timeout: 4, headers: headers), timeout: 4),
           let item = resource["resource"]?.array?.first,
           let address = (item["lrcUrl"] ?? item["lyricUrl"])?.string,
           let found = try? await MusicLyricPayload(lyric: address, translation: item["trcUrl"]?.string).loaded(transport: transport, platform: .migu, headers: headers) { return found }
        try Task.checkCancellation()
        let url = MusicHTTP.url("https://music.migu.cn/v3/api/music/audioPlayer/getLyric", [("copyrightId", copyright)])
        let json = try await MusicHTTP.json(transport, MusicHTTP.request(url, timeout: 4, headers: headers), timeout: 4)
        guard let payload = MusicLyricPayload.parse(json) else { return nil }
        return try await payload.loaded(transport: transport, platform: .migu, headers: headers)
    }
}

/// Finds a track's lyrics: from the catalog whose recording is playing first, since timing
/// belongs to a recording, then from the other catalog that lists the same recording.
public struct MusicLyricsLoader: Sendable {
    let sources: [any MusicLyricsSource]
    let lxLibrary: LXSourceLibrary?
    let lxRuntime: LXSourceRuntime
    let transport: MusicTransport
    public init(sources: [any MusicLyricsSource]) {
        self.sources = sources; lxLibrary = nil; lxRuntime = .shared; transport = URLSessionMusicTransport()
    }
    public init(transport: MusicTransport = URLSessionMusicTransport(), lxLibrary: LXSourceLibrary = .shared, lxRuntime: LXSourceRuntime = .shared) {
        sources = [QQMusicCatalog(transport: transport), NeteaseMusicCatalog(transport: transport), KugouMusicCatalog(transport: transport),
                   KuwoMusicCatalog(transport: transport), MiguMusicCatalog(transport: transport), MusicExtensionCatalog()]
        self.transport = transport; self.lxLibrary = lxLibrary; self.lxRuntime = lxRuntime
    }

    public func lyrics(for track: MusicTrack, playing platform: MusicPlatform?, sourceID: String? = nil) async -> MusicLyrics? {
        let ordered = sources.filter { $0.platform == platform } + sources.filter { $0.platform != platform }
        var unsynced: MusicLyrics?
        let imported = lxLibrary?.enabled ?? []
        for source in ordered {
            guard !Task.isCancelled else { return nil }
            guard let songID = track.ids[source.platform] else { continue }
            // Prefer the imported source actually playing this recording, then the platform's
            // own lyrics, then other enabled sources declaring lyric for this same catalog ID.
            let preferred = imported.filter { $0.id == sourceID }
            if let found = await importedLyrics(preferred, track: track, platform: source.platform, songID: songID) {
                if found.synced { return found }; unsynced = unsynced ?? found
            }
            if let found = try? await MusicHTTP.withTimeout(10, { try await source.lyrics(songID: songID, track: track) }) {
                if Task.isCancelled { return nil }
                if found.synced { return found }; unsynced = unsynced ?? found
            }
            if let found = await importedLyrics(imported.filter { $0.id != sourceID }, track: track, platform: source.platform, songID: songID) {
                if found.synced { return found }; unsynced = unsynced ?? found
            }
        }
        return unsynced
    }

    private func importedLyrics(_ sources: [LXSource], track: MusicTrack, platform: MusicPlatform, songID: String) async -> MusicLyrics? {
        guard let lxLibrary, platform != .ext else { return nil }
        let key = LXSourceKey.key(platform)
        var info: [String: JSONValue]?
        var unsynced: MusicLyrics?
        for source in sources {
            guard !Task.isCancelled else { return nil }
            do {
                let actions: [String: [String]]
                if let saved = source.actions { actions = saved }
                else { actions = try await lxRuntime.declaration(source, library: lxLibrary).actions }
                guard actions[key]?.contains("lyric") == true else { continue }
                if info == nil {
                    info = try? await MusicHTTP.withTimeout(3) { try await LXMusicMetadata.shared.info(songID: songID, platform: platform, track: track, transport: transport) }
                    if info == nil { info = LXSourceKey.musicInfo(songID: songID, platform: platform, track: track) }
                }
                try await MusicHealth.shared.admit("lx:" + source.id)
                let answer = try await lxRuntime.lyric(source, library: lxLibrary, key: key, musicInfo: info ?? [:])
                guard let payload = MusicLyricPayload.parse(answer), let found = try await payload.loaded(transport: transport, platform: platform) else { continue }
                if found.synced { return found }; unsynced = unsynced ?? found
            } catch { if Task.isCancelled { return nil } }
        }
        return unsynced
    }
}
