import Foundation
import CryptoKit
import Perception

public struct PosterResource: Hashable, Sendable {
    public let url: URL
    public let headers: [String: String]
    private let addressKey: String
    public static func artworkScope(_ url: URL) -> String { "artwork:" + cacheAddress(url) }
    public var cacheKey: String {
        addressKey + headers.sorted { $0.key < $1.key }.map { "\n\($0.key.lowercased()):\($0.value)" }.joined()
    }
    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        addressKey = Self.cacheAddress(url)
        var headers = headers
        // Douban's image hosts refuse covers without a Douban Referer (HTTP 418, or 403 with another site's);
        // many sources and the Douban lists on Discover show them.
        if url.host()?.hasSuffix(".doubanio.com") == true, !headers.keys.contains(where: { $0.caseInsensitiveCompare("Referer") == .orderedSame }) {
            headers["Referer"] = "https://movie.douban.com/"
        }
        self.headers = headers
    }

    private static func cacheAddress(_ url: URL) -> String {
        guard url.scheme?.lowercased() == "data" else { return url.absoluteString }
        // An inline cover can contain hundreds of kilobytes. Keep that payload out
        // of memory-cache keys and the disk index's persisted artwork scope.
        return "data:sha256:" + SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Subscription folders and resources may embed raster covers rather than use
    /// HTTP endpoints. Bound decoded bytes to the artwork cache's per-image limit;
    /// ImageIO still has to decode the image before the loader commits any cache data.
    public static func inlineImageData(for url: URL) -> Data? {
        guard url.scheme?.lowercased() == "data" else { return nil }
        return inlineImageData(url.absoluteString)
    }

    private static func inlineImageData(_ address: String) -> Data? {
        let maximumBytes = 8 * 1024 * 1024
        guard address.utf8.count <= maximumBytes * 4,
              address.prefix(5).lowercased() == "data:",
              let comma = address.firstIndex(of: ",") else { return nil }
        let metadata = address[address.index(address.startIndex, offsetBy: 5)..<comma].lowercased().split(separator: ";")
        guard let type = metadata.first,
              ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp", "image/bmp",
               "image/tiff", "image/x-icon", "image/vnd.microsoft.icon", "image/heic", "image/heif", "image/avif"].contains(type),
              metadata.last == "base64",
              let payload = String(address[address.index(after: comma)...]).removingPercentEncoding,
              payload.utf8.count <= ((maximumBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: payload), !data.isEmpty, data.count <= maximumBytes else { return nil }
        return data
    }

    public init?(address: String, origin: URL) {
        if address.prefix(5).lowercased() == "data:" {
            guard Self.inlineImageData(address) != nil, let url = URL(string: address) else { return nil }
            self.init(url: url)
            return
        }
        // TVBox appends transport headers to artwork URLs. Do not send that suffix as part of the URL.
        let pattern = #"@(Headers|Cookie|Referer|User-Agent)="#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let text = address as NSString
        let matches = regex.matches(in: address, range: NSRange(location: 0, length: text.length))
        let endpoint = matches.first.map { text.substring(to: $0.range.location) } ?? address
        guard let url = try? WebAddress.resolve(endpoint, relativeTo: origin) else { return nil }
        var headers: [String: String] = [:]
        for (index, match) in matches.enumerated() {
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : text.length
            let value = text.substring(with: NSRange(location: start, length: end - start))
            let name = text.substring(with: match.range(at: 1))
            if name.lowercased() == "headers", let data = value.data(using: .utf8),
               let values = try? JSONDecoder().decode([String: String].self, from: data) {
                headers.merge(values) { _, new in new }
            } else if name.lowercased() != "headers" { headers[name] = value }
        }
        self.init(url: url, headers: headers.filter { $0.key.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil && !$0.value.contains("\r") && !$0.value.contains("\n") })
    }
}

public struct Recommendation: Identifiable, Hashable, Sendable {
    public enum Destination: Hashable, Sendable {
        case search(String)
        case detail(Video)
    }
    public let id: String
    public let name: String
    public let poster: PosterResource?
    public let remarks: String
    public let destination: Destination

    public init?(json: [String: JSONValue], origin: URL, isIndex: Bool) {
        let title = HTMLText.name(json["vod_name"]?.string ?? "")
        guard !title.isEmpty else { return nil }
        let video = Video(json: json, origin: origin)
        // Index actions are provider controls, not title recommendations.
        if (isIndex || video == nil), !(json["action"]?.string ?? "").isEmpty { return nil }
        name = title
        poster = json["vod_pic"]?.string.flatMap { PosterResource(address: $0, origin: origin) }
        remarks = json["vod_remarks"]?.string ?? ""
        if !isIndex, let video {
            id = "video:" + video.id; destination = .detail(video)
        } else {
            id = "search:" + title; destination = .search(title)
        }
    }
}

@MainActor @Perceptible public final class RecommendationModel {
    public private(set) var items: [Recommendation] = []
    /// The source's own categories, browsable beside its recommendations.
    public private(set) var categories: [Category] = []
    public private(set) var site: Site?
    public private(set) var busy = false
    public private(set) var error: String?
    /// Reload observers only when a reset discarded a request or visible state.
    public private(set) var resetRevision: UInt64 = 0
    private struct Cached {
        let items: [Recommendation]
        let categories: [Category]
        let date: Date
    }
    private var cache: [String: Cached] = [:]
    private var identity: String?
    private var generation = UUID()
    public init() {}

    public func reset() {
        if busy || !items.isEmpty || !categories.isEmpty || error != nil { resetRevision &+= 1 }
        generation = UUID(); identity = nil; cache = [:]
        items = []; categories = []; site = nil; busy = false; error = nil
    }

    public func load(client: CatalogClient, subscriptionDate: Date, force: Bool = false) async {
        let key = "\(client.origin)|\(subscriptionDate.timeIntervalSince1970)|\(client.site.key)"
        let token = UUID(); generation = token
        if identity != key { items = []; categories = [] }
        identity = key; site = client.site; error = nil
        if !force, let cached = cache[key], Date().timeIntervalSince(cached.date) < 600 {
            items = cached.items; categories = cached.categories; busy = false; return
        }
        busy = true
        do {
            let result = try await client.recommendationPage()
            try Task.checkCancellation()
            guard generation == token else { return }
            items = result.items; categories = result.categories; busy = false
            cache[key] = Cached(items: result.items, categories: result.categories, date: Date())
            if cache.count > 4, let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key { cache[oldest] = nil }
        } catch {
            guard generation == token else { return }
            busy = false
            guard !Task.isCancelled else { return }
            Diagnostics.shared.failure("catalog", "recommendations \(client.reportContext)", error)
            self.error = error.localizedDescription
        }
    }
}
