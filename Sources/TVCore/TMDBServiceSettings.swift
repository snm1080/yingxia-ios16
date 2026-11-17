import Foundation
import CryptoKit

/// The switch selects the service independently from the retained custom configuration.
public struct TMDBServiceSettings: Codable, Equatable, Sendable {
    public static let defaultAPIBase = "https://api.themoviedb.org/3"
    public static let defaultImageBase = "https://image.tmdb.org/t/p"
    public var enabled: Bool
    public var ultraHD: Bool
    public var apiBase: String
    public var apiKey: String
    public var token: String
    public var imageBase: String
    public var language: String
    public var proxyEnabled: Bool
    public var proxyUrl: String
    public var proxyUsername: String
    public var proxyPassword: String
    private static let key = "local.tmdb.custom.v1"
    public static let changed = Notification.Name("LocalTMDBConfigurationChanged")
    public static var identity: String { load().serviceIdentity }
    public var serviceIdentity: String {
        guard var service = custom else { return "builtin" }
        // Image quality must not invalidate manual title matching and exclusions.
        service.ultraHD = false
        service.proxyEnabled = false; service.proxyUrl = ""; service.proxyUsername = ""; service.proxyPassword = ""
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(service) else { return "builtin" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public init(apiBase: String = "", apiKey: String = "", token: String = "", imageBase: String = "", language: String = "zh-CN", enabled: Bool? = nil, ultraHD: Bool = false,
                proxyEnabled: Bool = false, proxyUrl: String = "", proxyUsername: String = "", proxyPassword: String = "") {
        self.enabled = enabled ?? (!apiBase.isEmpty || !apiKey.isEmpty || !token.isEmpty)
        self.ultraHD = ultraHD
        self.apiBase = apiBase; self.apiKey = apiKey; self.token = token; self.imageBase = imageBase; self.language = language
        self.proxyEnabled = proxyEnabled; self.proxyUrl = proxyUrl; self.proxyUsername = proxyUsername; self.proxyPassword = proxyPassword
    }
    private enum CodingKeys: String, CodingKey { case enabled, ultraHD, apiBase, apiKey, token, imageBase, language, proxyEnabled, proxyUrl, proxyUsername, proxyPassword }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(apiBase: try values.decodeIfPresent(String.self, forKey: .apiBase) ?? "",
                  apiKey: try values.decodeIfPresent(String.self, forKey: .apiKey) ?? "",
                  token: try values.decodeIfPresent(String.self, forKey: .token) ?? "",
                  imageBase: try values.decodeIfPresent(String.self, forKey: .imageBase) ?? "",
                  language: try values.decodeIfPresent(String.self, forKey: .language) ?? "zh-CN",
                  enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled),
                  ultraHD: try values.decodeIfPresent(Bool.self, forKey: .ultraHD) ?? false,
                  proxyEnabled: try values.decodeIfPresent(Bool.self, forKey: .proxyEnabled) ?? false,
                  proxyUrl: try values.decodeIfPresent(String.self, forKey: .proxyUrl) ?? "",
                  proxyUsername: try values.decodeIfPresent(String.self, forKey: .proxyUsername) ?? "",
                  proxyPassword: try values.decodeIfPresent(String.self, forKey: .proxyPassword) ?? "")
    }
    public var credential: String {
        get { token.isEmpty ? apiKey : token }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let bearer = value.lowercased().hasPrefix("bearer ")
            let secret = bearer ? String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces) : value
            if bearer || secret.split(separator: ".").count == 3 || secret.count > 64 {
                token = secret; apiKey = ""
            } else { apiKey = secret; token = "" }
        }
    }
    public var custom: Self? { enabled ? cleaned : nil }
    private var cleaned: Self {
        func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Self(apiBase: trim(apiBase).isEmpty ? Self.defaultAPIBase : trim(apiBase), apiKey: trim(apiKey), token: trim(token),
                    imageBase: trim(imageBase).isEmpty ? Self.defaultImageBase : trim(imageBase), language: trim(language).isEmpty ? "zh-CN" : trim(language),
                    enabled: enabled, ultraHD: ultraHD, proxyEnabled: proxyEnabled, proxyUrl: trim(proxyUrl),
                    proxyUsername: trim(proxyUsername), proxyPassword: proxyPassword)
    }
    public static func load(defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    public func save(defaults: UserDefaults = .standard) throws {
        let value = cleaned
        if value.enabled {
            _ = try value.request(path: "configuration", parameters: [:])
            _ = try Self.webURL(value.imageBase)
            _ = try value.proxyConfiguration()
        }
        guard !value.apiKey.contains(where: { $0.isNewline }), !value.token.contains(where: { $0.isNewline }) else { throw URLError(.badURL) }
        defaults.set(try JSONEncoder().encode(value), forKey: Self.key)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func webURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else { throw URLError(.badURL) }
        return url
    }
    public func proxyConfiguration() throws -> [String: String]? {
        guard enabled && proxyEnabled else { return nil }
        guard let url = URL(string: proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https", "socks5"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.port != 0,
              !proxyUsername.contains(where: { $0.isNewline || $0 == ":" || $0 == "\0" }),
              !proxyPassword.contains(where: { $0.isNewline || $0 == "\0" }),
              proxyPassword.isEmpty || !proxyUsername.isEmpty,
              url.scheme?.lowercased() != "socks5" || (proxyUsername.utf8.count <= 255 && proxyPassword.utf8.count <= 255) else {
            throw URLError(.badURL)
        }
        return ["url": url.absoluteString, "username": proxyUsername, "password": proxyPassword]
    }
    public func isArtwork(_ url: URL) -> Bool {
        [Self.defaultImageBase, cleaned.imageBase].contains { base in
            guard let candidate = URL(string: base) else { return false }
            let prefix = "/" + candidate.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return url.scheme?.lowercased() == candidate.scheme?.lowercased() && url.host?.lowercased() == candidate.host?.lowercased()
                && url.port == candidate.port && url.path.hasPrefix(prefix == "/" ? prefix : prefix + "/")
        }
    }
    public func request(path: String, parameters: [String: String]) throws -> URLRequest {
        let value = cleaned
        let base = try Self.webURL(value.apiBase.isEmpty ? "https://api.themoviedb.org/3" : value.apiBase)
        var parts = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        var values = parameters
        if !value.language.isEmpty { values["language"] = value.language }
        if value.token.isEmpty, !value.apiKey.isEmpty { values["api_key"] = value.apiKey }
        parts.queryItems = (parts.queryItems ?? []) + values.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !value.token.isEmpty { request.setValue("Bearer " + value.token, forHTTPHeaderField: "Authorization") }
        return request
    }
    /// Apply the poster quality to both built-in service URLs and custom image mirrors.
    public static func artworkURL(_ url: URL, settings: Self? = nil) -> URL {
        let config = settings ?? load()
        guard config.enabled && config.ultraHD else { return url }
        let customBase = URL(string: config.cleaned.imageBase)
        guard ["image.tmdb.org", "images.tmdb.org"].contains(url.host ?? "") ||
                (config.enabled && url.host == customBase?.host && url.path.hasPrefix(customBase?.path ?? "/t/p")) else { return url }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.path = parts.path.replacingOccurrences(of: #"/(?:w[0-9]+|h[0-9]+)/"#, with: "/original/", options: .regularExpression)
        return parts.url ?? url
    }
    func image(_ path: String?, size: String = "w500") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let url = URL(string: path), ["https", "http"].contains(url.scheme ?? "") { return url }
        let base = cleaned.imageBase
        return URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + size + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
