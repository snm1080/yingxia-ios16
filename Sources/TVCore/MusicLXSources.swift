import Foundation

/// LX Music (洛雪音乐) custom sources: scripts a listener imports that turn a catalog song ID into an
/// audio address, as in LX Music's "custom source" setting. Yingxia ships none. Each runs on QuickJS
/// with the `lx` object of LX Music desktop's user API (ScriptAssets/lx/lx.js), and the enabled ones
/// are one more channel, `MusicProviderID.lx`, tried alongside built-in channels. Nothing runs until
/// a source is imported, and a source's runtime starts only when a song first needs it.

/// The comment LX Music reads at the top of a source: `@name`, `@description`, `@version`, `@author`, `@homepage`.
public struct LXSourceInfo: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var version: String
    public var author: String
    public var homepage: String

    public init(name: String, description: String = "", version: String = "", author: String = "", homepage: String = "") {
        self.name = name; self.description = description; self.version = version; self.author = author; self.homepage = homepage
    }

    /// Reads the header comment, which must open the script; LX Music's own length limits apply.
    public init(script: String) {
        var fields: [String: String] = [:]
        let text = script.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        if text.hasPrefix("/*"), let end = text.range(of: "*/") {
            for line in text[text.index(text.startIndex, offsetBy: 2)..<end.lowerBound].split(whereSeparator: \.isNewline) {
                let content = line.drop { $0 == " " || $0 == "\t" || $0 == "*" || $0 == "!" }
                guard content.hasPrefix("@") else { continue }
                let parts = content.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard parts.count == 2 else { continue }
                let key = String(parts[0]), value = parts[1].trimmingCharacters(in: .whitespaces)
                if fields[key] == nil, !value.isEmpty { fields[key] = value }
            }
        }
        func field(_ key: String, _ limit: Int) -> String { String((fields[key] ?? "").prefix(limit)) }
        let name = field("name", 24)
        self.init(name: name.isEmpty ? L10n.text("LX Music Source") : name, description: field("description", 36), version: field("version", 36),
                  author: field("author", 56), homepage: field("homepage", 1024))
    }
}

/// LX Music's catalog keys, kept distinct from the app's persisted platform identifiers.
public enum LXSourceKey {
    public static func platform(_ key: String) -> MusicPlatform? {
        switch key {
        case "tx": .qq
        case "wy": .netease
        case "kw": .kuwo
        case "mg": .migu
        case "kg": .kugou
        default: nil
        }
    }

    public static func key(_ platform: MusicPlatform) -> String {
        switch platform {
        case .qq: "tx"
        case .netease: "wy"
        case .kuwo: "kw"
        case .migu: "mg"
        case .kugou: "kg"
        case .ext: ""
        }
    }

    /// The quality a lookup asks for: lossless at CD quality first, as the other channels do; the
    /// stream is probed anyway. High and Standard ask only for a lossy tier the source declared,
    /// and a source with none is skipped rather than sent lossless audio the viewer chose to avoid.
    public static func quality(from declared: [String], for quality: MusicAudioQuality) -> String? {
        qualities(from: declared, for: quality).first
    }

    public static func qualities(from declared: [String], for quality: MusicAudioQuality) -> [String] {
        if declared.isEmpty {
            switch quality {
            case .lossless, .high: return ["320k", "128k"]
            case .standard: return ["128k"]
            }
        }
        switch quality {
        case .lossless: return ["flac", "flac24bit", "hires", "24bit", "320k", "192k", "128k"].filter(declared.contains)
        case .high: return ["320k", "192k", "128k"].filter(declared.contains)
        case .standard: return ["128k"].filter(declared.contains)
        }
    }

