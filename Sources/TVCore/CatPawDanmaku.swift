import Foundation

/// Danmaku from a CatPawOpen bundle's own comment service (#506). The 9280.kstore.vip bundle carries a danmu_api: a
/// moment after a play it asks the app what plays and sends back the address of the comments it matched, as the
/// CatVod Open apps take them. The hosts (Runtime/ScriptHost/host.mjs, Runtime/NodeHost/main.mjs) answer the bundle
/// and keep that address; `comments(for:)` asks the host for it (`catDanmaku`) and reads the bundle's Bilibili XML.
/// A bundle without one answers that address with 404 and the app's own matching goes on as before. Mac, iPhone and
/// iPad run bundles; tvOS has none.
public enum CatPawDanmaku {
    private struct ClientKey: Hashable {
        let origin: URL
        let source: String
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var clients: [ClientKey: CatalogClient] = [:]
    nonisolated(unsafe) private static var configured = false
    nonisolated(unsafe) private static var pythonSources: Set<ClientKey> = []
    nonisolated(unsafe) private static var subscriptionClient: CatalogClient?
    nonisolated(unsafe) private static var registryRevision = UUID()
    nonisolated(unsafe) private static var generation: UInt64 = 0
    nonisolated(unsafe) private static var playback: (key: String, session: String, owner: String)?
    nonisolated(unsafe) private static var prepared: [String: String] = [:]
    nonisolated(unsafe) private static var preparedOrder: [String] = []

    /// Independent Python sources borrow only the currently enabled subscription.
    /// Rebuilding the registry invalidates selections even after A → B → A.
    public static func configure(subscriptions: [Subscription], activeSubscription: Subscription?) {
        lock.withLock {
            var registered: [ClientKey: CatalogClient] = [:]
            var python = Set<ClientKey>()
            for document in subscriptions {
                for site in document.sites {
                    let client = CatalogClient(site: site, origin: document.origin, jarURL: document.spiderURL)
                    let key = ClientKey(origin: client.origin, source: site.sourceKey)
                    if site.runtime == .python { python.insert(key) }
                    if site.raw["catPawOpen"] != nil {
                        let previous = clients[key]
                        registered[key] = previous?.site.api == site.api && previous?.site.raw == site.raw ? previous : client
                    }
                }
            }
            clients = registered; pythonSources = python; configured = true
            subscriptionClient = activeSubscription.flatMap { document in
                document.sites.first(where: { $0.raw["catPawOpen"] != nil }).map {
                    CatalogClient(site: $0, origin: document.origin, jarURL: document.spiderURL)
                }
            }
            registryRevision = UUID(); generation += 1
            prepared.removeAll(); preparedOrder.removeAll()
            if let current = playback { playback = (current.key, current.session, UUID().uuidString) }
        }
        NotificationCenter.default.post(name: LocalDanmakuPreferences.changed, object: nil)
    }

    private static func playbackKey(_ context: PlaybackHistoryContext) -> String {
        [context.origin.absoluteString, context.sourceKey, context.videoID, context.episodeID, context.episodeFlag]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
    private static func preparedKey(origin: URL, source: String, episode: String, flag: String) -> String {
        [origin.absoluteString, source, episode, flag].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
    /// Prefetch/retry creates an isolated reservation; only the selected resolved
    /// choice's requestJSON can adopt it. Preparing never changes the active owner.
    static func reserve(_ client: CatalogClient, episode: Episode) -> String? {
        guard client.site.raw["catPawOpen"] != nil else { return nil }
        return lock.withLock {
            guard !configured || clients[ClientKey(origin: client.origin, source: client.site.sourceKey)] != nil else { return nil }
            let owner = UUID().uuidString
            prepared[owner] = preparedKey(origin: client.origin, source: client.site.sourceKey, episode: episode.id, flag: episode.flag)
            preparedOrder.append(owner)
            while preparedOrder.count > 64 { prepared[preparedOrder.removeFirst()] = nil }
            return owner
        }
    }
    static func discardPrepared(_ owner: String) {
        lock.withLock { prepared[owner] = nil; preparedOrder.removeAll { $0 == owner } }
    }
    public static func beginPlayback(_ context: PlaybackHistoryContext?, sessionID: String, requestJSON: String? = nil) {
        let candidate = requestJSON.flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8)) }?["catDanmakuOwner"]?.string
        lock.withLock {
            generation += 1; registryRevision = UUID()
            playback = context.map { context in
                let key = preparedKey(origin: context.origin, source: context.sourceKey, episode: context.episodeID, flag: context.episodeFlag)
                let adopted = candidate.flatMap { prepared[$0] == key ? $0 : nil }
                if let adopted { prepared[adopted] = nil; preparedOrder.removeAll { $0 == adopted } }
                return (playbackKey(context), sessionID, adopted ?? UUID().uuidString)
            }
        }
    }
    public static func endPlayback(sessionID: String) {
        lock.withLock {
            guard playback?.session == sessionID else { return }
            generation += 1; registryRevision = UUID(); playback = nil
        }
    }
    static var revision: UUID { lock.withLock { registryRevision } }
    struct Binding: Sendable {
        let client: CatalogClient
        let revision: UUID
        let generation: UInt64
        let owner: String?
        let context: PlaybackHistoryContext
        var isCurrent: Bool { CatPawDanmaku.lock.withLock {
            guard revision == registryRevision else { return false }
            if let owner { return playback?.owner == owner && CatPawDanmaku.generation == generation }
            return CatPawDanmaku.generation == generation
        } }
        func request(_ params: [String: String]) async throws -> [String: JSONValue] {
            guard isCurrent, !Task.isCancelled else { throw CancellationError() }
            var params = params
            if let owner {
                params["catDanmakuOwner"] = owner; params["catDanmakuGeneration"] = String(generation)
                params["danmakuTitle"] = context.videoName; params["danmakuEpisode"] = context.episodeName
                params["danmakuFlag"] = context.episodeFlag
            }
            let response = try await client.catPawRequest(params)
            guard isCurrent, !Task.isCancelled else { throw CancellationError() }
            return response
        }
    }
    static func binding(for context: PlaybackHistoryContext) -> Binding? {
        lock.withLock {
            let key = ClientKey(origin: context.origin, source: context.sourceKey)
            guard let client = pythonSources.contains(key) ? subscriptionClient : clients[key] else { return nil }
            if let playback, playback.key != playbackKey(context) { return nil }
            return Binding(client: client, revision: registryRevision, generation: generation,
                           owner: playback?.owner, context: context)
        }
    }

