import Foundation

/// Ordered image pages returned by catalog sources, including Python spiders.
public struct ReadingMedia: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case comic, gallery }
    public struct Image: Codable, Hashable, Sendable {
        public let url: String
        public let headers: [String: String]
    }
    public let kind: Kind
    public let images: [Image]

    /// Nil means video/other media. An empty image list still means reading: report its
    /// source error in the reader instead of passing a custom image scheme to a player.
    public static func normalize(_ raw: JSONValue, baseURL: URL? = nil, headers: [String: String] = [:]) -> ReadingMedia? {
        var result = unpack(raw)
        var inherited = mergeHeaders([:], .object(headers.mapValues(JSONValue.string)))
        for _ in 0..<5 {
            if let values = result.array, values.count == 1 { result = unpack(values[0]) }
            guard var fields = result.object else { break }
            inherited = mergeHeaders(inherited, fields["header"], fields["headers"])
            let nested = unpack(["data", "result", "play"].compactMap { fields[$0] }.first { $0 != .null } ?? .null)
            if let inner = nested.object {
                for key in ["data", "result", "play", "header", "headers"] { fields.removeValue(forKey: key) }
                fields.merge(inner) { _, new in new }
                result = .object(fields)
            } else if let text = text(nested), readingScheme(text) != nil {
                for key in ["data", "result", "play"] { fields.removeValue(forKey: key) }
                fields["url"] = .string(text)
                result = .object(fields)
                break
            } else { break }
        }
        let fields = result.object ?? [:]
        inherited = mergeHeaders(inherited, fields["header"], fields["headers"])
        let rawURL = text(result).map(JSONValue.string) ?? ["url", "urls", "play_url", "playUrl", "link", "src"].compactMap { fields[$0] }.first {
            $0 != .null && $0 != .string("") && $0.array?.isEmpty != true
        }
        let address = rawURL.flatMap(text)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = address.flatMap(readingScheme)
        let declared = ["contentType", "content_type", "vod_content_type", "mediaKind", "kind"].compactMap { fields[$0].flatMap(text) }.first { !$0.isEmpty } ?? ""
        let isDeclared = declared.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "^(?:image(?:/[^;\\s]+)?|comic|gallery)$", options: [.regularExpression, .caseInsensitive]) != nil
        var values = fields["images"]?.array ?? fields["pictures"]?.array
        if let scheme, let address {
            values = String(address.dropFirst(scheme.count + 3)).components(separatedBy: "&&").map(JSONValue.string)
        } else if values == nil, isDeclared || address.map(isImageAddress) == true {
            values = rawURL?.array ?? [rawURL ?? .null]
        }
        guard let values else { return nil }
        let comic = [fields["kind"], fields["mediaKind"]].contains { $0.flatMap(text)?.lowercased() == "comic" } || scheme == "manga" || scheme == "mange"
        return ReadingMedia(kind: comic ? .comic : .gallery,
                            images: values.compactMap { page($0, headers: inherited, baseURL: baseURL) })
    }

    private static func unpack(_ value: JSONValue) -> JSONValue {
        var value = value
        for _ in 0..<4 {
            guard let string = text(value), let next = try? JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) else { break }
            value = next
        }
        return value
    }

    private static func text(_ value: JSONValue) -> String? {
        if case .string(let string) = value { return string }; return nil
    }

    private static func readingScheme(_ text: String) -> String? {
        let value = text.lowercased()
        return ["pics", "manga", "mange"].first { value.hasPrefix($0 + "://") }
    }

    private static func isImageAddress(_ text: String) -> Bool {
        let path = text.components(separatedBy: CharacterSet(charactersIn: "|?#")).first ?? ""
        return path.range(of: "\\.(?:jpe?g|png|gif|webp|avif|bmp)$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func page(_ value: JSONValue, headers: [String: String], baseURL: URL?) -> Image? {
        let fields = value.object ?? [:]
        guard var address = text(value) ?? ["url", "src", "link"].compactMap({ fields[$0] }).first(where: { $0 != .null }).flatMap(text) else { return nil }
        address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var inline: [String: JSONValue] = [:]
        if let separator = address.lastIndex(of: "|") {
            let suffix = String(address[address.index(after: separator)...])
            if suffix.contains("=") {
                for pair in suffix.components(separatedBy: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    func decode(_ string: Substring) -> String {
                        let plus = string.replacingOccurrences(of: "+", with: " ")
                        return plus.removingPercentEncoding ?? plus
                    }
                    if let name = parts.first { inline[decode(name)] = .string(parts.count > 1 ? decode(parts[1]) : "") }
                }
                address = String(address[..<separator])
            }
        }
        guard !address.isEmpty, !address.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              let url = URL(string: address, relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        // Keep signed absolute addresses byte-for-byte, including encoded delimiters and query order.
        if address.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil { address = url.absoluteString }
        return Image(url: address, headers: mergeHeaders(headers, .object(inline), fields["header"], fields["headers"]))
    }

    private static let transportHeaders: Set<String> = ["host", "connection", "content-length", "transfer-encoding", "keep-alive", "proxy-connection", "upgrade", "te", "trailer", "expect"]

    private static func mergeHeaders(_ inherited: [String: String], _ values: JSONValue?...) -> [String: String] {
        var result = inherited
        for value in values {
            guard let value, let fields = unpack(value).object else { continue }
            for (name, value) in fields {
                guard name.range(of: "^[!#$%&'*+.^_`|~0-9a-z-]+$", options: [.regularExpression, .caseInsensitive]) != nil,
                      !transportHeaders.contains(name.lowercased()) else { continue }
                let string: String
                switch value {
                case .string(let text): string = text
                case .number(let number): guard number.isFinite, let text = value.string else { continue }; string = text
                case .bool(let boolean): string = boolean ? "true" : "false"
                default: continue
                }
                guard !string.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 || $0.value == 127 }) else { continue }
                for key in result.keys where key.caseInsensitiveCompare(name) == .orderedSame { result.removeValue(forKey: key) }
                result[name] = string
            }
        }
        return result
    }
}