    /// The `musicInfo` an LX source receives, in LX Music's format, from what the catalog listed.
    public static func musicInfo(songID: String, platform: MusicPlatform, track: MusicTrack?) -> [String: JSONValue] {
        var info = track?.lxInfo(for: platform) ?? [:]
        info["source"] = .string(key(platform))
        if info["songmid"] == nil { info["songmid"] = .string(songID) }
        switch platform {
        case .migu:
            // Prefer the actual recording ID from the catalog. Older saved songs only have the
            // content/copyright pair, which remains available until metadata can be refreshed.
            if let ids = MiguMusicCatalog.ids(songID) {
                if track?.lxInfo(for: platform)?["songmid"] == nil { info["songmid"] = .string(ids.copyright) }
                if info["copyrightId"] == nil { info["copyrightId"] = .string(ids.copyright) }
                if info["contentId"] == nil { info["contentId"] = .string(ids.content) }
            } else if info["copyrightId"] == nil { info["copyrightId"] = .string(songID) }
        case .qq:
            if info["strMediaMid"] == nil { info["strMediaMid"] = info["file"]?["media_mid"] }
        case .kugou:
            if info["hash"] == nil { info["hash"] = .string(songID) }
            if info["_types"] == nil { info["_types"] = .object(["128k": .object(["hash": info["hash"]!])]) }
        case .kuwo:
            if info["rid"] == nil { info["rid"] = .string(songID) }
            if info["songId"] == nil { info["songId"] = .string(songID) }
        case .netease:
            if info["songId"] == nil { info["songId"] = .string(songID) }
        case .ext: break
        }
        if info["name"] == nil { info["name"] = .string(track?.title ?? "") }
        if info["singer"] == nil { info["singer"] = .string(track?.artists.joined(separator: "、") ?? "") }
        if info["albumName"] == nil { info["albumName"] = .string(track?.album ?? "") }
        if info["img"] == nil { info["img"] = .string(track?.artwork?.absoluteString ?? "") }
        if info["interval"] == nil, let seconds = track?.duration, seconds.isFinite, seconds > 0, seconds < 604_800 {
            let whole = Int(seconds.rounded())
            info["interval"] = .string(String(format: "%02d:%02d", whole / 60, whole % 60))
        } else if info["interval"] == nil { info["interval"] = .string("") }
        if let seconds = info["interval"]?.double, seconds.isFinite, seconds >= 0, seconds < 86_400 {
            let whole = Int(seconds.rounded())
            info["interval"] = .string(String(format: "%02d:%02d", whole / 60, whole % 60))
        }
        if info["types"] == nil {
            info["types"] = .array((info["_types"]?.object ?? [:]).keys.sorted().map { key in
                var entry = info["_types"]?[key]?.object ?? [:]
                entry["type"] = .string(key)
                return .object(entry)
            })
        }
        if info["_types"] == nil { info["_types"] = .object([:]) }
        if info["typeUrl"] == nil { info["typeUrl"] = .object([:]) }
        return info
    }
}

struct LXSourceDeclaration: Sendable {
    var sources: [String: [String]]
    var actions: [String: [String]]
}

/// One imported source.
public struct LXSource: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var info: LXSourceInfo
    /// The LX catalog keys that answer `musicUrl`, each with the qualities it declared.
    public var sources: [String: [String]]
    /// Nil for old imports; re-read their declarations on first use.
    public var actions: [String: [String]]?
    /// Where it was imported from, to fetch it again if the system cleared its copy (tvOS keeps files in Caches).
    public var origin: URL?
    public var enabled: Bool
    public var added: Date

    public init(id: String = UUID().uuidString, info: LXSourceInfo, sources: [String: [String]], origin: URL?, enabled: Bool = true, added: Date = Date(), actions: [String: [String]]? = nil) {
        self.id = id; self.info = info; self.sources = sources; self.origin = origin; self.enabled = enabled; self.added = added
        self.actions = actions
    }

    public func supports(_ action: String, key: String) -> Bool {
        if let actions { return actions[key]?.contains(action) == true }
        return action == "musicUrl" && sources[key] != nil
    }

    /// The catalogs it can play, in the app's order.
    public var platforms: [MusicPlatform] { MusicPlatform.allCases.filter { sources[LXSourceKey.key($0)] != nil } }
}

/// The imported sources: a small list in user defaults and each script in a file.
public final class LXSourceLibrary: @unchecked Sendable {
    public static let shared = LXSourceLibrary(folder: LXSourceLibrary.defaultFolder, defaults: .standard)
    static var defaultFolder: URL {
        #if os(tvOS)
        // tvOS only permits Caches; a cleared script is fetched again from where it came from.
        URL.cachesDirectory.appending(path: "com.tvbox.yingxia/LXSources", directoryHint: .isDirectory)
        #else
        URL.applicationSupportDirectory.appending(path: "com.tvbox.yingxia/LXSources", directoryHint: .isDirectory)
        #endif
    }
    static let defaultsKey = "musicLXSources"
    /// LX Music refuses larger scripts too.
    static let scriptLimit = 9_000_000

