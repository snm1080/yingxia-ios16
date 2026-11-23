import Foundation

extension TMDBServiceSettings {
    /// Direct requests retain the caller's cache/session. Only the explicitly
    /// configured TMDB proxy enters the embedded mobile HTTP/SOCKS transport.
    func data(for request: URLRequest, session: URLSession) async throws -> Data {
        #if os(iOS) || os(tvOS)
        if let proxy = try proxyConfiguration() {
            guard let url = request.url else { throw URLError(.badURL) }
            let response = try await MobileMediaServices.call("tmdb.fetch", [
                "url": .string(url.absoluteString),
                "proxy": .object(proxy.mapValues(JSONValue.string)),
                "headers": .object((request.allHTTPHeaderFields ?? [:]).mapValues(JSONValue.string)),
            ])
            guard let encoded = response.object?["data"]?.string, let data = Data(base64Encoded: encoded) else {
                throw URLError(.cannotDecodeContentData)
            }
            return data
        }
        #endif
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    public static func artworkData(for url: URL, headers: [String: String] = [:]) async throws -> Data {
        let settings = load()
        var request = URLRequest(url: artworkURL(url, settings: settings), timeoutInterval: 30)
        request.allHTTPHeaderFields = headers
        if settings.isArtwork(url) { return try await settings.data(for: request, session: .shared) }
        return try await HTTPClient().get(url, headers: headers).0
    }

    /// The poster loader's fetch: same flow as artworkData (same settings, same
    /// proxy behaviour) but on the caller's session in both branches, and with the
    /// TMDB size segment clamped to w780 — the poster decoder caps thumbnails at
    /// 720 px, so originals (0.5–2 MB) buy nothing.
    public static func posterData(for url: URL, headers: [String: String] = [:], session: URLSession) async throws -> Data {
        let settings = load()
        let fetched = Self.clampedPosterURL(artworkURL(url, settings: settings))
        var request = URLRequest(url: fetched, timeoutInterval: 30)
        request.allHTTPHeaderFields = headers
        if settings.isArtwork(url) { return try await settings.data(for: request, session: session) }
        return try await HTTPClient(session: session, mirrors: .shared).get(fetched, headers: headers).0
    }

    private static func clampedPosterURL(_ url: URL) -> URL {
        guard ["image.tmdb.org", "images.tmdb.org"].contains(url.host?.lowercased() ?? "") else { return url }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var segments = parts.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for index in segments.indices.dropLast(2) where segments[index] == "t" && segments[index + 1] == "p" {
            let size = segments[index + 2]
            let oversized = size == "original" || ((size.hasPrefix("w") || size.hasPrefix("h")) && (Int(size.dropFirst()) ?? 0) > 780)
            guard oversized else { return url }
            segments[index + 2] = "w780"
            parts.path = segments.joined(separator: "/")
            return parts.url ?? url
        }
        return url
    }
}
