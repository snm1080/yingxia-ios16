import Foundation
import CryptoKit
import Perception

public struct MediaPushRequest: Codable, Equatable, Sendable {
    public let input: String
    public let title: String
    public let headers: [String: String]
    public let metadataHint: MediaMetadataHint?
    public init(input: String, title: String = "", headers: [String: String] = [:], metadataHint: MediaMetadataHint? = nil) {
        self.input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines); self.headers = headers; self.metadataHint = metadataHint
    }
}

public enum MediaPush {
    public static func sources(_ sites: [Site]) -> [Site] {
        sites.filter { !$0.api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            ($0.sourceKey.localizedCaseInsensitiveContains("push") || $0.sourceKey == "推送" ||
             $0.name.contains("推送") || $0.name.range(of: "(?:^|[\\s_/:.-])push(?:$|[\\s_/:.-])", options: [.regularExpression, .caseInsensitive]) != nil) }
    }
    public static func supported(_ value: JSONValue) -> Bool? {
        var scalar = value
        for _ in 0..<4 {
            guard let next = scalar.object?["supported"] else { break }; scalar = next
        }
        if scalar == .bool(false) || scalar.string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "false" { return false }
        if scalar == .bool(true) || scalar.string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" { return true }
        return nil
    }
    public static func requiresFiles(_ input: String) -> Bool {
        if input.lowercased().hasPrefix("magnet:") || input.lowercased().hasPrefix("ed2k:") { return true }
        guard let host = URL(string: input)?.host?.lowercased() else { return false }
        if host == "caiyun.feixin.10086.cn" { return true }
        return host.range(of: "(?:^|\\.)(?:quark\\.cn|qoark\\.cn|uc\\.cn|baidu\\.com|189\\.cn|139\\.com|xunlei\\.com|alipan\\.com|aliyundrive\\.com|115\\.com|115cdn\\.com|anxia\\.com|pikpak\\.com|mypikpak\\.com|guangyapan\\.com|123(?:pan|684|865|685|912|592)\\.(?:com|cn))$", options: .regularExpression) != nil
    }
    public static func directVideo(_ request: MediaPushRequest, sniff: Bool = false) throws -> Video {
        guard let url = URL(string: request.input), url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !requiresFiles(request.input) else { throw TVError.unsupported("网盘分享和磁力链接请通过推送站点解析") }
        let digest = SHA256.hash(data: Data(request.input.utf8)).map { String(format: "%02x", $0) }.joined()
        let id = "local-media-" + String(digest.prefix(24))
        return Video(id: id, name: request.title.isEmpty ? url.lastPathComponent : request.title,
                     episodes: [Episode(id: id + "-0", name: request.title.isEmpty ? "播放" : request.title, address: request.input,
                                        flag: sniff ? "嗅探" : "直链", videoID: id)])
    }
    public static func applyingTitle(_ title: String, to video: Video) -> Video {
        guard !title.isEmpty else { return video }
        return Video(id: video.id, name: title, poster: video.poster, posterHeaders: video.posterHeaders, year: video.year,
                     remarks: video.remarks, synopsis: video.synopsis, episodes: video.episodes, category: video.category,
                     action: video.action, folderCategoryID: video.isFolder ? video.folderCategoryID : nil, folderFilters: video.folderFilters,
                     area: video.area, director: video.director, actor: video.actor)
    }
    public static func applyingMetadata(_ request: MediaPushRequest, to video: Video) -> Video {
        let named = applyingTitle(request.title, to: video)
        guard let hint = request.metadataHint, hint.id > 0 else { return named }
        return PosterPresentation.applying(hint.poster, headers: hint.posterHeaders ?? [:], to: named)
    }
}

