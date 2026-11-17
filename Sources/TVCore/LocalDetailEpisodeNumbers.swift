import Foundation

/// MacCat episode-numbers.mjs semantics shared by metadata alignment and detail display.
public enum LocalDetailEpisodeNumbers {
    /// Never assign metadata by list position: unnumbered audio variants, trailers and episode packs
    /// must not borrow the title/still of the first ordinary episode.
    public static func mappedNumbers(_ names: [String], season: Int, seasonCounts: [Int: Int], absolute: Bool, offset: Int = 0) -> [Int?] {
        let parsed = names.map { name -> Int? in
            guard !isExtra(name) else { return nil }
            let value = numbers(name)
            guard value.season == nil || value.season == season else { return nil }
            return value.episode.map { $0 + offset }
        }
        let previous = seasonCounts.filter { $0.key > 0 && $0.key < season }
        let before = previous.values.reduce(0, +)
        if absolute { return parsed.map { $0.map { $0 - before } } }
        // MacCat accepts continuous numbering only when this line starts exactly at the season boundary.
        let known = parsed.compactMap { $0 }
        if offset == 0, season > 1, previous.count == season - 1, previous.values.allSatisfy({ $0 > 0 }),
           let count = seasonCounts[season], count > 0, known.min() == before + 1, known.allSatisfy({ $0 <= before + count }) {
            return parsed.map { $0.map { $0 - before } }
        }
        return parsed
    }
    // Source lines can contain thousands of filenames. Parse a name once, outside repeated card redraws.
    private final class ParsedNumbers: NSObject {
        let value: (season: Int?, episode: Int?)
        init(_ value: (season: Int?, episode: Int?)) { self.value = value }
    }
    nonisolated(unsafe) private static let numberCache: NSCache<NSString, ParsedNumbers> = {
        let cache = NSCache<NSString, ParsedNumbers>(); cache.countLimit = 4000; return cache
    }()
    nonisolated(unsafe) private static let regexCache = NSCache<NSString, NSRegularExpression>()
    public static func isExtra(_ name: String) -> Bool {
        name.range(of: #"预告|預告|花絮|片花|采访|採訪|幕后|幕後|主题曲|主題曲|\b(?:trailer|teaser|preview|behind the scenes)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
    public static func numbers(_ name: String) -> (season: Int?, episode: Int?) {
        if let cached = numberCache.object(forKey: name as NSString) { return cached.value }
        let value = parseNumbers(name)
        numberCache.setObject(ParsedNumbers(value), forKey: name as NSString)
        return value
    }
    private static func parseNumbers(_ name: String) -> (season: Int?, episode: Int?) {
        let numeral = #"[零〇一二两兩三四五六七八九十百千万萬\d]+"#
        let chineseSeason = #"第\s*("# + numeral + #")\s*[季部]"#
        let chineseEpisode = #"(?:第\s*)?("# + numeral + #")\s*[集话話期回章节節]"#
        let seasonTag = #"(?:\bSeason[ ._-]*|(?<![a-z\d])S[ ._-]*)(\d{1,3})(?!\d)"#
        var text = name.precomposedStringWithCompatibilityMapping
        let cleanup = [
            #"[\u200b-\u200d\ufeff]|<[^>]*>|&nbsp;|&#160;"#,
            #"\.(?:mp4|mkv|m4v|avi|flv|m2ts|mts|ts|m3u8|webm|mov|wmv|rmvb|rm|mp3|m4a|aac|flac|wav|ogg)(?![a-z\d])"#,
            #"(?<!\d)(?:19|20)\d{2}[-_./年](?:0?[1-9]|1[0-2])[-_./月](?:0?[1-9]|[12]\d|3[01])日?(?!\d)"#,
            #"(?<![a-z\d])\d+(?:\.\d+)?\s*(?:[kmgt]i?b|[gmkt])(?=$|[^a-z\d])"#,
            #"(?<![a-z\d])(?:\d{3,4}[pi](?:\d{2})?|[248]k|\d{3,4}\s*[x×]\s*\d{3,4})(?![a-z\d])"#,
            #"(?<![a-z\d])(?:[xh][ ._-]?26[45]|hevc|avc|av1|vp9|\d{1,2}[ ._-]?bit)(?![a-z\d])"#,
            #"(?<![a-z\d])(?:aac|e?ac[ ._-]?3|ddp?|dts(?:[ ._-]?hd)?|flac|truehd)(?:[ ._-]*\d\.\d(?:ch)?)?(?![a-z\d])"#,
            #"(?<![a-z\d])(?:ver(?:sion)?|v)[ ._-]*\d+(?:\.\d+)*(?![a-z\d])"#
        ]
        for pattern in cleanup { text = replacing(pattern, in: text) }
        let pair = groups(#"S[ ._-]*(\d{1,3})[ ._-]*E(?:P)?[ ._-]*(\d{1,4})(?!\d)|(?<![a-z\d])(\d{1,3})\s*[x×]\s*(\d{1,4})(?![a-z\d])"#, in: text)?.filter { !$0.isEmpty }
        let seasonMatch = groups(chineseSeason, in: text) ?? groups(seasonTag, in: text)
        let special = groups(#"(?:\bSP|\bSpecials?\b|特别篇|特別篇|番外(?:篇)?)[ ._-]*(\d{1,4})?(?!\d)"#, in: text)
        let season = pair?.first.flatMap(Int.init) ?? seasonMatch?.first.flatMap(chineseNumber) ?? (special == nil ? nil : 0)
        let range = #"(?=(?:第\s*|(?<![a-z])(?:EP(?:ISODE)?S?|E|SP)[ ._-]*|S[ ._-]*\d+[ ._-]*E)("# + numeral + #")(?:\s*[集话話期回章节節])?[ ._]*[-~～至][ ._]*(?:(?:第|EP?|SP)\s*)?("# + numeral + #"))"#
        if matches(range, in: text).contains(where: { $0.count > 1 && chineseNumber($0[0]) != chineseNumber($0[1]) }) { return (season, nil) }
        if let pair, pair.count == 2 { return (season, Int(pair[1])) }
        if let explicit = (groups(chineseEpisode, in: text) ?? groups(#"(?<![a-z])(?:EP(?:ISODE)?S?|E)[ ._:#-]*(\d{1,4})(?!\d)"#, in: text))?.first { return (season, chineseNumber(explicit)) }
        if let number = special?.first.flatMap(Int.init) { return (season, number) }
        var loose = replacing(chineseSeason, in: replacing(seasonTag, in: text))
        loose = replacing(#"(?<!\d)(?:19|20)\d{2}(?!\d)"#, in: loose)
        loose = replacing(#"[\[({【]([^\]})】]*)[\]})】]"#, in: loose, preservingNumber: true)
        loose = replacing(#"^[\s._]+|[\s._-]+$"#, in: loose).trimmingCharacters(in: .whitespacesAndNewlines)
        if loose.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil { return (season, Int(loose)) }
        if loose.range(of: #"^-\d+$|^\d+\s*[-~～至]\s*\d+$"#, options: .regularExpression) != nil { return (season, nil) }
        if let suffix = groups(#"(?<!\d)([1-9]\d?)([_.-])(0*[1-9]\d{0,3})$"#, in: loose), suffix.count == 3,
           (suffix[1] == "_" || loose.rangeOfCharacter(from: .letters) != nil),
           suffix[1] != "-" || suffix[2].hasPrefix("0") { return (season ?? Int(suffix[0]), Int(suffix[2])) }
        let digits = matches(#"(\d+)"#, in: loose).compactMap(\.first)
        return (season, digits.count == 1 && digits[0].count <= 4 ? Int(digits[0]) : nil)
    }
    private static func chineseNumber(_ value: String) -> Int? {
        if let number = Int(value) { return number }
        let digits: [Character: Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"兩":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        let units: [Character: Int] = ["十":10,"百":100,"千":1000,"万":10000,"萬":10000]
        var total = 0, section = 0, digit = 0
        for char in value {
            if let n = digits[char] ?? (char.isASCII ? char.wholeNumberValue : nil) { digit = digit * 10 + n }
            else if units[char] == 10000 { total += max(1, section + digit) * 10000; section = 0; digit = 0 }
            else if let unit = units[char] { section += max(1, digit) * unit; digit = 0 }
            else { return nil }
        }
        return value.isEmpty ? nil : total + section + digit
    }
    private static func groups(_ pattern: String, in text: String) -> [String]? { matches(pattern, in: text).first }
    private static func expression(_ pattern: String) -> NSRegularExpression? {
        if let cached = regexCache.object(forKey: pattern as NSString) { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        regexCache.setObject(regex, forKey: pattern as NSString)
        return regex
    }
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = expression(pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }
    private static func replacing(_ pattern: String, in text: String, preservingNumber: Bool = false) -> String {
        guard let regex = expression(pattern) else { return text }
        if !preservingNumber { return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ") }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let full = Range(match.range, in: result), let innerRange = Range(match.range(at: 1), in: result) else { continue }
            let inner = String(result[innerRange]).trimmingCharacters(in: .whitespaces)
            result.replaceSubrange(full, with: inner.range(of: #"^\d{1,4}$"#, options: .regularExpression) == nil ? " " : " \(inner) ")
        }
        return result
    }
}
