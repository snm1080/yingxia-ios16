import Foundation

/// The same resource-title rules as MacCat's runtime/lib/tmdb-matching.mjs.
/// Keep the source title intact: the query discards release labels, while year/season remain evidence.
enum TMDBTitleMatching {
    nonisolated(unsafe) private static let expressions: NSCache<NSString, NSRegularExpression> = {
        let value = NSCache<NSString, NSRegularExpression>()
        value.countLimit = 64
        return value
    }()
    private static func expression(_ pattern: String) -> NSRegularExpression? {
        if let cached = expressions.object(forKey: pattern as NSString) { return cached }
        guard let value = try? NSRegularExpression(pattern: pattern) else { return nil }
        expressions.setObject(value, forKey: pattern as NSString)
        return value
    }
    private static func first(_ pattern: String, _ text: String) -> NSTextCheckingResult? {
        expression(pattern)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func capture(_ pattern: String, _ text: String, group: Int = 1) -> String? {
        guard let match = first(pattern, text), let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
    private static func replacing(_ pattern: String, in text: String, with replacement: String = " ") -> String {
        expression(pattern)?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement) ?? text
    }

    static func query(_ title: String) -> String {
        var raw = title.precomposedStringWithCompatibilityMapping
        raw = replacing(#"<[^>]*>|[\p{So}\p{Cf}]"#, in: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        raw = replacing(#"^(?:[\[【](?:国剧|泰剧|韩剧|日剧|美剧|短剧|电视剧|剧集|电影|标题)[\]】]\s*[:：]?\s*|(?:电视剧|剧集|电影)\s*[:：]\s*|国剧(?=[\p{Han}「『]))"#, in: raw, with: "")
        if let year = first(#"[\[【(]\s*(?:19|20)\d{2}\s*[\]】)]"#, raw), year.range.location > 0,
           let range = Range(year.range, in: raw), first(#"^\s*[:：]"#, String(raw[range.upperBound...])) == nil {
            raw = String(raw[..<range.lowerBound])
        }
        if let book = capture(#"^《([^》]+)》"#, raw) { raw = book }
        if let tail = first(#"(?i)(?:更新至?|更至?|连载至|連載至|全|共)\s*(?:EP?)?\d+(?:\s*[-~至]\s*\d+)?\s*[集话話期]?|(?<=[\p{Han}\s._-])(?:4K|8K|2160p|1080p|720p|WEB[- ]?DL|HDR|SDR|HEVC|H\.?26[45]|x26[45])|[\[【(](?:剧情|爱情|古装|都市|悬疑|国安|喜剧|动作|科幻|犯罪)[^\]】)]*[\]】)]"#, raw),
           tail.range.location > 0, let range = Range(tail.range, in: raw) { raw = String(raw[..<range.lowerBound]) }
        raw = replacing(#"^[「『]+|[\s「『\[【(]+$"#, in: raw, with: "")
        raw = replacing(#"(?i)\.(?:mkv|mp4|avi|mov|wmv|flv|rmvb|ts|m2ts)$"#, in: raw)
        // ICU word boundaries differ from JavaScript beside Han text. Use ASCII word boundaries explicitly.
        let bracket = expression(#"[\[【(]([^\]】)]*)[\]】)]"#)
        for match in (bracket?.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) ?? []).reversed() {
            guard let range = Range(match.range, in: raw), let inner = Range(match.range(at: 1), in: raw) else { continue }
            if first(#"(?i)^(?:19|20)\d{2}$|(?<![a-z0-9_])(?:4K|8K|HDR|HD|UHD|1080p|2160p|720p|BluRay|WEB-DL|\d+(?:\.\d+)?fps)(?![a-z0-9_])|(?:DTS|AAC|AC3|DDP)音轨|(?:更新至|更|全)\s*\d+\s*集|高码率|字幕|中字|国语|粤语|国粤|配音|高清|超清|完整版"#, String(raw[inner])) != nil {
                raw.replaceSubrange(range, with: " ")
            }
        }
        raw = replacing(#"[\[【(]\s*(?:真彩|臻彩|无水印|无台标)\s*[\]】)]"#, in: raw)
        raw = replacing(#"(?i)第\s*[零〇一二两三四五六七八九十百千\d]+\s*[季集]|(?<![a-z0-9_])Season\s*\d{1,3}(?![a-z0-9_])|(?<![a-z0-9_])S\d{1,3}(?:[ ._-]*E\d{1,4})?(?![a-z0-9_])"#, in: raw)
        raw = replacing(#"(?i)(?<![a-z0-9_])(?:2160p|1080p|720p|WEB[- ]?DL|BluRay|HEVC|H\.?26[45]|x26[45]|AAC|DTS|DDP|Atmos)(?![a-z0-9_])"#, in: raw)
        raw = replacing(#"(?i)(?:\s*(?:(?<![a-z0-9_])(?:4K|8K|HDR|HD|UHD|1080p|2160p|720p|BluRay|WEB-DL)(?![a-z0-9_])|更新至\s*\d+\s*集|全\s*\d+\s*集|高码率|国语版|粤语版|国粤双语|中英双字|简繁中字|高清版|超清版|完整版|完结))+\s*$"#, in: raw)
        raw = replacing(#"[\p{So}]"#, in: raw)
        raw = replacing(#"[#＃]"#, in: raw, with: "")
        raw = replacing(#"(^|\s)(?:动漫|动画|电视剧|剧集|电影|综艺)(?=\s|$)"#, in: raw)
        raw = replacing(#"[._]+"#, in: raw)
        raw = replacing(#"\s+"#, in: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        raw = replacing(#"(?i)^[a-z]\s+(?=.*[\p{Han}])"#, in: raw, with: "")
        if first(#"[\p{Han}]"#, raw) != nil { raw = replacing(#"(?i)\s+[a-z]$"#, in: raw, with: "") }
        return String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }

    static func key(_ title: String) -> String {
        replacing(#"[\p{P}\p{S}\s]"#, in: query(title).lowercased(), with: "")
    }

    static func sourceYear(_ year: String?, title: String, episodes: [String]) -> String? {
        if let explicit = capture(#"((?:19|20)\d{2})"#, year ?? "") { return explicit }
        if let bracket = capture(#"[\[【(]\s*((?:19|20)\d{2})\s*[\]】)]"#, title.precomposedStringWithCompatibilityMapping) { return bracket }
        let years = Set(episodes.compactMap { capture(#"(?i)(?:^|[ ._-])((?:19|20)\d{2})(?=[ ._-]+S\d+[ ._-]*E\d+)"#, $0) })
        return years.count == 1 ? years.first : nil
    }

    static func season(_ title: String) -> Int? {
        let text = title.precomposedStringWithCompatibilityMapping
        if let pair = capture(#"(?i)S[ ._-]*(\d{1,3})[ ._-]*E(?:P)?[ ._-]*\d{1,4}(?!\d)"#, text)
            ?? capture(#"(?i)(?<![a-z\d])(\d{1,3})\s*[x×]\s*\d{1,4}(?!\d)"#, text) { return Int(pair) }
        if let chinese = capture(#"第\s*([零〇一二两兩三四五六七八九十百千万萬\d]+)\s*[季部]"#, text) { return chineseNumber(chinese) }
        if let latin = capture(#"(?i)(?:(?<![a-z0-9_])Season[ ._-]*|(?<![a-z\d])S[ ._-]*)(\d{1,3})(?!\d)"#, text) { return Int(latin) }
        return first(#"(?i)(?<![a-z0-9_])SP|(?<![a-z0-9_])Specials?(?![a-z0-9_])|特别篇|特別篇|番外(?:篇)?"#, text) == nil ? nil : 0
    }

    private static func chineseNumber(_ text: String) -> Int? {
        let digits: [Character: Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"兩":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        let units: [Character: Int] = ["十":10,"百":100,"千":1000,"万":10000,"萬":10000]
        var total = 0, section = 0, digit = 0
        for character in text {
            if let value = (character.isASCII ? character.wholeNumberValue : nil) ?? digits[character] { digit = digit * 10 + value }
            else if let unit = units[character] {
                if unit == 10000 { total += max(1, section + digit) * unit; section = 0; digit = 0 }
                else { section += max(1, digit) * unit; digit = 0 }
            } else { return nil }
        }
        return total + section + digit
    }

    static func mediaType(_ request: TMDBMatch.Request) -> TMDBMatch.MediaType? {
        let category = request.category ?? ""
        if first(#"(?i)电影|電影|剧场版|劇場版|movie|film"#, category) != nil { return .movie }
        let numbered = request.episodes.filter {
            first(#"(?i)预告|預告|花絮|片花|采访|採訪|幕后|幕後|主题曲|主題曲|\b(?:trailer|teaser|preview|behind the scenes)\b"#, $0) == nil && TMDBMatch.episodeNumber($0) != nil
        }.count > 1
        if first(#"(?i)电视剧|電視劇|连续剧|連續劇|综艺|綜藝|剧集|series|tv"#, category) != nil || season(request.title) != nil || numbered { return .tv }
        return nil
    }

    static func pick(_ results: [TMDBMatch.SearchResult], request: TMDBMatch.Request) -> TMDBMatch.SearchResult? {
        let aliases = replacing(#"\s*[/|／]\s*"#, in: request.title, with: "\n").components(separatedBy: "\n")
        let keys = Set(([request.title] + aliases).map(key).filter { !$0.isEmpty })
        var matches = results.filter { keys.contains(key($0.name)) || keys.contains(key($0.originalName ?? "")) }
        if let type = mediaType(request) { matches = matches.filter { $0.mediaType == type } }
        if let year = sourceYear(request.year, title: request.title, episodes: request.episodes).flatMap(Int.init), (season(request.title) ?? 0) <= 1 {
            let sameYear = matches.filter { $0.year == year }
            matches = sameYear.isEmpty ? matches.filter { $0.year == nil } : sameYear
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
