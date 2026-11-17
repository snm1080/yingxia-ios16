import Foundation

/// Resolves public catalog identities to short-lived native video addresses.
/// Requests use only each catalog's public headers, never subscription credentials.
public actor TrailerStreamResolver {
    public struct Stream: Sendable {
        public let url: URL
        public let headers: [String: String]
    }
    private struct Cached { let stream: Stream; let expires: Date }
    private struct Pending { let id: UUID; let task: Task<Stream?, Never> }
    private let session: URLSession
    private var cached: [TMDBMatch.Trailer: Cached] = [:]
    private var pending: [TMDBMatch.Trailer: Pending] = [:]

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: configuration)
        }
    }

    public func resolve(_ trailer: TMDBMatch.Trailer) async -> Stream? {
        guard !Task.isCancelled else { return nil }
        if let value = cached[trailer], value.expires > Date() { return value.stream }
        cached[trailer] = nil
        if let value = pending[trailer] { return await value.task.value }
        let id = UUID(), task = Task { await self.load(trailer) }
        pending[trailer] = Pending(id: id, task: task)
        let stream = await task.value
        guard pending[trailer]?.id == id else { return nil }
        pending[trailer] = nil
        if let stream, !Task.isCancelled {
            cached = cached.filter { $0.value.expires > Date() }
            if cached.count >= 32, let oldest = cached.min(by: { $0.value.expires < $1.value.expires })?.key {
                cached[oldest] = nil
            }
            let expires = min(Self.expiry(stream.url) ?? Date().addingTimeInterval(900), Date().addingTimeInterval(900))
            if expires > Date().addingTimeInterval(15) { cached[trailer] = Cached(stream: stream, expires: expires.addingTimeInterval(-15)) }
        }
        return Task.isCancelled ? nil : stream
    }

    /// A late failure for an older URL must not evict a newly resolved stream.
    public func invalidate(_ trailer: TMDBMatch.Trailer, failedURL: URL? = nil) {
        guard failedURL == nil || cached[trailer]?.stream.url == failedURL else { return }
        cached[trailer] = nil
        pending[trailer]?.task.cancel(); pending[trailer] = nil
    }

    private func load(_ trailer: TMDBMatch.Trailer) async -> Stream? {
        if trailer.site.caseInsensitiveCompare("IMDb") == .orderedSame,
           let stream = await imdb(trailer.key) { return stream }
        guard !Task.isCancelled else { return nil }
        if trailer.site.caseInsensitiveCompare("Douban") == .orderedSame,
           Self.subjectID(trailer.key), let stream = await douban(subject: trailer.key) { return stream }
        guard let title = trailer.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              title.count <= 200, !title.contains("://"), let subject = await doubanSubject(title: title, year: trailer.year) else { return nil }
        return await douban(subject: subject)
    }

    private func data(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let maximum = 2 * 1024 * 1024
        guard response.expectedContentLength <= Int64(maximum) else { throw URLError(.dataLengthExceedsMaximum) }
        var value = Data()
        for try await byte in bytes {
            value.append(byte)
            if value.count > maximum { throw URLError(.dataLengthExceedsMaximum) }
        }
        try Task.checkCancellation()
        return value
    }

    private func imdb(_ id: String) async -> Stream? {
        guard id.range(of: #"^tt[0-9]{5,12}$"#, options: .regularExpression) != nil else { return nil }
        let query = "query { title(id: \"\(id)\") { primaryVideos(first: 5) { edges { node { id name { value } playbackURLs { url mimeType displayName { value } } } } } } }"
        var request = URLRequest(url: URL(string: "https://api.graphql.imdb.com/")!, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = ["Content-Type": "application/json", "Origin": "https://www.imdb.com",
            "Referer": "https://www.imdb.com/", "User-Agent": "Mozilla/5.0"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        guard let data = try? await data(request), let body = try? JSONDecoder().decode(Catalog.self, from: data) else { return nil }
        let videos = body.data?.title?.primaryVideos?.edges.map(\.node) ?? []
        let named = videos.filter { Self.isTrailer($0.name?.value ?? "") }
        for video in named.isEmpty ? videos : named {
            let formats = (video.playbackURLs ?? []).filter {
                ["video/mp4", "application/x-mpegurl", "application/vnd.apple.mpegurl"].contains($0.mimeType.lowercased())
            }.sorted { Self.rank($0) > Self.rank($1) }
            for format in formats {
                guard let url = Self.mediaURL(format.url, domain: "media-imdb.com") else { continue }
                return Stream(url: url, headers: ["Referer": "https://www.imdb.com/", "User-Agent": "Mozilla/5.0"])
            }
        }
        return nil
    }

    private func doubanSubject(title: String, year: Int?) async -> String? {
        var components = URLComponents(string: "https://movie.douban.com/j/subject_suggest")!
        components.queryItems = [URLQueryItem(name: "q", value: title)]
        var request = URLRequest(url: components.url!, timeoutInterval: 8)
        request.allHTTPHeaderFields = ["Referer": "https://movie.douban.com/", "User-Agent": "Mozilla/5.0", "Accept": "application/json"]
        guard let data = try? await data(request), let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let identity = Self.normalized(title)
        guard !identity.isEmpty else { return nil }
        var subjects = Set<String>()
        for row in rows.prefix(12) {
            guard let id = row["id"] as? String, Self.subjectID(id),
                  let name = row["title"] as? String, Self.normalized(name) == identity else { continue }
            let foundYear = (row["year"] as? String).flatMap(Int.init) ?? (row["year"] as? NSNumber)?.intValue
            if let year, foundYear != year { continue }
            subjects.insert(id)
        }
        return subjects.count == 1 ? subjects.first : nil
    }

    private func douban(subject: String) async -> Stream? {
        guard Self.subjectID(subject) else { return nil }
        var request = URLRequest(url: URL(string: "https://m.douban.com/rexxar/api/v2/movie/\(subject)/trailers")!, timeoutInterval: 8)
        request.allHTTPHeaderFields = ["Referer": "https://m.douban.com/movie/subject/\(subject)/", "User-Agent": "Mozilla/5.0", "Accept": "application/json"]
        guard let data = try? await data(request),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trailers = body["trailers"] as? [[String: Any]] else { return nil }
        for trailer in trailers.prefix(20) {
            guard let name = trailer["title"] as? String, Self.isTrailer(name),
                  let address = trailer["video_url"] as? String, let url = Self.mediaURL(address, domain: "doubanio.com") else { continue }
            return Stream(url: url, headers: ["Referer": "https://movie.douban.com/", "User-Agent": "Mozilla/5.0"])
        }
        return nil
    }

    private nonisolated static func subjectID(_ value: String) -> Bool {
        value.range(of: #"^[1-9][0-9]{0,11}$"#, options: .regularExpression) != nil
    }
    private nonisolated static func normalized(_ value: String) -> String {
        let text = value.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return (text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text).filter { $0.isLetter || $0.isNumber }
    }
    private nonisolated static func isTrailer(_ value: String) -> Bool {
        ["预告", "預告", "trailer", "teaser"].contains { value.localizedCaseInsensitiveContains($0) }
    }
    private nonisolated static func mediaURL(_ value: String, domain: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host == domain || host.hasSuffix("." + domain), url.user == nil, url.password == nil,
              ["mp4", "m3u8"].contains(url.pathExtension.lowercased()),
              !value.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
        if let expiry = expiry(url), expiry <= Date().addingTimeInterval(15) { return nil }
        return url
    }
    private nonisolated static func expiry(_ url: URL) -> Date? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for item in query where ["expires", "expiry", "expire", "exp"].contains(item.name.lowercased()) {
            if let text = item.value, let value = Double(text), value.isFinite, value > 0 {
                return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
            }
        }
        if let date = query.first(where: { $0.name.lowercased() == "x-amz-date" })?.value,
           let lifetime = query.first(where: { $0.name.lowercased() == "x-amz-expires" })?.value.flatMap(Double.init), lifetime.isFinite {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            if let start = formatter.date(from: date) { return start.addingTimeInterval(lifetime) }
        }
        return nil
    }
    private nonisolated static func rank(_ format: Format) -> Int {
        switch format.displayName?.value {
        case "720p": 5
        case "1080p": 4
        case "480p": 3
        case "AUTO": 2
        default: 1
        }
    }
    private struct Catalog: Decodable { let data: DataBody? }
    private struct DataBody: Decodable { let title: Title? }
    private struct Title: Decodable { let primaryVideos: Videos? }
    private struct Videos: Decodable { let edges: [Edge] }
    private struct Edge: Decodable { let node: Video }
    private struct Video: Decodable { let name: Name?; let playbackURLs: [Format]? }
    private struct Name: Decodable { let value: String }
    private struct Format: Decodable { let url: String; let mimeType: String; let displayName: Name? }
}