    private let folder: URL
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: [LXSource]?

    public init(folder: URL, defaults: UserDefaults) { self.folder = folder; self.defaults = defaults }

    public var sources: [LXSource] {
        lock.withLock {
            if let cached { return cached }
            let loaded = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([LXSource].self, from: $0) } ?? []
            cached = loaded
            return loaded
        }
    }

    public var enabled: [LXSource] { sources.filter(\.enabled) }

    /// Starts `script`, keeps it when it declares at least one catalog the app searches, and returns it.
    @discardableResult
    public func add(script: String, origin: URL?, runtime: LXSourceRuntime = .shared) async throws -> LXSource {
        guard !script.isEmpty, script.utf8.count <= Self.scriptLimit else { throw TVError.unsupported(L10n.text("This file is not an LX Music source.")) }
        let info = LXSourceInfo(script: script)
        var source = LXSource(info: info, sources: [:], origin: origin)
        let declared = try await runtime.start(source, script: script)
        source.sources = declared.sources.filter { LXSourceKey.platform($0.key) != nil }
        source.actions = declared.actions.filter { LXSourceKey.platform($0.key) != nil }
        guard !source.sources.isEmpty else {
            await runtime.close(source.id)
            throw TVError.unsupported(L10n.text("This source has no supported music catalog."))
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: file(source.id), options: .atomic)
        } catch { await runtime.close(source.id); throw error }
        update { $0.append(source) }
        Diagnostics.shared.record(.info, "music", "lx source added: \(source.sources.keys.sorted().joined(separator: ","))")
        return source
    }

    public func setEnabled(_ id: String, _ enabled: Bool) {
        update { list in
            if let index = list.firstIndex(where: { $0.id == id }) { list[index].enabled = enabled }
        }
        if !enabled { Task { await LXSourceRuntime.shared.close(id) } }
    }

    /// Upgrade old declarations in place; scripts remain the user's local copies.
    func record(_ declaration: LXSourceDeclaration, sourceID: String) {
        update { list in
            guard let index = list.firstIndex(where: { $0.id == sourceID }) else { return }
            list[index].sources = declaration.sources
            list[index].actions = declaration.actions
        }
    }

    public func remove(_ id: String) {
        update { $0.removeAll { $0.id == id } }
        try? FileManager.default.removeItem(at: file(id))
        Task { await LXSourceRuntime.shared.close(id) }
    }

    /// The script, fetched again from its origin when the system cleared the copy.
    func script(for source: LXSource) async throws -> String {
        if let data = try? Data(contentsOf: file(source.id)) { return String(decoding: data, as: UTF8.self) }
        guard let origin = source.origin else { throw MusicProviderError.noResource }
        let script = try await Self.download(origin)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(script.utf8).write(to: file(source.id), options: .atomic)
        return script
    }

    /// A source's text from an HTTP or HTTPS address.
    public static func download(_ url: URL, transport: MusicTransport = URLSessionMusicTransport()) async throws -> String {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw TVError.invalidURL }
        let response = try await MusicHTTP.withTimeout(30) { try await transport.send(MusicHTTP.request(url, timeout: 30), limit: scriptLimit + 1) }
        guard (200..<300).contains(response.status) else { throw TVError.http(response.status) }
        guard response.body.count <= scriptLimit, let text = String(data: response.body, encoding: .utf8), !text.isEmpty else {
            throw TVError.unsupported(L10n.text("This file is not an LX Music source."))
        }
        return text
    }

    private func file(_ id: String) -> URL { folder.appending(path: id + ".js") }

    private func update(_ change: (inout [LXSource]) -> Void) {
        lock.withLock {
            var list = cached ?? defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([LXSource].self, from: $0) } ?? []
            change(&list)
            cached = list
            if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.defaultsKey) }
        }
    }
}

