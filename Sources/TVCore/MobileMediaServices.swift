import Foundation

/// Native UI facade for local MacCat protocol services hosted by the app's embedded Node.
public enum MobileMediaServices {
    public static let videoCacheChanged = Notification.Name("yingxia.video-cache.changed")
    public struct VideoCacheSummary: Sendable {
        public let bytes: Int
        public let hits: Int
        public let written: Int
        public let sessions: Int
    }
    public struct VideoCacheStatistics: Sendable {
        public let networkBytes: Int64
        public let hits: Int64
        public let bytes: Int64
        public let nativeFallback: Bool
    }
    public struct PreparedPlaybackMedia: Sendable {
        public var url: URL
        public var headers: [String: String]
        public var audioURL: URL?
        public var audioHeaders: [String: String]
        public var ownerID: String?
        public var cacheIOURL: URL? = nil
        public var audioCacheIOURL: URL? = nil
    }

    /// Native inputs retain their exact source URLs and independent headers.
    /// Optional byte-cache transports are mapped below the demuxer, not MPD.
    public static func preparePlayable(_ channel: Channel, cacheEnabled: Bool, sizeGB: Int, adClean: Bool, isLive: Bool) async throws -> PreparedPlaybackMedia {
        var url = channel.url, headers = channel.headers
        var descriptor = channel.playback ?? PlaybackDescriptor(format: url.pathExtension)
        if let files = DashStreams.files(for: url), let video = files.video.first {
            url = video; headers = files.headers
            descriptor.format = "mp4"; descriptor.audioURL = files.audio.first; descriptor.audioHeaders = files.headers
        }
        let original = PreparedPlaybackMedia(url: url, headers: headers, audioURL: descriptor.audioURL,
            audioHeaders: descriptor.audioHeaders, ownerID: nil)
        guard ["http", "https"].contains(url.scheme ?? "") else {
            if descriptor.audioURL != nil { throw TVError.unsupported("当前分离音轨需要 HTTP/HTTPS 视频地址，请选择其他线路") }
            return original
        }
        // An MT proxy address is already a local transport minted by the
        // embedded host; preparing it would make the media cache fetch from
        // the proxy (double proxying), so it plays as-is.
        if url.path.hasPrefix("/mt/") { return original }
        let format = descriptor.format.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var hls = ["m3u8", "application/vnd.apple.mpegurl", "application/x-mpegurl"].contains(format) || url.pathExtension.lowercased() == "m3u8"
        let dash = ["mpd", "application/dash+xml"].contains(format) || url.pathExtension.lowercased() == "mpd"
        if isLive && descriptor.audioURL != nil { throw TVError.unsupported("当前直播带有分离音轨，请选择完整音视频线路") }
        if descriptor.audioURL != nil, hls || dash { throw TVError.unsupported("当前播放清单另带分离音轨，暂不支持此组合，请选择完整音视频线路") }
        // Unknown HTTP containers may be HLS dispatchers. The setting also
        // applies when caching is off; keep known file transports free of I/O.
        let containers: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "flv", "webm", "ts", "m2ts", "mpd", "iso", "udf", "bdmv", "mpls", "bluray", "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff", "ape", "video/mp4", "video/x-matroska", "video/mp2t", "video/webm", "audio/mpeg", "audio/mp4", "audio/aac", "audio/flac"]
        // With cache enabled the Node transport sniffs and reuses the first
        // actual response. A separate Range probe would start and immediately
        // cancel a subscription's multithread proxy before playback even opens.
        if adClean, (!cacheEnabled || isLive), !hls, !dash, !containers.contains(format), !containers.contains(url.pathExtension.lowercased()) {
            hls = await MediaPrefixProbe.isHls(url, headers: headers)
            try Task.checkCancellation()
        }
        // No-transform streams must not wait for the optional embedded cache service.
        if !(hls && adClean), isLive || !cacheEnabled { return original }
        let ownerID = UUID().uuidString.lowercased()
        var params: [String: JSONValue] = ["id": .string(ownerID), "url": .string(url.absoluteString),
            "headers": .object(headers.mapValues(JSONValue.string)), "format": .string(hls ? "m3u8" : dash ? "mpd" : descriptor.format),
            "enabled": .bool(cacheEnabled && !isLive), "sizeGB": .number(Double(max(1, min(4, sizeGB)))),
            "isLive": .bool(isLive), "adClean": .bool(adClean), "nativeTracks": .bool(true)]
        if let audio = descriptor.audioURL {
            params["audioUrl"] = .string(audio.absoluteString)
            params["audioHeaders"] = .object((descriptor.audioHeaders.isEmpty ? headers : descriptor.audioHeaders).mapValues(JSONValue.string))
        }
        if let threads = descriptor.threadCount { params["threadCount"] = .number(Double(threads)) }
        if let result = descriptor.resultJSON { params["resultJSON"] = .string(result) }
        if let files = DashStreams.files(for: channel.url), let duration = files.duration { params["duration"] = .number(duration) }
        do {
            let answer = try await call("playback.prepare", params)
            try Task.checkCancellation()
            guard let fields = answer.object, let address = fields["url"]?.string, let preparedURL = URL(string: address) else { throw TVError.invalidURL }
            let owner = fields["ownerID"]?.string
            return PreparedPlaybackMedia(url: preparedURL, headers: fields["headers"]?.object?.compactMapValues(\.string) ?? headers,
                audioURL: fields["audioUrl"]?.string.flatMap(URL.init(string:)) ?? descriptor.audioURL,
                audioHeaders: fields["audioHeaders"]?.object?.compactMapValues(\.string) ?? descriptor.audioHeaders, ownerID: owner,
                cacheIOURL: fields["cacheUrl"]?.string.flatMap(URL.init(string:)),
                audioCacheIOURL: fields["audioCacheUrl"]?.string.flatMap(URL.init(string:)))
        } catch {
            Task { _ = try? await call("playback.release", ["id": .string(ownerID)]) }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if !(hls && adClean) {
                Diagnostics.shared.record(.warning, "player.prepare", "optional cache unavailable; opening direct host=\(url.host() ?? "-")")
                return original
            }
            throw error
        }
    }

    public static func releasePlayback(_ ownerID: String?) async {
        guard let ownerID else { return }
        _ = try? await call("playback.release", ["id": .string(ownerID)])
    }
    public static func configureVideoCache(enabled: Bool, sizeGB: Int) async throws {
        try await configure(["videoCache": .object(["enabled": .bool(enabled),
            "sizeGB": .number(Double(max(1, min(4, sizeGB))))])])
        await MainActor.run {
            NotificationCenter.default.post(name: videoCacheChanged, object: nil, userInfo: ["enabled": enabled])
        }
    }
    public static func videoCacheSummary() async throws -> VideoCacheSummary {
        let values = try await call("playback.cache.stats").object ?? [:]
        func count(_ field: String) -> Int {
            guard case .number(let number) = values[field], number.isFinite, number >= 0, number < Double(Int.max) else { return 0 }
            return Int(number)
        }
        return VideoCacheSummary(bytes: count("bytes"), hits: count("hits"), written: count("written"), sessions: count("sessions"))
    }
    public static func clearVideoCache() async throws { _ = try await call("playback.cache.clear") }
    public static func videoCacheStatistics(_ ownerID: String) async throws -> VideoCacheStatistics {
        guard let values = try await call("playback.cache.stats", ["id": .string(ownerID)]).object else { throw TVError.invalidURL }
        func count(_ field: String) -> Int64 {
            guard case .number(let number) = values[field], number.isFinite, number >= 0, number < Double(Int64.max) else { return 0 }
            return Int64(number)
        }
        let fallback: Bool
        if case .bool(let value) = values["nativeFallback"] { fallback = value } else { fallback = false }
        return VideoCacheStatistics(networkBytes: count("networkBytes"), hits: count("hits"), bytes: count("bytes"), nativeFallback: fallback)
    }
    /// Cancelling this call stops speculative I/O while completed cache blocks remain reusable.
    public static func prefetchPlayback(_ ownerID: String, maxBytes: Int = 15 * 1024 * 1024) async throws {
        _ = try await call("playback.prefetch", ["id": .string(ownerID), "maxBytes": .number(Double(maxBytes))])
    }
    public static func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        #if os(iOS) || os(tvOS)
        return try await EmbeddedNodeHost.shared.mediaService(method, params: params)
        #else
        throw TVError.unsupported("移动媒体服务仅用于 iPhone、iPad 与 Apple TV")
        #endif
    }
    public static func configure(_ values: [String: JSONValue]) async throws {
        _ = try await call("settings.set", values)
    }
}