/// Retain the original subscribed push input so reopening a title refreshes the same share.
/// Resolved stream URLs and authorization headers never enter this document.
public final class PushMediaLibrary: @unchecked Sendable {
    public struct Artwork: Codable, Equatable, Sendable {
        public let poster: URL?
        public let headers: [String: String]
        public let isConfirmed: Bool?
        public let confirmedAt: Date?
    }
    public struct Record: Codable, Sendable {
        public let input: String
        public let flags: [String]
        public let metadataHint: MediaMetadataHint?
        public let title: String?
        public let artwork: Artwork?
    }
    public static let shared = PushMediaLibrary(directory: URL.applicationSupportDirectory.appendingPathComponent("PushMediaLibrary", isDirectory: true))
    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL) { self.directory = directory }
    private func file(origin: URL, sourceKey: String, videoID: String) -> URL {
        let key = EpisodeSkipSettings.scope(origin: origin, source: sourceKey, video: videoID)
        return directory.appendingPathComponent(PluginChecksum.sha256(Data(key.utf8)) + ".json")
    }
    public func register(_ request: MediaPushRequest, video: Video, client: CatalogClient) throws {
        var seen = Set<String>()
        let flags = video.episodes.map(\.flag).filter { seen.insert($0).inserted }
        try lock.withLock {
            let destination = file(origin: client.origin, sourceKey: client.site.sourceKey, videoID: video.id)
            let prior = read(destination)
            let inherited = prior?.input == request.input && prior?.title == request.title ? prior?.artwork : nil
            let sameWork = prior?.metadataHint?.id == request.metadataHint?.id &&
                prior?.metadataHint?.mediaType == request.metadataHint?.mediaType
            let supplied = request.metadataHint.flatMap { hint -> Artwork? in
                guard hint.id > 0, let poster = PosterPresentation.imageURL(hint.poster, excluding: [request.input, video.id]) else { return nil }
                return Artwork(poster: poster, headers: PosterPresentation.imageHeaders(hint.posterHeaders ?? [:]), isConfirmed: true, confirmedAt: Date())
            }
            let artwork: Artwork?
            if sameWork, let inherited { artwork = inherited }
            else if request.metadataHint != nil, !sameWork, supplied == nil {
                // A different work has no image yet. Keep an explicit empty decision newer than the
                // former work's cover, so the next history tick cannot inherit that previous image.
                let decidedAt = max(Date(), (prior?.artwork?.confirmedAt ?? .distantPast).addingTimeInterval(0.001))
                artwork = Artwork(poster: nil, headers: [:], isConfirmed: false, confirmedAt: decidedAt)
            } else { artwork = supplied ?? inherited }
            let value = Record(input: request.input, flags: flags.isEmpty ? ["push"] : flags, metadataHint: request.metadataHint,
                               title: request.title, artwork: artwork)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: destination, options: .atomic)
        }
    }
    public func record(origin: URL, sourceKey: String, videoID: String) -> Record? {
        lock.withLock { read(file(origin: origin, sourceKey: sourceKey, videoID: videoID)) }
    }
    /// A confirmed match belongs to this exact original catalog, never a merged source's temporary
    /// display key. Optional enrichment must not rewrite the share, password or provider file flags.
    public func updateArtwork(origin: URL, sourceKey: String, videoID: String, poster: URL, headers: [String: String] = [:],
                              decidedAt: Date = Date()) {
        guard let poster = PosterPresentation.imageURL(poster, excluding: [videoID]) else { return }
        decideArtwork(origin: origin, sourceKey: sourceKey, videoID: videoID, poster: poster, headers: headers, confirmed: true, decidedAt: decidedAt)
    }
    public func resetArtwork(origin: URL, sourceKey: String, videoID: String, poster: URL? = nil, headers: [String: String] = [:],
                             decidedAt: Date = Date()) {
        decideArtwork(origin: origin, sourceKey: sourceKey, videoID: videoID, poster: poster, headers: headers, confirmed: false, decidedAt: decidedAt)
    }
    private func decideArtwork(origin: URL, sourceKey: String, videoID: String, poster: URL?, headers: [String: String],
                               confirmed: Bool, decidedAt: Date) {
        lock.withLock {
            let destination = file(origin: origin, sourceKey: sourceKey, videoID: videoID)
            guard let current = read(destination) else { return }
            let cleanHeaders = PosterPresentation.imageHeaders(headers)
            guard current.artwork?.confirmedAt == nil || (current.artwork?.confirmedAt ?? .distantPast) <= decidedAt else { return }
            let artwork = Artwork(poster: PosterPresentation.imageURL(poster), headers: cleanHeaders, isConfirmed: confirmed, confirmedAt: decidedAt)
            let next = Record(input: current.input, flags: current.flags, metadataHint: current.metadataHint, title: current.title, artwork: artwork)
            try? JSONEncoder().encode(next).write(to: destination, options: .atomic)
        }
    }
    private func read(_ file: URL) -> Record? {
        guard let data = try? Data(contentsOf: file), data.count <= 128 * 1024 else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }
}