/// The sources' QuickJS runtimes, started on first use and kept for the next song.
public actor LXSourceRuntime {
    public static let shared = LXSourceRuntime()
    private var sessions: [String: ScriptSession] = [:]
    private var declarations: [String: LXSourceDeclaration] = [:]
    private var starting: [String: Task<LXSourceDeclaration, Error>] = [:]
    private var startupWaiters: [String: Set<UUID>] = [:]
    private var generations: [String: UUID] = [:]
    private var recent: [String] = []
    private var active: [String: Int] = [:]
    static let maximumSessions = 3
    /// A lookup's share of the resolver's eight seconds per channel.
    static let lookupSeconds: Double = 7.5

    public init() {}

    /// Runs `script` and answers what its `inited` event declared: LX catalog key → qualities.
    func start(_ source: LXSource, script: String, seconds: Double = 20) async throws -> LXSourceDeclaration {
        close(source.id)
        let generation = UUID()
        generations[source.id] = generation
        return try await boot(source, script: script, generation: generation, seconds: seconds)
    }

    private func boot(_ source: LXSource, script: String, generation: UUID, seconds: Double) async throws -> LXSourceDeclaration {
        let deadline = Date().addingTimeInterval(seconds)
        guard generations[source.id] == generation, !Task.isCancelled else { throw CancellationError() }
        let info = String(decoding: (try? JSONEncoder().encode(source.info)) ?? Data("{}".utf8), as: UTF8.self)
        let profile = ScriptAssets.profiles.appendingPathComponent("lx-" + source.id, isDirectory: true)
        let session = try await ScriptSession.start(module: "assets://lx/lx.js", supplied: ["lx://script": script, "lx://info": info],
                                                    profile: profile, label: "lx " + source.info.name)
        guard generations[source.id] == generation, !Task.isCancelled else { session.close(); throw CancellationError() }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { session.close(); throw MusicProviderError.timeout }
        let envelope = await session.evaluate("__lx.load()", within: remaining, cancellable: true)
        guard generations[source.id] == generation, !Task.isCancelled else { session.close(); throw CancellationError() }
        guard let sources = envelope["value"]?["sources"]?.object else {
            session.close()
            let reason = envelope["value"]?["error"]?.string ?? envelope["error"]?.string ?? ""
            throw TVError.unsupported(L10n.text("The LX Music source did not start: %@", String(reason.prefix(200))))
        }
        let actions = envelope["value"]?["actions"]?.object ?? [:]
        let declaration = LXSourceDeclaration(sources: sources.mapValues { $0.array?.compactMap(\.string) ?? [] },
                                              actions: actions.mapValues { $0.array?.compactMap(\.string) ?? [] })
        declarations[source.id] = declaration
        keep(session, for: source.id)
        return declaration
    }

    func declaration(_ source: LXSource, library: LXSourceLibrary, seconds: Double = 4) async throws -> LXSourceDeclaration {
        try Task.checkCancellation()
        if let declaration = declarations[source.id], sessions[source.id] != nil { return declaration }
        if let work = starting[source.id], !work.isCancelled {
            return try await awaitStartup(work, sourceID: source.id)
        }
        starting[source.id] = nil
        let generation = UUID()
        generations[source.id] = generation
        let work = Task { () throws -> LXSourceDeclaration in
            let deadline = Date().addingTimeInterval(seconds)
            let script = try await MusicHTTP.withTimeout(seconds) { try await library.script(for: source) }
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw MusicProviderError.timeout }
            return try await boot(source, script: script, generation: generation, seconds: remaining)
        }
        starting[source.id] = work
        do {
            let result = try await awaitStartup(work, sourceID: source.id)
            if generations[source.id] == generation { starting[source.id] = nil }
            library.record(result, sourceID: source.id)
            try Task.checkCancellation()
            return result
        } catch {
            if generations[source.id] == generation { starting[source.id] = nil }
            throw error
        }
    }

    private func awaitStartup(_ work: Task<LXSourceDeclaration, Error>, sourceID: String) async throws -> LXSourceDeclaration {
        let waiter = UUID()
        startupWaiters[sourceID, default: []].insert(waiter)
        defer { startupWaiters[sourceID]?.remove(waiter) }
        return try await withTaskCancellationHandler {
            let declaration = try await work.value
            try Task.checkCancellation()
            return declaration
        } onCancel: {
            Task { await self.cancelStartupWaiter(waiter, sourceID: sourceID, work: work) }
        }
    }

    private func cancelStartupWaiter(_ waiter: UUID, sourceID: String, work: Task<LXSourceDeclaration, Error>) {
        guard startupWaiters[sourceID]?.remove(waiter) != nil else { return }
        if startupWaiters[sourceID]?.isEmpty == true { work.cancel() }
    }

    private func evaluate(_ source: LXSource, library: LXSourceLibrary, key: String, action: String,
                          quality: String? = nil, musicInfo: [String: JSONValue], seconds: Double) async throws -> JSONValue {
        active[source.id, default: 0] += 1
        defer { active[source.id, default: 1] -= 1; trimIdleSessions() }
        let deadline = Date().addingTimeInterval(seconds)
        let declared = try await declaration(source, library: library, seconds: min(4, seconds))
        guard declared.actions[key]?.contains(action) == true, let session = sessions[source.id] else { throw MusicProviderError.noResource }
        try Task.checkCancellation()
        if sessions[source.id] != nil {
            recent.removeAll { $0 == source.id }; recent.append(source.id)
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.3 else { throw MusicProviderError.timeout }
        let input: JSONValue = .object(["source": .string(key), "quality": quality.map(JSONValue.string) ?? .null,
                                        "timeout": .number(max(100, (remaining - 0.3) * 1000)), "musicInfo": .object(musicInfo)])
        let json = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let envelope = await session.evaluate("__lx.\(action)(\(json))", within: remaining, cancellable: true)
        if Task.isCancelled {
            throw CancellationError()
        }
        if let value = envelope["value"], value["error"] == nil { return value }
        let reason = envelope["error"]?.string ?? envelope["value"]?["error"]?.string ?? ""
        if reason.contains("interrupted") || reason.contains("timeout") {
            throw MusicProviderError.timeout
        }
        throw MusicProviderError.noResource
    }

    func musicStream(_ source: LXSource, library: LXSourceLibrary, key: String, quality: String,
                     musicInfo: [String: JSONValue], seconds: Double = lookupSeconds) async throws -> ResolvedMusicStream {
        let answer = try await evaluate(source, library: library, key: key, action: "musicUrl", quality: quality, musicInfo: musicInfo, seconds: seconds)
        guard let address = answer["url"]?.string, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw MusicProviderError.noResource }
        return ResolvedMusicStream(url: url, headers: (answer["headers"]?.object ?? [:]).compactMapValues(\.string), claimedQuality: quality,
                                   upstream: "lx:" + source.info.name, sourceID: source.id)
    }

    func musicURL(_ source: LXSource, library: LXSourceLibrary, key: String, quality: String, musicInfo: [String: JSONValue]) async throws -> URL {
        try await musicStream(source, library: library, key: key, quality: quality, musicInfo: musicInfo).url
    }

    func lyric(_ source: LXSource, library: LXSourceLibrary, key: String, musicInfo: [String: JSONValue]) async throws -> JSONValue {
        let answer = try await evaluate(source, library: library, key: key, action: "lyric", musicInfo: musicInfo, seconds: Self.lookupSeconds)
        guard let lyric = answer["lyric"] else { throw MusicProviderError.noResource }
        return lyric
    }

    func close(_ id: String) {
        starting.removeValue(forKey: id)?.cancel()
        startupWaiters[id] = nil
        sessions.removeValue(forKey: id)?.close()
        declarations[id] = nil
        generations[id] = nil
        recent.removeAll { $0 == id }
    }

    private func keep(_ session: ScriptSession, for id: String) {
        sessions[id] = session
        recent.removeAll { $0 == id }; recent.append(id)
        trimIdleSessions()
    }

    private func trimIdleSessions() {
        while recent.count > Self.maximumSessions, let idle = recent.first(where: { active[$0, default: 0] == 0 }) {
            close(idle)
        }
    }
}