    /// Keeps the client of each CatPawOpen source that plays, for its episodes' comments.
    static func remember(_ client: CatalogClient) {
        guard client.site.raw["catPawOpen"] != nil else { return }
        lock.withLock {
            let key = ClientKey(origin: client.origin, source: client.site.sourceKey)
            guard !configured || clients[key] != nil else { return }
            clients[key] = client
        }
    }

    static func client(for context: PlaybackHistoryContext) -> CatalogClient? {
        binding(for: context)?.client
    }

    /// The bundle's comments for the episode, or nil when its source isn't a CatPawOpen one that played, or the
    /// bundle has none for it. Never throws: the other providers are asked next.
    public static func comments(for context: PlaybackHistoryContext) async -> AutomaticDanmakuResult? {
        guard LocalDanmakuPreferences.enabled(), LocalDanmakuPreferences.builtinEnabled() else { return nil }
        guard let binding = binding(for: context) else { return nil }
        let client = binding.client
        let savedTitle = client.pushInput.flatMap { _ in
            PushMediaLibrary.shared.record(origin: context.origin, sourceKey: context.sourceKey, videoID: context.videoID)?.title
        }
        let matchingShare = savedTitle?.isEmpty == false
        let result = await comments(for: context, source: client.site.name, http: .init(), matchingShare: matchingShare,
                                    owner: binding.owner) { params in
            try await binding.request(params)
        }
        return binding.isCurrent && !Task.isCancelled ? result : nil
    }

    static func comments(for context: PlaybackHistoryContext, source: String, http: DanmakuHTTP, matchingShare: Bool = false, owner: String? = nil,
                         ask: @Sendable ([String: String]) async throws -> [String: JSONValue]) async -> AutomaticDanmakuResult? {
        let params = ["catDanmaku": "1", "name": matchingShare ? MediaDanmakuIdentity.title(context.videoName) : context.videoName,
                      "episode": matchingShare ? MediaDanmakuIdentity.episode(context.episodeName) : context.episodeName]
        var answer: [String: JSONValue] = [:]
        // The bundle sends its address about a second after the play; the host says when one may still come.
        for attempt in 0..<8 {
            guard let reply = try? await ask(params), !Task.isCancelled else { return nil }
            answer = reply
            guard case .bool(true)? = reply["pending"], attempt < 7 else { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard let address = answer["url"]?.string, let url = URL(string: address), isLoopback(url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        // The host's own calls aren't the player reading the bundle's media proxy.
        request.setValue("1", forHTTPHeaderField: "x-yingxia-host")
        if let owner { request.setValue(owner, forHTTPHeaderField: "x-wincat-play-session") }
        let started = ContinuousClock.now
        do {
            let comments = try CatalogDanmakuParser.parse(try await http.send(request))
            Diagnostics.shared.record(.info, "danmaku.catpaw", "\(context.sourceKey) comments=\(comments.count) pushed=\(answer["pushed"] == .bool(true)) seconds=\(started.duration(to: .now).seconds)")
            guard !comments.isEmpty else { return nil }
            return AutomaticDanmakuResult(comments: comments, track: [context.videoName, context.episodeName].filter { !$0.isEmpty }.joined(separator: " · "),
                                          source: source, state: "loaded")
        } catch {
            Diagnostics.shared.record(.info, "danmaku.catpaw", "\(context.sourceKey) none: \(error)")
            return nil
        }
    }

    static func isLoopback(_ url: URL) -> Bool {
        url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host() ?? "")
    }
}

extension CatalogClient {
    /// A call to the source's CatPawOpen bundle beside its spider routes: sign-ins, its comments' address.
    func catPawRequest(_ params: [String: String]) async throws -> [String: JSONValue] {
        #if os(macOS)
        return try await LocalJarHost.shared.request(site: site, jarURL: site.scriptURL(origin: origin), params: params, http: http, scriptOrigin: origin)
        #elseif os(iOS) || os(tvOS)
        return try await EmbeddedNodeHost.shared.request(site: site, bundleURL: site.scriptURL(origin: origin), params: params, http: http, origin: origin)
        #else
        throw TVError.unsupported(L10n.text("This device can't run CatPawOpen sources."))
        #endif
    }
}