/// User-opened original media inputs, independent of disposable stream/cache data.
/// A restored webpage is sniffed again; the resolved CDN address is never registered here.
public final class LocalMediaLibrary: @unchecked Sendable {
    public enum Mode: String, Codable, Sendable { case direct, sniff, file }
    public struct Record: Codable, Sendable {
        public let request: MediaPushRequest
        public let mode: Mode
        public let video: Video
        /// HTML resolvers own fresh media addresses. Saved rows retain the source
        /// identity, but must not feed their old webpage or expiring CDN to a player.
        public let requiresHTMLSelection: Bool?
        public let htmlHome: HTMLHomePlayback.History?
        public var site: Site {
            Site(key: mode == .file ? "local.media.file" : "local.media.url", name: mode == .sniff ? "网页嗅探" : "本地播放",
                 type: 1, api: LocalMediaLibrary.origin.appendingPathComponent("media").absoluteString,
                 raw: ["header": .object(request.headers.mapValues(JSONValue.string)), "requiresWebDetection": .bool(mode == .sniff)])
        }
    }
    public static let origin = URL(string: "https://local.invalid/")!
    public static let shared = LocalMediaLibrary(directory: URL.applicationSupportDirectory.appendingPathComponent("LocalMediaLibrary", isDirectory: true))
    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL) { self.directory = directory }
    public static func isLocalSource(_ sourceKey: String) -> Bool { ["local.media.url", "local.media.file"].contains(sourceKey) }
    private func file(sourceKey: String, id: String) -> URL {
        directory.appendingPathComponent(PluginChecksum.sha256(Data((sourceKey + "\n" + id).utf8)) + ".json")
    }
    @discardableResult public func register(_ request: MediaPushRequest, mode: Mode) throws -> Record {
        let original = try MediaPush.directVideo(request, sniff: mode == .sniff)
        let id = original.id + "-" + mode.rawValue
        let video = Video(id: id, name: original.name, poster: original.poster, posterHeaders: original.posterHeaders,
                          year: original.year, remarks: original.remarks, synopsis: original.synopsis,
                          episodes: original.episodes.map { .init(id: $0.id + "-" + mode.rawValue, name: $0.name, address: $0.address, flag: $0.flag, videoID: id) })
        let record = Record(request: request, mode: mode, video: video, requiresHTMLSelection: nil, htmlHome: nil)
        try save(record)
        return record
    }
    @discardableResult public func registerHTML(_ request: MediaPushRequest, video: Video, htmlHome: HTMLHomePlayback.History? = nil) throws -> Record {
        guard !request.input.lowercased().hasPrefix("data:"), !video.episodes.isEmpty, video.episodes.count <= 1000,
              video.episodes.allSatisfy({ !$0.address.lowercased().hasPrefix("data:") }) else {
            throw TVError.unsupported("首页播放记录缺少可重新打开的资源标识")
        }
        if let htmlHome {
            guard !htmlHome.sourceID.isEmpty, htmlHome.sourceID.utf8.count <= 128, htmlHome.workID.utf8.count <= 32768,
                  htmlHome.episodes.count == video.episodes.count,
                  zip(htmlHome.episodes, video.episodes).allSatisfy({ reference, episode in
                      reference.id == episode.id && reference.name == episode.name && reference.pageURL == episode.address
                          && HTMLHomePlayback.resolverIdentity(reference.resolverURL, pageURL: reference.pageURL) == reference.resolverURL
                  }) else { throw TVError.unsupported("首页播放记录的来源或集数标识无效") }
        }
        let record = Record(request: request, mode: .direct, video: video, requiresHTMLSelection: true, htmlHome: htmlHome)
        try save(record)
        return record
    }
    private func save(_ record: Record) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: file(sourceKey: record.site.key, id: record.video.id), options: .atomic)
        }
    }
    public func record(sourceKey: String, id: String) -> Record? {
        guard Self.isLocalSource(sourceKey) else { return nil }
        return lock.withLock {
            guard let data = try? Data(contentsOf: file(sourceKey: sourceKey, id: id)), data.count <= 1024 * 1024,
                  let record = try? JSONDecoder().decode(Record.self, from: data), record.video.id == id, record.site.key == sourceKey else { return nil }
            return record
        }
    }
    public func video(sourceKey: String, id: String) -> Video? { record(sourceKey: sourceKey, id: id)?.video }
    public func client(sourceKey: String, videoID: String) -> CatalogClient? {
        guard let record = record(sourceKey: sourceKey, id: videoID) else { return nil }
        let client = CatalogClient(site: record.site, origin: Self.origin)
        return record.requiresHTMLSelection == true ? client.withLocalPlaybackPlans([:]) : client
    }
}