/// Restores the provider metadata older queues did not save, using the exact recording ID.
/// Successful answers are kept briefly so successive quality/lyric requests share them.
actor LXMusicMetadata {
    static let shared = LXMusicMetadata()
    private var cache: [String: (Date, [String: JSONValue])] = [:]

    func info(songID: String, platform: MusicPlatform, track: MusicTrack?, transport: MusicTransport) async throws -> [String: JSONValue] {
        let supplied = track?.lxInfo(for: platform)
        let needed: Bool
        switch platform {
        case .qq: needed = supplied?["strMediaMid"] == nil
        case .migu: needed = supplied?["songId"] == nil || supplied?["songmid"] == supplied?["copyrightId"]
        default: needed = false
        }
        let base = LXSourceKey.musicInfo(songID: songID, platform: platform, track: track)
        guard needed else { return base }
        let cacheKey = platform.rawValue + "|" + songID
        if let cached = cache[cacheKey], Date().timeIntervalSince(cached.0) < 3600 { return base.merging(cached.1) { _, new in new } }
        let fresh: MusicTrack?
        switch platform {
        case .qq:
            let answer = try await QQMusicCatalog(transport: transport).call(module: "music.pf_song_detail_svr", method: "get_song_detail", param: ["song_mid": songID, "song_type": 0])
            if let row = answer[path: "req", "data", "track_info"], row["mid"]?.string == songID { fresh = QQMusicCatalog.track(row) }
            else { fresh = nil }
        case .migu:
            let copyright = supplied?["copyrightId"]?.string ?? MiguMusicCatalog.ids(songID)?.copyright ?? songID
            let url = MusicHTTP.url("https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do", [("copyrightId", copyright), ("resourceType", "2")])
            let answer = try await MusicHTTP.json(transport, MusicHTTP.request(url, timeout: 4, headers: ["Referer": "https://music.migu.cn/"]), timeout: 4)
            if let row = answer["resource"]?.array?.first(where: { $0["copyrightId"]?.string == copyright }) { fresh = MiguMusicCatalog.track(row) }
            else { fresh = nil }
        default: fresh = nil
        }
        guard let fresh, fresh.lxInfo(for: platform) != nil else { throw MusicProviderError.noResource }
        let fields = LXSourceKey.musicInfo(songID: songID, platform: platform, track: fresh)
        if cache.count > 128 { cache = cache.filter { Date().timeIntervalSince($0.value.0) < 1800 }; if cache.count > 128 { cache.removeAll(keepingCapacity: true) } }
        cache[cacheKey] = (Date(), fields)
        return base.merging(fields) { _, new in new }
    }
}

