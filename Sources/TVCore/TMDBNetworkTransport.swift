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
}