@MainActor @Perceptible public final class MediaPushModel {
    public private(set) var request: MediaPushRequest?
    public private(set) var video: Video?
    public private(set) var busy = false
    public private(set) var phase = ""
    public private(set) var error: String?
    private var generation = 0
    public init() {}
    public func cancel() { generation += 1; busy = false; phase = ""; video = nil; error = nil }
    public func resolve(_ value: MediaPushRequest, client: CatalogClient) async {
        await resolve(value, support: { try await client.pushSupport($0) }, detail: { try await client.pushDetail($0) })
    }
    public func resolve(_ value: MediaPushRequest, support: @escaping @Sendable (String) async throws -> Bool?, detail: @escaping @Sendable (String) async throws -> Video) async {
        generation += 1; let own = generation
        request = value; busy = true; video = nil; error = nil; phase = "检查站点支持"
        defer { if own == generation { busy = false; phase = "" } }
        do {
            guard !value.input.isEmpty else { throw TVError.unsupported("请输入推送链接") }
            let supported = try await support(value.input)
            guard own == generation, !Task.isCancelled else { return }
            guard supported != false else { throw TVError.unsupported("当前订阅未启用或不支持该网盘，请检查推送站点设置") }
            phase = "读取资源文件"
            for attempt in 0..<4 {
                let parsed = try await detail(value.input)
                guard own == generation, !Task.isCancelled else { return }
                let valid = parsed.episodes.filter { !$0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if parsed.isFolder || !valid.isEmpty {
                    let clean = Video(id: parsed.id, name: parsed.name, poster: parsed.poster, posterHeaders: parsed.posterHeaders,
                                      year: parsed.year, remarks: parsed.remarks, synopsis: parsed.synopsis, episodes: valid,
                                      category: parsed.category, action: parsed.action, folderCategoryID: parsed.isFolder ? parsed.folderCategoryID : nil, folderFilters: parsed.folderFilters,
                                      area: parsed.area, director: parsed.director, actor: parsed.actor)
                    video = MediaPush.applyingMetadata(value, to: clean); return
                }
                if !MediaPush.requiresFiles(value.input) { video = MediaPush.applyingMetadata(value, to: parsed); return }
                if attempt < 3 { try await Task.sleep(for: .seconds(1)) }
            }
            throw TVError.unsupported("网盘分享或离线解析未返回可播放文件，请检查分享链接和提取码，或稍后重试")
        } catch { if own == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