/// The enabled LX sources as one channel: each source that covers the catalog is asked in turn.
public struct LXMusicProvider: MusicStreamProvider {
    public let id = MusicProviderID.lx
    public let platforms: Set<MusicPlatform>
    let sources: [LXSource]
    let library: LXSourceLibrary
    let runtime: LXSourceRuntime
    let health: MusicHealth
    let transport: MusicTransport
    let streamProber: MusicProber?

    public init?(sources: [LXSource], library: LXSourceLibrary = .shared, runtime: LXSourceRuntime = .shared, health: MusicHealth = .shared,
                 transport: MusicTransport = URLSessionMusicTransport(), streamProber: MusicProber? = nil) {
        guard !sources.isEmpty else { return nil }
        self.sources = sources; self.library = library; self.runtime = runtime; self.health = health
        self.transport = transport; self.streamProber = streamProber
        // Old imports discarded kg at import time. Their local script is re-read before a
        // lookup, so do not suppress Kugou candidates solely from that stale declaration.
        platforms = sources.contains(where: { $0.actions == nil })
            ? Set(MusicPlatform.allCases.filter { $0 != .ext }) : Set(sources.flatMap(\.platforms))
    }

    public func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        try await resolve(songID, platform: platform, track: nil, quality: quality)
    }

    public func resolve(_ songID: String, platform: MusicPlatform, track: MusicTrack?, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        let deadline = Date().addingTimeInterval(12)
        let key = LXSourceKey.key(platform)
        let metadata = try? await MusicHTTP.withTimeout(2) { try await LXMusicMetadata.shared.info(songID: songID, platform: platform, track: track, transport: transport) }
        try Task.checkCancellation()
        let info = metadata ?? LXSourceKey.musicInfo(songID: songID, platform: platform, track: track)
        var ranked: [(source: LXSource, cooling: Bool, success: Date?, index: Int)] = []
        for (index, source) in sources.enumerated() {
            // Known capabilities need no runtime boot. Old imports are checked lazily.
            if source.actions != nil, source.sources[key] == nil { continue }
            let healthKey = MusicHealth.key("lx:" + source.id, platform, .resolve)
            ranked.append((source, await health.failing(healthKey), await health.lastSuccess(healthKey), index))
        }
        ranked.sort {
            if $0.cooling != $1.cooling { return !$0.cooling }
            if $0.success != $1.success { return ($0.success ?? .distantPast) > ($1.success ?? .distantPast) }
            return $0.index < $1.index
        }
        let ordered = ranked.map(\.source)
        return try await withThrowingTaskGroup(of: Result<ResolvedMusicStream, MusicProviderError>.self) { group in
            var cursor = 0
            func launch() {
                guard cursor < ordered.count, deadline.timeIntervalSinceNow > 0.3, !Task.isCancelled else { return }
                let source = ordered[cursor]; cursor += 1
                group.addTask {
                    do {
                        return .success(try await lookup(source, key: key, platform: platform, track: track,
                                                        quality: quality, info: info, deadline: min(deadline, Date().addingTimeInterval(4))))
                    } catch { return .failure(MusicProviderError(error)) }
                }
            }
            // Sliding window: an immediate failure frees a slot immediately. No wave barrier.
            for _ in 0..<min(3, ordered.count) { launch() }
            var failures: [MusicProviderError] = []
            while let answer = try await group.next() {
                try Task.checkCancellation()
                switch answer {
                case .success(let stream): group.cancelAll(); return stream
                case .failure(let error): failures.append(error); launch()
                }
            }
            try Task.checkCancellation()
            throw MusicResolver.summary(failures, budgetSpent: cursor < ordered.count)
        }
    }

    private func lookup(_ source: LXSource, key: String, platform: MusicPlatform, track: MusicTrack?,
                        quality: MusicAudioQuality, info: [String: JSONValue], deadline: Date) async throws -> ResolvedMusicStream {
        let began = Date()
        let healthKey = MusicHealth.key("lx:" + source.id, platform, .resolve)
        do {
            var capabilities = source.sources
            if source.actions == nil {
                capabilities = try await runtime.declaration(source, library: library, seconds: max(0.1, deadline.timeIntervalSinceNow)).sources
            }
            guard let declared = capabilities[key] else { throw MusicProviderError.noResource }
            let tiers = LXSourceKey.qualities(from: declared, for: quality)
            var failure = MusicProviderError.noResource
            for tier in tiers {
                try Task.checkCancellation()
                let left = deadline.timeIntervalSinceNow
                guard left > 0.3 else { throw MusicProviderError.timeout }
                do {
                    try await health.admit("lx:" + source.id)
                    var stream = try await runtime.musicStream(source, library: library, key: key, quality: tier, musicInfo: info,
                                                               seconds: max(0.1, left - (streamProber == nil ? 0 : 0.3)))
                    if let streamProber {
                        let resolved = stream
                        let probe = try await MusicHTTP.withTimeout(max(0.1, deadline.timeIntervalSinceNow)) {
                            try await streamProber.probe(resolved, expected: track?.duration)
                        }
                        if probe.completeness == .preview { throw MusicProviderError.preview(probe.duration ?? 0) }
                        if let expected = track?.duration, let duration = probe.duration,
                           duration > expected + MusicMatching.durationTolerance(expected) { throw MusicProviderError.differentRecording(duration) }
                        stream.verifiedProbe = probe
                    }
                    try Task.checkCancellation()
                    await health.record(healthKey, error: nil)
                    Diagnostics.shared.record(.info, "music", "lx source=\(source.id) platform=\(platform.rawValue) playable in \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
                    return stream
                } catch {
                    try Task.checkCancellation()
                    failure = MusicProviderError(error)
                    if failure != .noResource { break }
                }
            }
            throw failure
        } catch {
            try Task.checkCancellation()
            let failure = MusicProviderError(error)
            await health.record(healthKey, error: failure)
            Diagnostics.shared.record(.info, "music", "lx source=\(source.id) platform=\(platform.rawValue) failed=\(failure.detail) in \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
            throw failure
        }
    }
}
