import SwiftUI
import Perception
import TVCore

@MainActor @Perceptible final class Store {
    static let defaultURL = "https://raw.githubusercontent.com/qist/tvbox/master/fty.json"
    let searchModel = SearchModel()
    /// Song search and the music player; both outlive the Music page, so a song keeps playing elsewhere in the app.
    /// The Mac and Apple TV list every kind at once, in rows; a phone or iPad starts on songs.
    /// Music extensions the listener imported search alongside the catalogs; with none, they answer nothing at once.
    #if os(macOS) || os(tvOS)
    let musicSearch = MusicSearchModel(catalogs: MusicSearchModel.defaultCatalogs() + [MusicExtensionCatalog()], kind: .top)
    #else
    let musicSearch = MusicSearchModel(catalogs: MusicSearchModel.defaultCatalogs() + [MusicExtensionCatalog()])
    #endif
    let music = MusicPlaybackSession()
    /// The Music page's charts, playlists and new albums; fetched when that page first shows.
    /// The music extensions' library groups come after the catalogs' shelves.
    let musicBrowse = MusicBrowseModel(sources: MusicBrowseModel.defaultSources() + [MusicExtensionCatalog()])
    let recommendationModel = RecommendationModel()
    let playbackHistory: PlaybackHistory
    let playbackDefaults: UserDefaults
    let pinnedSources: PinnedSources
    let hiddenSources: HiddenSources
    let sourceOrder: SourceOrder
    /// Keeps the viewer's library the same on their other devices when using the standard preferences.
    let cloudSync: CloudSync?
    /// The history entry being resumed; another entry, or leaving the page, replaces or cancels it.
    private(set) var resumingHistoryID: String?
    private var resumeTask: Task<Void, Never>?
    /// The selected subscription and all enabled Python sources, merged in list order.
    var subscription: Subscription?
    /// The address being typed in to add a subscription.
    var subscriptionAddress: String
    /// What to call the subscription being added; empty shows where it lives instead.
    var subscriptionName = ""
    /// Every subscription the viewer added, in the order they merge.
    var subscriptions: [SubscriptionEntry] = []
    /// Library ownership follows the enabled subscription, including every enabled Python source
    /// and local playback. Source selection cannot move progress into another library.
    var historySubscriptions: [SubscriptionEntry] {
        subscriptions.filter { $0.enabled && localSourceGroups[$0.address] != .python }
    }
    var historyScope: String? { historySubscriptions.first?.address }
    var visibleHistory: [PlaybackHistoryEntry] {
        let entries = playbackHistory.entries(in: historyScope)
        guard !entries.isEmpty else { return [] }
        let sources = enabledHistorySourceIdentities
        var origins: [URL: URL] = [:]
        return entries.filter { entry in
            let context = entry.context
            if LocalMediaLibrary.isLocalSource(context.sourceKey) || context.sourceKey == CloudFiles.sourceKey { return true }
            let identity: URL
            if let known = origins[context.origin] { identity = known }
            else {
                identity = PlaybackHistoryContext.sourceIdentity(context.origin)
                origins[context.origin] = identity
            }
            return historySourceEnabled(context, identity: identity, sources: sources)
        }
    }
    /// Snapshot once per history read; progress changes do not alter provider membership.
    /// Rebuilding from current catalogs keeps disable/remove/refresh checks immediate.
    private var enabledHistorySourceIdentities: Set<URL> {
        Set(subscriptions.compactMap { entry in
            guard entry.enabled, let origin = documents[entry.address]?.origin ?? URL(string: entry.address) else { return nil }
            return PlaybackHistoryContext.sourceIdentity(origin)
        })
    }
    /// Disabled or removed providers keep their saved rows, but do not appear in Watching or
    /// finish an in-flight resume. A refresh may remove a title; its provider still owns the row.
    private func historySourceEnabled(_ context: PlaybackHistoryContext) -> Bool {
        if LocalMediaLibrary.isLocalSource(context.sourceKey) || context.sourceKey == CloudFiles.sourceKey { return true }
        return historySourceEnabled(context, identity: PlaybackHistoryContext.sourceIdentity(context.origin),
                                    sources: enabledHistorySourceIdentities)
    }
    private func historySourceEnabled(_ context: PlaybackHistoryContext, identity: URL, sources: Set<URL>) -> Bool {
        if sources.contains(identity) { return true }
        guard let config = subscription else { return false }
        return config.sites.contains { $0.isBuiltIn && $0.sourceKey == context.sourceKey && $0.origin(or: config.origin) == context.origin }
    }
    private func scopedHistoryChannel(_ channel: Channel) -> Channel {
        guard var context = channel.historyContext else { return channel }
        context.historyScope = historyScope ?? ""
        return Channel(name: channel.name, group: channel.group, url: channel.url, logo: channel.logo,
                       headers: channel.headers, skipScope: channel.skipScope, historyContext: context,
                       resumePosition: channel.resumePosition, subtitles: channel.subtitles, playback: channel.playback)
    }
    /// Independent subscription/Python management, including migration of existing lone scripts.
    var localSourceGroups: [String: LocalSourceGroup] = [:]
    var subscriptionAutoUpdateEnabled: Bool {
        didSet {
            guard subscriptionAutoUpdateEnabled != oldValue else { return }
            defaults.set(subscriptionAutoUpdateEnabled, forKey: SubscriptionUpdateFrequency.enabledKey)
            subscriptionUpdateSchedule.settingsChanged()
            if subscriptionAutoUpdateEnabled { requestAutomaticSubscriptionUpdate() }
        }
    }
    var subscriptionUpdateFrequency: SubscriptionUpdateFrequency {
        didSet {
            guard subscriptionUpdateFrequency != oldValue else { return }
            defaults.set(subscriptionUpdateFrequency.rawValue, forKey: SubscriptionUpdateFrequency.frequencyKey)
            subscriptionUpdateSchedule.settingsChanged()
            requestAutomaticSubscriptionUpdate()
        }
    }
    /// Why a subscription last failed to refresh, by address; its last good copy stays in use.
    var subscriptionErrors: [String: String] = [:]
    /// The last good copy of each subscription, by address.
    private(set) var documents: [String: Subscription] = [:]
    let favorites: Favorites
    var importing = false {
        didSet { if oldValue && !importing && subscriptionUpdateTask == nil { requestAutomaticSubscriptionUpdate() } }
    }
    var restoringBackup = false {
        didSet { if oldValue && !restoringBackup { requestAutomaticSubscriptionUpdate() } }
    }
    var backupRecoveryRequired = false {
        didSet { if oldValue && !backupRecoveryRequired { requestAutomaticSubscriptionUpdate() } }
    }
    var error: String?
    /// Why the last subscription import failed. It shows under the address field, not in the app-wide alert: on
    /// iPhone and iPad that alert closed the Add Subscription sheet over it and took the viewer out of the form (#357).
    var importError: String?
    var notice: String?
    var localReading: LocalReadingSession?
    var playing: Channel? {
        // An episode of a listening source (audiobooks, radio, songs) plays in the music player instead (#289).
        didSet {
            if let channel = playing, let media = channel.playback?.reading {
                playing = nil
                music.stop()
                localReading?.close()
                localReading = LocalReadingSession(channel: channel, media: media, catalog: catalog(for: channel), store: self)
                return
            }
            if let channel = playing, let queue = listeningQueue(for: channel) { playing = nil; listen(queue, from: channel) }
        }
    }
    /// Set while a listening source's episode goes to the video player on purpose.
    @PerceptionIgnored private var playsAsVideo = false
    var playbackCatalog: PlaybackCatalog?
    /// The Cloud Files folder the playing file came from; its next file plays after it.
    var filesFolder: CloudFilesFolder?
    var resolvingEpisode: Episode?
    var episodeError: String?
    var autoPlayNext: Bool {
        didSet { if persistsChanges { defaults.set(autoPlayNext, forKey: "autoPlayNextEpisode") } }
    }
    private var episodeRequest = UUID()
    private var episodeTask: Task<Void, Never>?
    var section: AppSection = .home
    /// The Mac sidebar folds away while the manga reader fills the window, and comes back when it closes.
    /// macOS 26 floats the sidebar over the page, so it covered the left part of every comic page.
    var hidesSidebar = false
    /// Every build shows the built-in services (Music, Bilibili, Douyin), the default subscription and
    /// the plugin pages only once a subscription that works has been added: one that is on and whose
    /// copy has sources or live playlists.
    var extrasUnlocked: Bool {
        subscriptions.contains { $0.enabled && documents[$0.address].map { !$0.sites.isEmpty || !$0.lives.isEmpty } == true }
    }
    /// Private service adapters used for playback fallback. The iOS catalog does not include them.
    private(set) var cloudDocument: Subscription?
    @PerceptionIgnored private var cloudFetchedAt: Date?
    @PerceptionIgnored private var cloudFetch: Task<Void, Never>?
    /// Sections kept out of the tab bar and sidebar until then; Manga while no Venera comic source list
    /// is subscribed (one is added with Add Subscription, like any other).
    var hiddenSections: [AppSection] {
        var hidden: [AppSection] = extrasUnlocked ? [] : [.music]
        if MangaStore.shared.repositories.isEmpty { hidden.append(.manga) }
        return hidden
    }
    private let defaults: UserDefaults
    var backupDefaults: UserDefaults { defaults }
    private let http = HTTPClient()
    @PerceptionIgnored private var restoredLocalSources = Set<String>()
    @PerceptionIgnored private let subscriptionUpdateSchedule: SubscriptionUpdateSchedule
    @PerceptionIgnored private var subscriptionUpdateFingerprints: [String: SubscriptionUpdateFingerprint]
    @PerceptionIgnored private var subscriptionUpdateTask: Task<Void, Never>?
    @PerceptionIgnored private var subscriptionUpdateRequested = false
    @PerceptionIgnored private var subscriptionUpdatesReady = false
    @PerceptionIgnored private var subscriptionUpdatesForeground = false
    /// Rebuilt source rows are expensive (every source is classified and copied) and Watch Now reads
    /// them many times while drawing one frame. The stamp is the inputs, so a later frame reuses the row.
    /// Not observed: views fill these while drawing, and a write would draw every reader again.
    @PerceptionIgnored private var siteListStamp = ""
    @PerceptionIgnored private var cloudDrivesObserver: NSObjectProtocol?
    @PerceptionIgnored private var automaticCache: [Site]?
    @PerceptionIgnored private var orderedCache: [Site]?
    @PerceptionIgnored private var recommendationCache: [Site]?
    @PerceptionIgnored private var groupsCache: [Bool: [SourceGroup]] = [:]
    /// What the cached rows were built from: the merged subscription, which subscriptions are on, and the viewer's pins, hides, and order.
    private func currentSiteListStamp() -> String {
        let imported = subscription?.importedAt.timeIntervalSince1970 ?? 0
        let entries = subscriptions.map { "\($0.address)=\($0.enabled)" }.joined(separator: "\n")
        return "\(subscription?.origin.absoluteString ?? "")|\(imported)|\(subscription?.sites.count ?? 0)|\(entries)|\(pinnedSources.revision)|\(hiddenSources.revision)|\(sourceOrder.revision)"
    }
    private var persistsChanges: Bool {
        return true
    }
    init(defaults: UserDefaults = .standard) {
        #if os(macOS)
        if defaults === UserDefaults.standard { Self.adoptPreviousBundleDefaults(defaults) }
        #endif
        self.defaults = defaults
        subscriptionUpdateSchedule = SubscriptionUpdateSchedule(defaults: defaults)
        subscriptionAutoUpdateEnabled = defaults.bool(forKey: SubscriptionUpdateFrequency.enabledKey)
        subscriptionUpdateFrequency = defaults.string(forKey: SubscriptionUpdateFrequency.frequencyKey)
            .flatMap(SubscriptionUpdateFrequency.init(rawValue:)) ?? .automatic
        subscriptionUpdateFingerprints = defaults.data(forKey: "local.subscription.autoUpdate.fingerprints")
            .flatMap { try? JSONDecoder().decode([String: SubscriptionUpdateFingerprint].self, from: $0) } ?? [:]
        defaults.removeObject(forKey: "local.hiddenFeatures")
        defaults.removeObject(forKey: "local.library.historyScope")
        playbackDefaults = defaults
        playbackHistory = .shared
        pinnedSources = PinnedSources(defaults: playbackDefaults)
        hiddenSources = HiddenSources(defaults: playbackDefaults)
        #if os(macOS) || os(iOS)
        WebSniff.install(WKWebSniffer())
        #endif
        sourceOrder = SourceOrder(defaults: playbackDefaults)
        cloudSync = defaults === UserDefaults.standard ? CloudSync() : nil
        favorites = Favorites(defaults: defaults)
        favorites.isEnabled = true
        playbackHistory.isEnabled = true
        autoPlayNext = defaults.object(forKey: "autoPlayNextEpisode") == nil || defaults.bool(forKey: "autoPlayNextEpisode")
        let saved = defaults.data(forKey: "subscriptions").flatMap { try? JSONDecoder().decode([SubscriptionEntry].self, from: $0) }
        var entries = saved ?? [], copies: [String: Subscription] = [:]
        for entry in entries {
            if let data = try? Data(contentsOf: Self.file(for: entry)),
               let value = try? JSONDecoder().decode(Subscription.self, from: data) { copies[entry.address] = value }
        }
        // Builds before several subscriptions kept one, in subscription.json, and before that in defaults.
        let legacyAddress = saved == nil ? defaults.string(forKey: "subscriptionAddress") : nil
        let legacy = legacyAddress == nil ? nil : (try? Data(contentsOf: Self.legacyFile)) ?? defaults.data(forKey: "subscription")
        if let legacyAddress {
            entries = [SubscriptionEntry(address: legacyAddress)]
            copies[legacyAddress] = legacy.flatMap { try? JSONDecoder().decode(Subscription.self, from: $0) }
        }
        documents = copies
        var restoredGroups = defaults.data(forKey: "localSourceGroups").flatMap { try? JSONDecoder().decode([String: LocalSourceGroup].self, from: $0) } ?? [:]
        for entry in entries where restoredGroups[entry.address] == nil {
            let sites = copies[entry.address]?.sites ?? []
            restoredGroups[entry.address] = (!sites.isEmpty && sites.allSatisfy { $0.runtime == .python }) || URL(string: entry.address)?.pathExtension.lowercased() == "py" ? .python : .subscription
        }
        localSourceGroups = restoredGroups
        let loadedSubscriptions = LocalSourcePolicy.normalized(entries, groups: restoredGroups)
        subscriptions = loadedSubscriptions
        let cloud = (try? Data(contentsOf: Self.cloudFile)).flatMap { try? JSONDecoder().decode(Subscription.self, from: $0) }.flatMap { CloudSources.accepts($0) ? $0 : nil }
        cloudDocument = cloud
        CloudSources.current = cloud
        subscriptionAddress = ""
        if persistsChanges, let legacyAddress {
            if let legacy, copies[legacyAddress] != nil { try? Self.save(legacy, to: Self.file(for: entries[0])) }
            saveSubscriptionList()
            try? FileManager.default.removeItem(at: Self.legacyFile)
            defaults.removeObject(forKey: "subscription")
        }
        rebuildSubscription(resetting: false)
        searchModel.currentCatalog = { [weak self] in self?.subscription }
        // Signing in to a drive or adding a server adds its source; signing out or removing one takes it away.
        cloudDrivesObserver = NotificationCenter.default.addObserver(forName: CloudFiles.drivesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCloudFilesSources() }
        }
        searchModel.order = sourceOrder
        DownloadLibrary.shared.resolver = { [weak self] item in
            guard let self else { throw CancellationError() }
            return try await self.resolveDownload(item)
        }
        // Songs that were downloading when the app quit carry on.
        MusicDownloadLibrary.shared.wake()
        setUpListening()
        setUpCloudSync()
    }
    // MARK: Listening sources (#289)

    /// The music player's queue for an episode of a listening source: the episodes of its line, from it on. Nil for
    /// other sources, for one whose streams turned out to be videos, and when the episode's details aren't at hand.
    private func listeningQueue(for channel: Channel) -> MusicQueue? {
        guard !playsAsVideo, let context = channel.historyContext, let catalog = catalog(for: channel),
              AudioSources.isCandidate(catalog.client.site),
              !AudioSourceVerdicts(defaults: playbackDefaults).showsVideo(context),
              let episode = context.episode(in: catalog.video.episodes) else { return nil }
        return AudioSources.queue(video: catalog.video, from: episode, site: catalog.client.site, origin: catalog.client.origin)
    }

    /// Plays the queue from the channel's stream, where this chapter stopped last time.
    private func listen(_ queue: MusicQueue, from channel: Channel) {
        var position = channel.resumePosition
        if position == nil, let context = channel.historyContext,
           let saved = visibleHistory.first(where: { $0.context.id == context.id }),
           saved.context.episodeID == context.episodeID, saved.context.episodeFlag == context.episodeFlag, saved.resumePosition > 1 {
            position = saved.resumePosition
        }
        Diagnostics.shared.record(.info, "music", "listening source \(channel.historyContext?.sourceKey ?? "-") queue=\(queue.tracks.count)")
        music.play(queue, at: position, stream: channel)
    }

    /// The music player gets a source's streams from here, saves where a book is in the playback history, and hands
    /// an episode with a picture, or one it can't play, to the video player.
    private func setUpListening() {
        music.resolveSource = { [weak self] source in
            guard let self else { throw CancellationError() }
            return try await self.resolveListening(source)
        }
        music.recordSource = { [weak self] source, position, duration in
            guard let self else { return }
            var context = source.context; context.historyScope = self.historyScope ?? ""
            self.playbackHistory.record(context, position: position, duration: duration)
        }
        music.handOffSource = { [weak self] stream, position, picture, covered in
            guard let self, let context = stream.historyContext else { return }
            if picture { AudioSourceVerdicts(defaults: self.playbackDefaults).recordVideo(context) }
            let channel = Channel(name: stream.name, group: stream.group, url: stream.url, logo: stream.logo, headers: stream.headers,
                                  skipScope: stream.skipScope, historyContext: context, resumePosition: position > 1 ? position : nil,
                                  subtitles: stream.subtitles, playback: stream.playback)
            Task { @MainActor [weak self] in
                // The video player can't open while Now Playing is still closing (as PlayOn waits for the player).
                if covered { try? await Task.sleep(for: .milliseconds(700)) }
                guard let self, self.playing == nil else { return }
                self.playsAsVideo = true
                self.playing = channel
                self.playsAsVideo = false
            }
        }
    }

    /// A chapter's stream from its source, as Continue Watching gets an episode's.
    private func resolveListening(_ source: MusicSourceEpisode) async throws -> Channel {
        var context = source.context
        context.historyScope = historyScope ?? ""
        guard let client = historyClient(PlaybackHistoryEntry(context: context, position: 0, duration: 0, updatedAt: Date())) else {
            throw TVError.unsupported(L10n.text("This history source is no longer in the current subscription. Restore that subscription to continue."))
        }
        let resolved = try await client.playback(source.episode)
        return Channel(name: "\(context.videoName) · \(context.episodeName)", group: resolved.group, url: resolved.url, logo: resolved.logo,
                       headers: resolved.headers, skipScope: context.id, historyContext: context, subtitles: resolved.subtitles, playback: resolved.playback)
    }

    /// The current media address of a downloading episode, from its source; the queue asks again when a link expires.
    private func resolveDownload(_ item: DownloadItem) async throws -> Channel {
        let config = subscription
        guard let site = config?.sites.first(where: { $0.key == item.source.siteKey })
                ?? cloudDocument?.sites.first(where: { $0.key == item.source.siteKey }) else {
            throw TVError.unsupported(L10n.text("%@ is no longer in your subscription, so this download can't continue.", item.source.siteName))
        }
        let base = CatalogClient(site: site, origin: config?.origin ?? URL(string: "https://example.invalid/")!, jarURL: config?.spiderURL)
        let client = config.map { base.applying($0) } ?? base
        let plan = try await client.preparePlayback(item.source.episode, forDownload: true)
        let channel = try await client.resolvePlayback(plan, choice: plan.choices[0])
        // A cloud-drive file downloads straight from its CDN, as it plays: through the plugin's
        // proxy every part costs the embedded runtime download threads and interpreted TLS.
        // A file of a drive in Cloud Files downloads from the address its stream reads.
        if channel.url.scheme == CloudStreams.scheme, let media = await CloudStreams.source(for: channel.url) {
            CloudStreams.stop(channel.url)
            return Channel(name: channel.name, group: channel.group, url: media.url, headers: media.headers)
        }
        // A drive's HLS copy downloads with the headers its CDN wants.
        if let headers = CloudStreams.playlistHeaders(for: channel.url) {
            CloudStreams.stop(channel.url)
            return Channel(name: channel.name, group: channel.group, url: channel.url, headers: channel.headers.merging(headers) { $1 })
        }
        let address = try await EmbeddedJarHost.shared.recoverProxy(channel.url)
        if let media = await EmbeddedJarHost.shared.directMedia(address) {
            Diagnostics.shared.record(.info, "download", "cloud direct host=\(media.url.host() ?? "-") length=\(media.length)")
            return Channel(name: channel.name, group: channel.group, url: media.url, headers: media.headers)
        }
        return address == channel.url ? channel : Channel(name: channel.name, group: channel.group, url: address, headers: channel.headers)
    }
    /// Large subscriptions run to megabytes, past the defaults size limit that aborts tvOS apps,
    /// so each parsed subscription lives in a file. tvOS only offers Caches, which the system may purge;
    /// `restoreSubscription()` refetches what is gone from the saved addresses.
    private static var subscriptionDirectory: URL {
        #if os(tvOS)
        return URL.cachesDirectory
        #else
        return URL.applicationSupportDirectory
        #endif
    }
    private static var legacyFile: URL { subscriptionDirectory.appending(path: "subscription.json") }
    private static var cloudFile: URL { subscriptionDirectory.appending(path: "cloud-sources.json") }
    private static func file(for entry: SubscriptionEntry) -> URL {
        subscriptionDirectory.appending(path: "subscriptions").appending(path: entry.cacheName)
    }
    private static func save(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    /// Lets sources on a shared spider borrow classes from the subscription's other plugin archives.
    private static func registerPlugins(_ subscription: Subscription) {
        let archives = subscription.pluginArchives
        Task { await PluginLocator.shared.use(archives) }
    }
    /// Rebuilds owned source adapters once per launch and fetches missing remote subscriptions.
    func restoreSubscription() async {
        let active = subscriptions.filter(\.enabled)
        let owned = active.filter { URL(string: $0.address)?.host()?.lowercased() == "sources.yingxia.invalid" && !restoredLocalSources.contains($0.address) }
        let missing = active.filter { documents[$0.address] == nil && URL(string: $0.address)?.host()?.lowercased() != "sources.yingxia.invalid" }
        guard !importing, !owned.isEmpty || !missing.isEmpty else { return }
        importing = true
        defer { importing = false }
        for entry in owned {
            restoredLocalSources.insert(entry.address)
            do {
                let value = try await LocalSourceLibrary.shared.storedSubscription(address: entry.address, http: http)
                if subscriptions.contains(where: { $0.address == entry.address && $0.enabled }) { keep(value, for: entry) }
            } catch { subscriptionErrors[entry.address] = error.localizedDescription }
        }
        if !owned.isEmpty { rebuildSubscription() }
        if !missing.isEmpty { await fetch(missing) }
    }
    func managedSubscriptions(in group: LocalSourceGroup) -> [SubscriptionEntry] {
        subscriptions.filter { (localSourceGroups[$0.address] ?? .subscription) == group }
    }
    /// The app marks readiness only after backup recovery and local adapter restoration.
    /// Scene callbacks before that point remember foreground state without starting I/O.
    func startSubscriptionUpdates() {
        subscriptionUpdatesReady = true
        requestAutomaticSubscriptionUpdate()
    }
    func subscriptionUpdateForegroundChanged(_ foreground: Bool) {
        subscriptionUpdatesForeground = foreground
        if foreground { subscriptionUpdateSchedule.enterForeground(); requestAutomaticSubscriptionUpdate() }
        else { subscriptionUpdateSchedule.leaveForeground() }
    }
    private func requestAutomaticSubscriptionUpdate() {
        guard subscriptionUpdatesReady, subscriptionUpdatesForeground, subscriptionAutoUpdateEnabled else { return }
        subscriptionUpdateRequested = true
        guard !importing, !restoringBackup, !backupRecoveryRequired, subscriptionUpdateTask == nil else { return }
        subscriptionUpdateTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.subscriptionUpdateRequested = false
                await self.checkAutomaticSubscriptionUpdates()
            } while self.subscriptionUpdateRequested && self.subscriptionUpdatesForeground && self.subscriptionAutoUpdateEnabled
                && !self.importing && !self.restoringBackup && !self.backupRecoveryRequired
            self.subscriptionUpdateTask = nil
        }
    }
    private func checkAutomaticSubscriptionUpdates() async {
        guard subscriptionUpdatesReady, subscriptionUpdatesForeground, subscriptionAutoUpdateEnabled,
              !importing, !restoringBackup, !backupRecoveryRequired else { return }
        importing = true
        defer { importing = false }
        let owned: [LocalSourceRecord]
        do { owned = try await LocalSourceLibrary.shared.records() }
        catch {
            Diagnostics.shared.failure("subscription", "automatic update source index", error)
            return
        }
        let eligible = managedSubscriptions(in: .subscription).filter { entry in
            guard entry.enabled, let url = URL(string: entry.address),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !ImportedFiles.isImported(entry.address) else { return false }
            if url.host()?.lowercased() == "sources.yingxia.invalid" {
                guard let record = owned.first(where: { $0.address.absoluteString == entry.address }) else { return false }
                return record.group == .subscription && !record.input.isEmpty
                    && record.input.allSatisfy { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
            }
            return true
        }
        var changed = false
        for entry in eligible {
            guard subscriptionUpdatesForeground, subscriptionAutoUpdateEnabled, !restoringBackup, !backupRecoveryRequired,
                  subscriptions.contains(where: { $0.address == entry.address && $0.enabled }),
                  let check = subscriptionUpdateSchedule.begin(address: entry.address, frequency: subscriptionUpdateFrequency) else { continue }
            var succeeded = false
            defer { subscriptionUpdateSchedule.complete(check, succeeded: succeeded) }
            do {
                if URL(string: entry.address)?.host()?.lowercased() == "sources.yingxia.invalid" {
                    let prepared = try await LocalSourceLibrary.shared.refreshIfChanged(address: entry.address, http: http)
                    if let prepared {
                        let values = try await prepared.subscriptions(http: http)
                        guard subscriptionAutoUpdateEnabled, !restoringBackup,
                              subscriptions.contains(where: { $0.address == entry.address && $0.enabled }),
                              let index = prepared.records.firstIndex(where: { $0.address.absoluteString == entry.address }) else { continue }
                        try await LocalSourceLibrary.shared.commit(prepared)
                        guard subscriptions.contains(where: { $0.address == entry.address && $0.enabled }) else { continue }
                        keep(values[index], for: entry); changed = true
                    }
                } else {
                    let result = try await http.subscriptionUpdate(WebAddress.resolve(entry.address), previous: documents[entry.address],
                                                                   fingerprint: subscriptionUpdateFingerprints[entry.address])
                    guard subscriptionAutoUpdateEnabled, !restoringBackup,
                          subscriptions.contains(where: { $0.address == entry.address && $0.enabled }) else { continue }
                    if let value = result.subscription { keep(value, for: entry); changed = true }
                    subscriptionUpdateFingerprints[entry.address] = result.fingerprint
                    saveSubscriptionUpdateFingerprints()
                }
                subscriptionErrors[entry.address] = nil
                succeeded = true
            } catch {
                guard subscriptions.contains(where: { $0.address == entry.address && $0.enabled }) else { continue }
                subscriptionErrors[entry.address] = error.localizedDescription
                Diagnostics.shared.failure("subscription", "automatic update host=\(URL(string: entry.address)?.host() ?? "-")", error)
            }
        }
        if changed { rebuildSubscription() }
    }
    private func saveSubscriptionUpdateFingerprints() {
        guard persistsChanges else { return }
        defaults.set(try? JSONEncoder().encode(subscriptionUpdateFingerprints), forKey: "local.subscription.autoUpdate.fingerprints")
    }
    func importLocalSources(_ urls: [URL], group: LocalSourceGroup, containingFolder: URL? = nil, name: String? = nil,
                            importingCopy: Bool = false) async {
        guard !importing else { return }
        importing = true; importError = nil; notice = nil
        defer { importing = false }
        let scoped = (urls + (containingFolder.map { [$0] } ?? [])).filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        do {
            let prepared = try await LocalSourceLibrary.shared.prepare(urls, group: group, http: http, containingFolder: containingFolder,
                                                                       name: name, importingCopy: importingCopy)
            let copies = try await prepared.subscriptions(http: http)
            try await LocalSourceLibrary.shared.commit(prepared)
            for (record, copy) in zip(prepared.records, copies) {
                let entry = SubscriptionEntry(address: record.address.absoluteString, name: record.name, enabled: false)
                if let index = subscriptions.firstIndex(where: { $0.address == entry.address }) {
                    subscriptions[index].name = record.name
                } else { subscriptions.append(entry) }
                localSourceGroups[entry.address] = group
                keep(copy, for: entry)
            }
            let enabled = group == .subscription ? Array(prepared.records.prefix(1)) : prepared.records
            for record in enabled {
                subscriptions = LocalSourcePolicy.setting(record.address.absoluteString, enabled: true, in: subscriptions, groups: localSourceGroups)
            }
            saveSubscriptionList(); rebuildSubscription()
            notice = group == .live
                ? "已导入 \(copies.reduce(0) { $0 + $1.lives.count }) 个直播列表"
                : "已导入 \(copies.reduce(0) { $0 + $1.sites.count }) 个来源"
        } catch { importError = error.localizedDescription }
    }
    func importSourceAddresses(_ text: String, group: LocalSourceGroup, name: String? = nil) async {
        let addresses = text.split(whereSeparator: { $0.isNewline }).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !addresses.isEmpty else { return }
        if group != .subscription {
            do { await importLocalSources(try addresses.map { try WebAddress.resolve($0) }, group: group, name: name) }
            catch { importError = error.localizedDescription }
        } else {
            for address in addresses {
                do {
                    let url = try WebAddress.resolve(address)
                    if url.pathExtension.lowercased() == "md5" || url.lastPathComponent == "index.js" {
                        await importLocalSources([url], group: group, name: name)
                    } else { await importSubscription(address: address, name: name) }
                } catch { importError = error.localizedDescription }
                if importError != nil { break }
            }
        }
    }
    func refreshSourceGroup(_ group: LocalSourceGroup) async {
        guard !importing else { return }
        importing = true; importError = nil
        defer { importing = false }
        await fetch(managedSubscriptions(in: group).filter(\.enabled))
    }
    func refreshSource(_ entry: SubscriptionEntry) async {
        guard !importing else { return }
        importing = true; importError = nil
        defer { importing = false }
        await fetch([entry])
    }
    func moveManagedSubscription(_ entry: SubscriptionEntry, by offset: Int) {
        guard !restoringBackup, !importing, offset != 0 else { return }
        let group = localSourceGroups[entry.address] ?? .subscription
        var shown = managedSubscriptions(in: group)
        guard let index = shown.firstIndex(where: { $0.address == entry.address }),
              offset >= -index, offset < shown.count - index else { return }
        let moved = shown.remove(at: index)
        shown.insert(moved, at: index + offset)
        let addresses = Set(shown.map(\.address))
        var next = shown.makeIterator()
        // Preserve every other group's slots and all enabled/selection metadata.
        for slot in subscriptions.indices where addresses.contains(subscriptions[slot].address) {
            subscriptions[slot] = next.next()!
        }
        saveSubscriptionList(); rebuildSubscription()
    }
    func moveManagedSubscription(_ address: String, onto target: String) {
        let group = localSourceGroups[address] ?? .subscription
        let shown = managedSubscriptions(in: group)
        guard let from = shown.firstIndex(where: { $0.address == address }),
              let to = shown.firstIndex(where: { $0.address == target }) else { return }
        moveManagedSubscription(shown[from], by: to - from)
    }
    /// Adds the typed address, or refreshes it when it is already in the list. A directory (多仓)
    /// adds every subscription it lists, switched off, for the viewer to choose from.
    /// `address` is one typed in Settings, or one a link or a file handed over; `name` labels it the way a
    /// typed name does, and stays empty for a file.
    func importSubscription(address: String? = nil, name: String? = nil) async {
        let proposed = address ?? subscriptionAddress
        if let url = try? WebAddress.resolve(proposed), url.pathExtension.lowercased() == "py" || url.pathExtension.lowercased() == "md5" || url.lastPathComponent == "index.js" {
            await importLocalSources([url], group: url.pathExtension.lowercased() == "py" ? .python : .subscription, name: name)
            return
        }
        guard !importing else { return }
        importing = true; importError = nil; notice = nil
        defer { importing = false }
        let typed = (address ?? subscriptionAddress).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let url = try WebAddress.resolve(typed)
            switch try await http.subscriptionImport(url) {
            case .subscription(let value):
                let typedName = (address == nil ? subscriptionName : (name ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
                let previousName = subscriptions.first { $0.address == url.absoluteString }?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = typedName.isEmpty ? (previousName.isEmpty ? LocalSourcePolicy.name(for: url) : previousName) : typedName
                let entry = SubscriptionEntry(address: url.absoluteString, name: title)
                if let index = subscriptions.firstIndex(where: { $0.address == entry.address }) {
                    subscriptions[index].enabled = true
                    if !title.isEmpty { subscriptions[index].name = title }
                } else { subscriptions.append(entry) }
                localSourceGroups[entry.address] = .subscription
                subscriptions = LocalSourcePolicy.setting(entry.address, enabled: true, in: subscriptions, groups: localSourceGroups)
                keep(value, for: entry)
                if persistsChanges { defaults.set(url.absoluteString, forKey: "subscriptionAddress") }
                notice = L10n.text("Imported sources: %lld · Live playlists: %lld", value.sites.count, value.lives.count)
            case .directory(let entries):
                let added = entries.filter { entry in !subscriptions.contains { $0.address == entry.address } }
                subscriptions += added
                notice = L10n.text("This address lists %lld subscriptions. They were added switched off; turn on the ones you want.", added.count)
            case .comicSources(let count):
                // Comic source lists feed Manga (and show it); they are listed under Subscriptions too.
                MangaStore.shared.addRepository(url)
                notice = L10n.text("Added a Venera comic source list (%lld sources). Choose the ones to install in Comic Sources.", count)
            case .alist(let servers):
                // AList servers are browsed in Cloud Files, not merged as sources.
                let saved = try AListServers.add(servers)
                notice = saved.count == 1 ? L10n.text("Added the AList server %@. Browse it in Cloud Files.", saved[0].name)
                    : L10n.text("Added %lld AList servers. Browse them in Cloud Files.", saved.count)
            }
            if address == nil { subscriptionAddress = ""; subscriptionName = "" }
            saveSubscriptionList()
            rebuildSubscription()
        } catch {
            Diagnostics.shared.failure("subscription", "import host=\((try? WebAddress.resolve(typed))?.host() ?? "-")", error)
            importError = L10n.text("Import failed: %@", error.localizedDescription)
        }
    }
    /// Adds a subscription, or one spider script, from a file the viewer picked. The file is copied
    /// into the app (see `ImportedFiles`) and then added like an address.
    func importSubscriptionFile(_ file: URL) async {
        if ["py", "zip", "md5"].contains(file.pathExtension.lowercased()) || file.lastPathComponent == "index.js" || (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            await importLocalSources([file], group: file.pathExtension.lowercased() == "py" ? .python : .subscription)
            return
        }
        let scoped = file.startAccessingSecurityScopedResource()
        let copied = Result { try ImportedFiles.add(file) }
        if scoped { file.stopAccessingSecurityScopedResource() }
        guard case .success(let url) = copied else {
            if case .failure(let error) = copied { importError = L10n.text("Import failed: %@", error.localizedDescription) }
            return
        }
        let address = url.absoluteString, known = subscriptions.contains { $0.address == address }
        await importSubscription(address: address)
        // A file that added no subscription of its own leaves no copy behind.
        if !known, !subscriptions.contains(where: { $0.address == address }) { ImportedFiles.remove(address) }
    }
    /// Fetches every enabled subscription again; one that fails keeps its last good copy.
    func refreshSubscriptions() async {
        guard !importing else { return }
        importing = true; importError = nil; notice = nil
        defer { importing = false }
        await fetch(subscriptions.filter(\.enabled))
        refreshCloudSources(force: true)
        let failed = subscriptions.filter { $0.enabled && subscriptionErrors[$0.address] != nil }.count
        if failed > 0 { notice = L10n.text("%lld subscriptions could not be refreshed; their last copies stay in use.", failed) }
    }
    func setSubscription(_ entry: SubscriptionEntry, enabled: Bool) async {
        guard !importing, subscriptions.contains(where: { $0.address == entry.address }) else { return }
        if enabled, documents[entry.address] == nil {
            importing = true
            defer { importing = false }
            do {
                let value: Subscription
                if URL(string: entry.address)?.host()?.lowercased() == "sources.yingxia.invalid" {
                    value = try await LocalSourceLibrary.shared.storedSubscription(address: entry.address, http: http)
                } else {
                    guard case .subscription(let loaded) = try await http.subscriptionImport(WebAddress.resolve(entry.address)) else {
                        throw TVError.unsupported("此地址没有可启用的订阅内容，请先更新来源")
                    }
                    value = loaded
                }
                guard subscriptions.contains(where: { $0.address == entry.address }) else { return }
                keep(value, for: entry)
            } catch {
                subscriptionErrors[entry.address] = error.localizedDescription
                return
            }
        }
        subscriptions = LocalSourcePolicy.setting(entry.address, enabled: enabled, in: subscriptions, groups: localSourceGroups)
        saveSubscriptionList()
        rebuildSubscription()
    }
    /// Names a subscription in Settings and Sources; an empty name shows where it lives again.
    func renameSubscription(_ entry: SubscriptionEntry, to name: String) {
        guard !restoringBackup else { return }
        guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }), subscriptions[index].name != name else { return }
        subscriptions[index].name = name
        saveSubscriptionList()
    }
    func removeSubscription(_ entry: SubscriptionEntry) { removeSubscriptions([entry.address]) }
    /// Removes several subscriptions and their saved copies, then merges what is left once.
    func removeSubscriptions(_ addresses: Set<String>) {
        guard !restoringBackup, !importing else { return }
        let removed = subscriptions.filter { addresses.contains($0.address) }
        guard !removed.isEmpty else { return }
        subscriptions.removeAll { addresses.contains($0.address) }
        for entry in removed {
            documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
            localSourceGroups[entry.address] = nil
            subscriptionUpdateFingerprints[entry.address] = nil
            subscriptionUpdateSchedule.forget(entry.address)
            Task { try? await LocalSourceLibrary.shared.remove(address: entry.address) }
            if persistsChanges { try? FileManager.default.removeItem(at: Self.file(for: entry)); ImportedFiles.remove(entry.address) }
        }
        saveSubscriptionList()
        saveSubscriptionUpdateFingerprints()
        rebuildSubscription()
    }
    /// Moves a subscription one place up (-1) or down (1); earlier subscriptions win duplicate sources.
    func moveSubscription(_ entry: SubscriptionEntry, by offset: Int) {
        guard !restoringBackup else { return }
        guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }),
              subscriptions.indices.contains(index + offset) else { return }
        subscriptions.swapAt(index, index + offset)
        saveSubscriptionList()
        rebuildSubscription()
    }
    func moveSourceGroup(_ address: String, onto target: String, includeHidden: Bool) {
        guard !restoringBackup else { return }
        let shown = sourceGroups(includeHidden: includeHidden).compactMap { group -> String? in
            guard case .subscription(let value) = group.kind else { return nil }
            return value
        }
        let next = SubscriptionOrder.moving(address, onto: target, in: shown)
        guard next != shown else { return }
        subscriptions = SubscriptionOrder.applying(displayed: next, to: subscriptions)
        saveSubscriptionList()
        rebuildSubscription()
    }

    /// Fetches subscriptions side by side, keeps what arrives, and shows the merged result. A
    /// subscription that turns out to be a directory is replaced by the ones it lists, switched off.
    private func fetch(_ entries: [SubscriptionEntry]) async {
        let http = http
        let owned = entries.filter { URL(string: $0.address)?.host() == "sources.yingxia.invalid" }
        for entry in owned {
            do {
                let prepared = try await LocalSourceLibrary.shared.refresh(address: entry.address, http: http)
                let values = try await prepared.subscriptions(http: http)
                guard let record = prepared.records.firstIndex(where: { $0.address.absoluteString == entry.address }) else { continue }
                try await LocalSourceLibrary.shared.commit(prepared)
                // A removal while this request ran must not resurrect the source.
                if subscriptions.contains(where: { $0.address == entry.address }) { keep(values[record], for: entry) }
            } catch { subscriptionErrors[entry.address] = error.localizedDescription }
        }
        let remoteEntries = entries.filter { URL(string: $0.address)?.host() != "sources.yingxia.invalid" }
        let results = await withTaskGroup(of: (SubscriptionEntry, Result<SubscriptionImport, any Error>).self) { group in
            for entry in remoteEntries {
                group.addTask {
                    do { return (entry, .success(try await http.subscriptionImport(WebAddress.resolve(entry.address)))) }
                    catch { return (entry, .failure(error)) }
                }
            }
            var all: [(SubscriptionEntry, Result<SubscriptionImport, any Error>)] = []
            for await result in group { all.append(result) }
            return all
        }
        for (entry, result) in results {
            switch result {
            case .success(.subscription(let value)): keep(value, for: entry)
            case .success(.directory(let listed)):
                guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }) else { continue }
                let known = Set(subscriptions.map(\.address))
                subscriptions.replaceSubrange(index...index, with: listed.filter { !known.contains($0.address) })
            case .success(.comicSources):
                subscriptionErrors[entry.address] = L10n.text("This address is now a comic source list. Add it again to use it for Manga.")
            case .success(.alist):
                subscriptionErrors[entry.address] = L10n.text("This address is now an AList server. Add it again to browse it in Cloud Files.")
            case .failure(let error):
                Diagnostics.shared.failure("subscription", "refresh host=\(URL(string: entry.address)?.host() ?? "-")", error)
                subscriptionErrors[entry.address] = error.localizedDescription
            }
        }
        saveSubscriptionList()
        rebuildSubscription()
    }
    private func keep(_ value: Subscription, for entry: SubscriptionEntry) {
        documents[entry.address] = value
        // A manual import/refresh changes the baseline too. Establish its raw MD5
        // on the next check instead of comparing against an older document's hash.
        if subscriptionUpdateFingerprints.removeValue(forKey: entry.address) != nil { saveSubscriptionUpdateFingerprints() }
        subscriptionErrors[entry.address] = nil
        if persistsChanges, let data = try? JSONEncoder().encode(value) { try? Self.save(data, to: Self.file(for: entry)) }
    }
    private func saveSubscriptionList() {
        guard persistsChanges else { return }
        defaults.set(try? JSONEncoder().encode(subscriptions), forKey: "subscriptions")
        defaults.set(try? JSONEncoder().encode(localSourceGroups), forKey: "localSourceGroups")
        cloudSync?.changed("subscriptions")
    }
    /// Restored code is indexed but stays inactive until explicitly enabled.
    /// Keeping prior cached documents allows an undo without network or scripts.
    func applyBackupSubscriptions(_ incoming: [SubscriptionEntry], groups: [String: LocalSourceGroup], replacing: Bool, activate: Bool = false,
                                  restoredDocuments: [String: Subscription]? = nil) throws {
        var next = replacing ? [] : subscriptions
        for var entry in incoming {
            if !activate { entry.enabled = false }
            if let index = next.firstIndex(where: { $0.address == entry.address }) {
                if replacing || activate { next[index] = entry }
            } else { next.append(entry) }
        }
        var nextGroups = replacing ? [:] : localSourceGroups
        for entry in incoming { nextGroups[entry.address] = groups[entry.address] ?? .subscription }
        if let restoredDocuments {
            for entry in incoming {
                if let document = restoredDocuments[entry.address] { try Self.save(JSONEncoder().encode(document), to: Self.file(for: entry)) }
                else if FileManager.default.fileExists(atPath: Self.file(for: entry).path) { try FileManager.default.removeItem(at: Self.file(for: entry)) }
            }
        } else if replacing && !activate {
            for entry in incoming where FileManager.default.fileExists(atPath: Self.file(for: entry).path) {
                try FileManager.default.removeItem(at: Self.file(for: entry))
            }
        }
        next = LocalSourcePolicy.normalized(next, groups: nextGroups)
        let data = try JSONEncoder().encode(next), groupData = try JSONEncoder().encode(nextGroups)
        defaults.set(data, forKey: "subscriptions"); defaults.set(groupData, forKey: "localSourceGroups")
        subscriptions = next; localSourceGroups = nextGroups
        if let restoredDocuments { documents = restoredDocuments }
        else if replacing && !activate {
            for entry in incoming { documents[entry.address] = nil; subscriptionErrors[entry.address] = nil }
        } else if activate {
            for entry in incoming where documents[entry.address] == nil {
                if let data = try? Data(contentsOf: Self.file(for: entry)), let copy = try? JSONDecoder().decode(Subscription.self, from: data) { documents[entry.address] = copy }
            }
        }
        // Restore/undo replaces documents outside keep(_:for:). Their MD5 baselines
        // belong to the replaced snapshots, including values persisted before undo.
        subscriptionUpdateFingerprints.removeAll()
        saveSubscriptionUpdateFingerprints()
        rebuildSubscription()
        cloudSync?.changed("subscriptions")
    }
    func stopForBackupRestore() {
        cancelResume(); cancelEpisodeSelection(); music.stop(); playing = nil
        localReading?.close(); localReading = nil
        #if os(iOS)
        PlaybackSession.current?.stop()
        #endif
    }
    /// Favorites, Continue Watching, subscriptions and the viewer's pins, hides and order follow them to their other
    /// devices. Continue Watching changes every few seconds while a video plays, so it waits longer between writes.
    private func setUpCloudSync() {
        guard let sync = cloudSync else { return }
        let favorites = favorites, history = playbackHistory, pinned = pinnedSources, hidden = hiddenSources, order = sourceOrder
        sync.register("favorites", current: { favorites.syncValues }, apply: { favorites.adopt($0) })
        sync.register("history", delay: .seconds(30), current: { Dictionary(history.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) },
                      apply: { history.adopt($0.map(\.value)) })
        sync.register("subscriptions", current: { [weak self] in self?.syncedSubscriptions ?? [:] }, apply: { [weak self] in self?.adoptSubscriptions($0) })
        sync.register("pinnedSources", current: { CloudSync.ranks(pinned.savedKeys) }, apply: { pinned.adopt(CloudSync.ordered($0)) })
        sync.register("hiddenSources", current: { Dictionary(hidden.savedKeys.map { ($0, true) }, uniquingKeysWith: { first, _ in first }) },
                      apply: { hidden.adopt($0.sorted { ($0.stamp, $0.id) < ($1.stamp, $1.id) }.map(\.id)) })
        sync.register("sourceOrder", current: { CloudSync.ranks(order.savedKeys) }, apply: { order.adopt(CloudSync.ordered($0)) })
        // Only "on" is an item: a new device's default (off) is no change, so it can't switch the order off everywhere.
        sync.register("sourceOrderOn", current: { order.enabled ? ["on": true] : [:] }, apply: { if order.enabled == $0.isEmpty { order.enabled = !$0.isEmpty } })
        favorites.onChange = { sync.changed("favorites") }
        history.onChange = { sync.changed("history") }
        pinned.onChange = { sync.changed("pinnedSources") }
        hidden.onChange = { sync.changed("hiddenSources") }
        order.onChange = { sync.changed("sourceOrder"); sync.changed("sourceOrderOn") }
    }
    private var syncedSubscriptions: [String: SyncedSubscription] {
        Dictionary(subscriptions.enumerated().map { ($0.element.address, SyncedSubscription(entry: $0.element, rank: $0.offset, group: localSourceGroups[$0.element.address] ?? .subscription)) },
                   uniquingKeysWith: { first, _ in first })
    }
    /// Subscriptions another device added, renamed, switched, moved or removed. A new one that is on loads.
    private func adoptSubscriptions(_ synced: [CloudSyncItem<SyncedSubscription>]) {
        guard !restoringBackup else { return }
        let ordered = synced.sorted { ($0.value.rank, $0.id) < ($1.value.rank, $1.id) }.map(\.value)
        let next = ordered.map(\.entry)
        var groups: [String: LocalSourceGroup] = [:]
        for value in ordered {
            let address = value.entry.address
            let sites = documents[address]?.sites ?? []
            let inferred: LocalSourceGroup = (!sites.isEmpty && sites.allSatisfy { $0.runtime == .python }) || URL(string: address)?.pathExtension.lowercased() == "py" ? .python : .subscription
            groups[address] = value.group ?? localSourceGroups[address] ?? inferred
        }
        let normalized = LocalSourcePolicy.normalized(next, groups: groups)
        guard normalized != subscriptions || groups != localSourceGroups else { return }
        let kept = Set(next.map(\.address))
        for entry in subscriptions where !kept.contains(entry.address) {
            documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
            try? FileManager.default.removeItem(at: Self.file(for: entry))
        }
        localSourceGroups = groups
        subscriptions = normalized
        saveSubscriptionList()
        rebuildSubscription()
        if subscriptions.contains(where: { $0.enabled && documents[$0.address] == nil }) { Task { await restoreSubscription() } }
    }
    /// Shows every enabled subscription that has a copy, merged in list order.
    private func rebuildSubscription(resetting: Bool = true) {
        if resetting { cancelResume(); searchModel.reset(); recommendationModel.reset() }
        var enabledDocuments = subscriptions.filter(\.enabled).compactMap { entry -> Subscription? in
            guard let document = documents[entry.address] else { return nil }
            // A document filed under Live merges as its playlists only, whatever else it carries.
            return localSourceGroups[entry.address] == .live ? document.livesOnly() : document
        }
        #if os(iOS)
        enabledDocuments = enabledDocuments.map(LocalEditionPolicy.importedCatalog)
        #endif
        let activeDanmakuSubscription = subscriptions.first {
            $0.enabled && localSourceGroups[$0.address] == .subscription
        }.flatMap { documents[$0.address] }
        CatPawDanmaku.configure(subscriptions: enabledDocuments, activeSubscription: activeDanmakuSubscription)
        subscription = Subscription.merge(enabledDocuments)?.withCloudSources(extrasUnlocked ? cloudDocument : nil)
        let owners = Dictionary(subscriptions.compactMap { entry -> (URL, String)? in
            guard let document = documents[entry.address] else { return nil }
            return (PlaybackHistoryContext.sourceIdentity(document.origin), localSourceGroups[entry.address] == .python ? "" : entry.address)
        }, uniquingKeysWith: { first, _ in first })
        playbackHistory.migrateLegacyScopes(owners)
        playbackHistory.recordingScope = historyScope ?? ""
        refreshCloudSources()
        if let subscription {
            Self.registerPlugins(subscription)
            hiddenSources.restoreBuiltIns(subscription.sites, origin: subscription.origin)
            hiddenSources.restoreAutoHidden(subscription.sites, origin: subscription.origin, health: .shared)
            #if os(iOS) || os(tvOS)
            // Converts the visible JAR sources' likely classes while the app sits idle (issue #274).
            let visible = subscription.sites.filter { !hiddenSources.contains($0, origin: subscription.origin) }
            let origin = subscription.origin, spider = subscription.spiderURL
            Task { await PluginConversionAhead.shared.schedule(sites: visible, origin: origin, spider: spider) }
            #endif
        }
    }
    /// Fetches Yingxia's own subscription while a subscription works: at once when there is no copy, else
    /// every ten minutes at most. A failed fetch keeps the last copy.
    private func refreshCloudSources(force: Bool = false) {
        guard extrasUnlocked, cloudFetch == nil else { return }
        if !force, cloudDocument != nil, let fetched = cloudFetchedAt, Date.now.timeIntervalSince(fetched) < 600 { return }
        let http = http, persists = persistsChanges
        cloudFetch = Task { [weak self] in
            let result: Result<Subscription, any Error>
            do { result = .success(try await CloudSources.fetch(http: http)) } catch { result = .failure(error) }
            guard let self else { return }
            self.cloudFetch = nil
            self.cloudFetchedAt = .now
            switch result {
            case .success(let document):
                if persists, let data = try? JSONEncoder().encode(document) { try? Self.save(data, to: Self.cloudFile) }
                CloudSources.current = document
                #if !os(iOS)
                let changed = (try? JSONEncoder().encode(document.raw)) != (try? JSONEncoder().encode(self.cloudDocument?.raw))
                #endif
                self.cloudDocument = document
                #if !os(iOS)
                if changed { self.rebuildSubscription() }
                #endif
            case .failure(let error):
                Diagnostics.shared.failure("subscription", "built-in sources", error)
            }
        }
    }
    private func refreshCloudFilesSources() {
        #if !os(iOS)
        guard let subscription, subscription.sites.filter(\.isCloudFiles) != CloudFilesSource.sites() else { return }
        rebuildSubscription()
        #endif
    }
    func searchVideos(_ title: String) {
        guard let config = subscription else { return }
        let keyword = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        let old = defaults.data(forKey: "videoSearchHistory").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        defaults.set(try? JSONEncoder().encode(Array(([keyword] + old.filter { $0 != keyword }).prefix(20))), forKey: "videoSearchHistory")
        searchModel.search(keyword, config: config) { [hiddenSources] site in
            hiddenSources.contains(site, origin: config.origin)
        }
        section = .search
    }
    func toggleFavorite(_ channel: Channel) { favorites.toggle(.live(channel)) }
    func isFavorite(_ channel: Channel) -> Bool { favorites.contains(.live(channel)) }

    func catalogClient(for video: FavoriteVideo) -> CatalogClient? {
        if video.origin == LocalMediaLibrary.origin, let client = LocalMediaLibrary.shared.client(sourceKey: video.sourceKey, videoID: video.videoID) {
            return subscription.map { client.applying($0) } ?? client
        }
        guard let config = subscription,
              let site = config.sites.first(where: { $0.origin(or: config.origin) == video.origin && $0.sourceKey == video.sourceKey }) else { return nil }
        let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
        if let push = PushMediaLibrary.shared.record(origin: video.origin, sourceKey: video.sourceKey, videoID: video.videoID) {
            return client.withPushInput(push.input, flags: push.flags)
        }
        return client
    }
    func reportMissingFavoriteSource() {
        error = L10n.text("This favorite's source is no longer in the current subscription. Restore that subscription to open it.")
    }

    func play(_ episode: FavoriteEpisode) {
        guard catalogClient(for: episode.video) != nil else { reportMissingFavoriteSource(); return }
        let position = episode.resumePosition(in: visibleHistory)
        var context = episode.historyContext(); context.historyScope = historyScope ?? ""
        resume(PlaybackHistoryEntry(context: context, position: position, duration: 0, updatedAt: Date()))
    }

    func play(_ file: FavoriteCloudFile) {
        guard let drive = CloudFiles.drive(key: file.driveKey) else {
            error = L10n.text("This file's drive is no longer in Cloud Files.")
            return
        }
        let cloud = CloudFile(id: file.fileID, name: file.fileName, isFolder: false, size: file.size)
        playFile(cloud, in: CloudFilesFolder(drive: drive, id: file.folderID, name: file.folderName, files: [cloud]))
    }

    /// The Watch Now source row: pinned, then built-in, then the sources page's subscription order.
    func recommendationSites(_ config: Subscription) -> [Site] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = recommendationCache { return cached }
        let leading = automaticSites(config)
        let pinned = leading.filter { pinnedSources.contains($0, origin: config.origin) }
        let builtIn = leading.filter { $0.isBuiltIn && !pinnedSources.contains($0, origin: config.origin) }
        let groups = sourceGroups(includeHidden: false)
        let result = SourceGroups.homeRow(pinned: pinned, builtIn: builtIn, groups: groups)
        rememberSiteLists(stamp)
        recommendationCache = result
        return result
    }

    /// The sources to show, in the viewer's own order while it is on.
    func orderedSites(_ config: Subscription) -> [Site] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = orderedCache { return cached }
        let sites = automaticSites(config)
        let arranged = sourceOrder.enabled ? sourceOrder.arrange(sites, origin: config.origin) : sites
        rememberSiteLists(stamp)
        orderedCache = arranged
        return arranged
    }

    /// The home selector follows the subscription's own order, including changes
    /// made in its website. Pins and search runtime priority belong to their own lists.
    func homeSourceSites(_ config: Subscription) -> [Site] {
        SourceLists.browsable(config.sites, jarURL: config.spiderURL) {
            hiddenSources.contains($0, origin: config.origin)
        }
    }

    /// The order the app picks: built-in sources, then `SourceStrategy`'s, with pinned sources first. Hidden sources stay out.
    func automaticSites(_ config: Subscription) -> [Site] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = automaticCache { return cached }
        let sites = SourceLists.browsable(config.sites, jarURL: config.spiderURL) { hiddenSources.contains($0, origin: config.origin) }
        let arranged = pinnedSources.arrange(sites.filter(\.isBuiltIn) + sites.filter { !$0.isBuiltIn }, origin: config.origin)
        rememberSiteLists(stamp)
        automaticCache = arranged
        return arranged
    }

    /// Drops cached rows when their inputs changed. Each list fills itself, so a caller that only needs one does not build the others.
    private func rememberSiteLists(_ stamp: String) {
        guard stamp != siteListStamp else { return }
        siteListStamp = stamp
        automaticCache = nil
        orderedCache = nil
        recommendationCache = nil
        groupsCache = [:]
    }

    /// Turns the viewer's own source order on or off. The first time, it starts from the order on
    /// screen, so nothing jumps.
    func setCustomSourceOrder(_ enabled: Bool) {
        if enabled, sourceOrder.isEmpty, let config = subscription { sourceOrder.save(automaticSites(config), origin: config.origin) }
        sourceOrder.enabled = enabled
    }

    /// Moves a source within the viewer's order; `offset` is a position in `orderedSites`, as `move(fromOffsets:toOffset:)` takes it.
    func moveSource(_ site: Site, to offset: Int) {
        guard let config = subscription else { return }
        var sites = orderedSites(config)
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        sites.move(fromOffsets: [index], toOffset: max(0, min(offset, sites.count)))
        sourceOrder.save(sites, origin: config.origin)
    }

    /// The sources page's sections: pinned, built-in, then one per subscription.
    func sourceGroups(includeHidden: Bool) -> [SourceGroup] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = groupsCache[includeHidden] { return cached }
        guard let config = subscription else { return [] }
        let pins = pinnedSources.arrange(config.sites, origin: config.origin).filter { pinnedSources.contains($0, origin: config.origin) }
        var groups = SourceGroups.make(entries: subscriptions, documents: documents, builtIns: config.sites.filter(\.isBuiltIn), builtInOrigin: config.origin, mergedSites: config.sites, pinOrder: pins, userHidden: { hiddenSources.contains($0, origin: config.origin) }, includeHidden: includeHidden, jarURL: config.spiderURL)
        // The viewer's own order, while it is on, orders the sources inside each group too.
        if sourceOrder.enabled { groups = sourceOrder.arrange(groups, origin: config.origin) }
        rememberSiteLists(stamp)
        groupsCache[includeHidden] = groups
        return groups
    }

    func catalogChannel(_ resolved: Channel, video: Video, episode: Episode, client: CatalogClient,
                        resumePosition: Double? = nil) -> Channel {
        var channel = episodeChannel(resolved, video: video, episode: episode, client: client, resumePosition: resumePosition)
        if resumePosition == 0 { channel.playbackRequestID = UUID() }
        remember(video, client: client.with(parses: subscription?.parseServices ?? client.parses), for: channel)
        return channel
    }

    /// The channel that plays `episode`, without making its video the one playing.
    private func episodeChannel(_ resolved: Channel, video: Video, episode: Episode, client: CatalogClient,
                                resumePosition: Double? = nil) -> Channel {
        var context = PlaybackHistoryContext(origin: client.origin, site: client.site, video: video, episode: episode)
        context.historyScope = historyScope ?? ""
        if resolved.playback?.reading != nil, resumePosition != 0 {
            context.readingProgress = visibleHistory.first {
                PlaybackHistoryContext.sourceIdentity($0.context.origin) == PlaybackHistoryContext.sourceIdentity(context.origin) &&
                $0.context.sourceKey == context.sourceKey && $0.context.videoID == context.videoID && $0.context.episode(in: video.episodes) == episode
            }?.context.readingProgress
        }
        return Channel(name: "\(video.name) · \(episode.name)", group: resolved.group, url: resolved.url,
                       logo: resolved.logo, headers: resolved.headers, skipScope: context.id,
                       historyContext: context, resumePosition: resumePosition, subtitles: resolved.subtitles, playback: resolved.playback)
    }

    /// The video and its episode list, for the player's episode buttons and the next episode.
    private func remember(_ video: Video, client: CatalogClient, for channel: Channel) {
        guard let context = channel.historyContext else { return }
        if let data = try? JSONEncoder().encode(video) {
            MediaCache.shared.store(data, for: "detail", kind: .catalog, scope: context.id, ttl: 6 * 3600, ticket: MediaCache.shared.ticket())
        }
        // The Episodes menu's short labels (#318): kept from the episode before on the same video, else worked out off the
        // main thread.
        let kept = playbackCatalog.flatMap { $0.video == video ? $0 : nil }
        playbackCatalog = PlaybackCatalog(video: video, client: client, scope: context.id, labels: kept?.labels ?? [:], details: kept?.details ?? [:])
        guard kept == nil else { return }
        let episodes = video.episodes
        Task { [weak self] in
            let (labels, details) = await Task.detached(priority: .utility) {
                let labels = EpisodeLabels.labels(episodes)
                return (labels, EpisodeFileInfo.details(episodes, labels: labels))
            }.value
            // Still this video, though maybe the next episode by now.
            guard let self, !labels.isEmpty || !details.isEmpty, self.playbackCatalog?.video == video else { return }
            self.playbackCatalog?.labels = labels
            self.playbackCatalog?.details = details
        }
    }

    /// The next episode's stream, resolved ahead so the player can queue it behind this one; nil when
    /// auto-play is off, there is no next episode, or the source can't resolve it now.
    func upcomingEpisode(after channel: Channel) async -> Channel? {
        // Only while `channel` still plays: once the queue moves on, this was asked about the one before.
        let prefetch = playbackDefaults.object(forKey: "local.playback.prefetchNext") as? Bool ?? true
        if CloudFiles.isFile(channel.url) { return (autoPlayNext || prefetch) && playing == channel ? nextFile(after: channel) : nil }
        guard autoPlayNext || prefetch, let catalog = catalog(for: channel), let next = nextEpisode(after: channel) else { return nil }
        do {
            let resolved = try await catalog.client.playback(next)
            guard !Task.isCancelled, playing == channel else { return nil }
            return episodeChannel(resolved, video: catalog.video, episode: next, client: catalog.client)
        } catch {
            if !(error is CancellationError) { Diagnostics.shared.failure("catalog", "upcoming episode \(catalog.client.reportContext) flag=\(next.flag)", error) }
            return nil
        }
    }

    /// The queued episode started playing by itself: it becomes the one playing, as if it had been chosen.
    func advance(to next: Channel, from channel: Channel) {
        if CloudFiles.isFile(next.url), playing == channel { playing = next; return }
        guard playing == channel, let catalog = catalog(for: channel) else { return }
        cancelEpisodeSelection()
        remember(catalog.video, client: catalog.client, for: next)
        playing = next
    }

    func catalog(for channel: Channel) -> PlaybackCatalog? {
        guard let catalog = playbackCatalog, catalog.scope == channel.historyContext?.id else { return nil }
        return catalog
    }

    func nextEpisode(after channel: Channel) -> Episode? {
        guard let context = channel.historyContext else { return nil }
        return catalog(for: channel)?.playlist.next(after: context)
    }

    func previousEpisode(before channel: Channel) -> Episode? {
        guard let context = channel.historyContext else { return nil }
        return catalog(for: channel)?.playlist.previous(before: context)
    }

    /// The same episode on a transcoded line (FTY's 智 lines are the drive's own HLS) when the
    /// playing original can't play here. The same drive's line comes first: 夸父原1 → 夸父智1.
    func transcodedLine(for channel: Channel) -> Episode? {
        guard let context = channel.historyContext, let catalog = catalog(for: channel) else { return nil }
        let current = context.episodeFlag
        let candidates = catalog.video.episodes.filter {
            $0.name == context.episodeName && $0.flag != current && $0.flag.contains("智")
        }
        let sameDrive = current.replacingOccurrences(of: "原", with: "智").replacingOccurrences(of: "无限", with: "智")
        return candidates.first { $0.flag == sameDrive } ?? candidates.first
    }

    func selectEpisode(_ episode: Episode, from channel: Channel, failed: ((String) -> Void)? = nil) {
        guard playing == channel, let catalog = catalog(for: channel),
              catalog.video.episodes.contains(episode) else { return }
        cancelEpisodeSelection()
        let request = episodeRequest
        let sourceStarted = Date()
        Diagnostics.shared.record(.info, "player.startup", "entry=episode request=\(request) stage=resolve-begin")
        resolvingEpisode = episode; episodeError = nil
        episodeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.episodeRequest == request { self.resolvingEpisode = nil; self.episodeTask = nil } }
            do {
                let resolved = try await catalog.client.playback(episode)
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                Diagnostics.shared.record(.info, "player.startup", "entry=episode request=\(request) stage=source-ready elapsed=\(Date().timeIntervalSince(sourceStarted)) addr=\(PlaybackFailureDiagnostics.address(resolved.url))")
                self.playing = self.catalogChannel(resolved, video: catalog.video, episode: episode, client: catalog.client)
            } catch {
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                Diagnostics.shared.failure("catalog", "episode \(catalog.client.reportContext) flag=\(episode.flag)", error)
                self.episodeError = error.localizedDescription
                failed?(error.localizedDescription)
            }
        }
    }

    /// Resolves the playing episode from its source again, for the error
    /// page's Try Again. The address an episode was resolved to can die
    /// while the app is suspended — a bundle's local proxy loses its
    /// listening ports to iOS and the signed stream behind it expires — and
    /// preparing that same address again (all the session's own recovery
    /// and a plain restart ever do) fails identically forever. Choosing the
    /// episode in the list, or re-entering it from the history, works
    /// because it resolves the episode afresh; this is that same call for
    /// the episode already playing, and it keeps the place the history
    /// last recorded for it. False when the channel has no catalogue
    /// behind it (a file, a download, a direct address); the caller then
    /// falls back to restarting the channel as it is.
    @discardableResult func reresolvePlayingEpisode(from channel: Channel, failed: ((String) -> Void)? = nil) -> Bool {
        guard playing == channel, let catalog = catalog(for: channel),
              let context = channel.historyContext, let episode = context.episode(in: catalog.video.episodes) else { return false }
        cancelEpisodeSelection()
        let request = episodeRequest
        let sourceStarted = Date()
        Diagnostics.shared.record(.info, "player.startup", "entry=reresolve request=\(request) stage=resolve-begin")
        resolvingEpisode = episode; episodeError = nil
        episodeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.episodeRequest == request { self.resolvingEpisode = nil; self.episodeTask = nil } }
            do {
                let resolved = try await catalog.client.playback(episode)
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                Diagnostics.shared.record(.info, "player.startup", "entry=reresolve request=\(request) stage=source-ready elapsed=\(Date().timeIntervalSince(sourceStarted)) addr=\(PlaybackFailureDiagnostics.address(resolved.url))")
                let saved = self.visibleHistory.first { $0.context.id == context.id && $0.context.episodeID == context.episodeID && $0.context.episodeFlag == context.episodeFlag }
                var next = self.catalogChannel(resolved, video: catalog.video, episode: episode, client: catalog.client,
                                               resumePosition: saved?.resumePosition(for: episode))
                // A fresh request id makes the replay unmistakable even when
                // the source hands back the very address it gave before.
                next.playbackRequestID = UUID()
                self.playing = next
            } catch {
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                Diagnostics.shared.failure("catalog", "reresolve \(catalog.client.reportContext) flag=\(episode.flag)", error)
                self.episodeError = error.localizedDescription
                failed?(error.localizedDescription)
            }
        }
        return true
    }

    func cancelEpisodeSelection() {
        episodeRequest = UUID()
        episodeTask?.cancel(); episodeTask = nil; resolvingEpisode = nil
    }

    /// Resumes a watched title. Choosing another title while one is still being prepared switches
    /// to it: the earlier request is cancelled, which also stops its plugin call.
    func resume(_ entry: PlaybackHistoryEntry, mode: PlaybackResumeMode = .resume) {
        guard entry.context.libraryScope == historyScope else { error = "订阅已切换，请刷新观看记录"; return }
        guard historySourceEnabled(entry.context) else { error = L10n.text("This history source is no longer in the current subscription. Restore that subscription to continue."); return }
        resumeTask?.cancel()
        resumingHistoryID = entry.id
        resumeTask = Task { await resumeHistory(entry, mode: mode) }
    }

    func cancelResume() {
        resumeTask?.cancel(); resumeTask = nil
        resumingHistoryID = nil
    }

    /// The source a watched title came from. Any enabled subscription can hold it: it is found by its own origin
    /// and original key. Nil for Cloud Files, and once the source is gone.
    func historyClient(_ entry: PlaybackHistoryEntry) -> CatalogClient? {
        guard entry.context.libraryScope == historyScope, historySourceEnabled(entry.context) else { return nil }
        if entry.context.origin == LocalMediaLibrary.origin, let client = LocalMediaLibrary.shared.client(sourceKey: entry.context.sourceKey, videoID: entry.context.videoID) {
            return subscription.map { client.applying($0) } ?? client
        }
        guard entry.context.sourceKey != CloudFiles.sourceKey, let config = subscription,
              let site = config.sites.first(where: { PlaybackHistoryContext.sourceIdentity($0.origin(or: config.origin)) == PlaybackHistoryContext.sourceIdentity(entry.context.origin) && $0.sourceKey == entry.context.sourceKey })
        else { return nil }
        let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
        if let push = PushMediaLibrary.shared.record(origin: entry.context.origin, sourceKey: entry.context.sourceKey, videoID: entry.context.videoID) {
            return client.withPushInput(push.input, flags: push.flags)
        }
        return client
    }

    func resumeHistory(_ entry: PlaybackHistoryEntry, mode: PlaybackResumeMode = .resume) async {
        guard entry.context.libraryScope == historyScope else { error = "订阅已切换，请刷新观看记录"; return }
        guard historySourceEnabled(entry.context) else { error = L10n.text("This history source is no longer in the current subscription. Restore that subscription to continue."); return }
        let sourceStarted = Date(), startupRequest = UUID()
        Diagnostics.shared.record(.info, "player.startup", "entry=history request=\(startupRequest) stage=resolve-begin resume=\(mode == .resume)")
        defer { Diagnostics.shared.record(.info, "player.startup", "entry=history request=\(startupRequest) stage=resolve-end elapsed=\(Date().timeIntervalSince(sourceStarted)) cancelled=\(Task.isCancelled)") }
        resumingHistoryID = entry.id
        defer { if resumingHistoryID == entry.id, !Task.isCancelled { resumingHistoryID = nil } }
        if entry.context.sourceKey == CloudFiles.sourceKey {
            return resumeFile(PlaybackHistoryEntry(context: entry.context, position: entry.position(for: mode), duration: entry.duration, updatedAt: entry.updatedAt))
        }
        guard var client = historyClient(entry) else {
            error = L10n.text("This history source is no longer in the current subscription. Restore that subscription to continue.")
            return
        }
        let site = client.site
        let subscriptionOrigin = subscription?.origin
        let selectedScope = historyScope
        let previousPlayback = playing
        do {
            var htmlResolution = false
            #if os(iOS)
            if entry.context.origin == LocalMediaLibrary.origin,
               let record = LocalMediaLibrary.shared.record(sourceKey: entry.context.sourceKey, id: entry.context.videoID),
               record.requiresHTMLSelection == true {
                client = try LocalHTMLHomeActions.restoredClient(record)
                if let config = subscription { client = client.applying(config) }
                htmlResolution = true
            }
            #endif
            // Plugin/API sources resolve an episode again. Direct-file APIs must refresh
            // their detail first so an expiring media address never becomes a resume shortcut.
            var video = try await client.detail(entry.context.videoID, cached: site.type == 3 || site.type == 4)
            guard var episode = entry.context.episode(in: video.episodes) else {
                throw TVError.unsupported(L10n.text("The saved episode is no longer available from this source. Choose an episode again."))
            }
            let channel: Channel
            do { channel = try await client.playback(episode) }
            catch {
                try Task.checkCancellation()
                // The HTML resolver already refetched its original page with
                // a bounded deadline. Retrying its identical cached catalog
                // doubles a failed/source-verification wait without new input.
                if htmlResolution { throw error }
                video = try await client.detail(entry.context.videoID)
                guard let refreshed = entry.context.episode(in: video.episodes) else { throw error }
                episode = refreshed
                channel = try await client.playback(refreshed)
            }
            guard !Task.isCancelled, playing == previousPlayback, subscription?.origin == subscriptionOrigin, historyScope == selectedScope,
                  historySourceEnabled(entry.context) else { return }
            Diagnostics.shared.record(.info, "player.startup", "entry=history request=\(startupRequest) stage=source-ready elapsed=\(Date().timeIntervalSince(sourceStarted)) addr=\(PlaybackFailureDiagnostics.address(channel.url))")
            // A source whose details carry no poster keeps the one saved with the entry.
            // Page progress is separate from video seconds. Nil lets the reader resume its saved
            // page; zero remains the explicit replay command for either kind of media.
            let position: Double? = channel.playback?.reading != nil && mode == .resume && !entry.completed ? nil : entry.position(for: mode)
            playing = catalogChannel(channel, video: video.keepingPoster(entry.context.poster, headers: entry.context.posterHeaders),
                                     episode: episode, client: client, resumePosition: position)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            Diagnostics.shared.failure("catalog", "resume source=\(entry.context.sourceKey)", error)
            self.error = L10n.text("Unable to resume playback: %@", error.localizedDescription)
        }
    }
}

#if os(macOS)
extension Store {
    /// 1.7.7 moved the Mac app from `com.tvbox.yingxia.mac` to `com.jo32.yingxia.mac`, which starts a
    /// new defaults domain: subscriptions, favorites and settings would look lost. Copy the old domain
    /// over once (the app isn't sandboxed, so it can read it). Files under Application Support and
    /// Caches keep their `com.tvbox.yingxia` folder and need nothing.
    static func adoptPreviousBundleDefaults(_ defaults: UserDefaults) {
        let previous = "com.tvbox.yingxia.mac", done = "adoptedDefaults." + previous
        guard Bundle.main.bundleIdentifier != previous, !defaults.bool(forKey: done) else { return }
        for (key, value) in defaults.persistentDomain(forName: previous) ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: done)
    }
}
#endif

/// How this build reaches people. App Store and TestFlight builds are archived with
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) APPSTORE'`; direct downloads and sideloaded
/// builds leave it out.
enum Distribution {
    static var isAppStore: Bool {
        #if APPSTORE
        return true
        #else
        return false
        #endif
    }

    /// An App Store build installed from TestFlight, which leaves a sandbox receipt. A build promoted to the
    /// App Store gets a production receipt, so it stops sending people to TestFlight.
    static let isTestFlight: Bool = {
        #if APPSTORE
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #else
        return false
        #endif
    }()
}

// MARK: Cloud Files

/// A Cloud Files folder being played through: its files of the kind chosen, in order.
struct CloudFilesFolder {
    let drive: CloudFilesDrive
    let id: String
    let name: String
    let files: [CloudFile]
}

extension Store {
    /// Plays a file from Cloud Files, where it was left if it was being watched; the folder's other
    /// files follow it.
    func playFile(_ file: CloudFile, in folder: CloudFilesFolder) {
        let channel = CloudFiles.channel(file, in: folder.drive, folder: folder.id, folderName: folder.name)
        let saved = visibleHistory.first { $0.context.id == channel.historyContext?.id && $0.context.episodeID == file.id && !$0.completed }
        filesFolder = folder
        playing = scopedHistoryChannel(saved.map { CloudFiles.channel(file, in: folder.drive, folder: folder.id, folderName: folder.name, resumePosition: $0.resumePosition) } ?? channel)
    }

    func nextFile(after channel: Channel) -> Channel? { file(1, from: channel) }
    func previousFile(before channel: Channel) -> Channel? { file(-1, from: channel) }

    /// The file `offset` places from the playing one in its folder, for the player's Previous and Next.
    private func file(_ offset: Int, from channel: Channel) -> Channel? {
        guard let context = channel.historyContext, context.sourceKey == CloudFiles.sourceKey, let folder = filesFolder,
              folder.drive.key == context.episodeFlag, folder.id == context.videoID,
              let index = folder.files.firstIndex(where: { $0.id == context.episodeID }),
              folder.files.indices.contains(index + offset) else { return nil }
        return scopedHistoryChannel(CloudFiles.channel(folder.files[index + offset], in: folder.drive, folder: folder.id, folderName: folder.name))
    }

    /// Continue Watching on a Cloud Files folder: the file plays at once, and the folder is listed
    /// again meanwhile so the files after it still follow.
    fileprivate func resumeFile(_ entry: PlaybackHistoryEntry) {
        let context = entry.context
        guard let drive = CloudFiles.drive(key: context.episodeFlag) else {
            error = L10n.text("This file's drive is no longer in Cloud Files.")
            return
        }
        filesFolder = nil
        let channel = scopedHistoryChannel(CloudFiles.channel(context, resumePosition: entry.resumePosition))
        playing = channel
        Task { [weak self] in
            guard let files = try? await CloudFiles.list(drive, folder: context.videoID), let self, self.playing == channel else { return }
            let kind = CloudFile.kind(of: context.episodeName)
            self.filesFolder = CloudFilesFolder(drive: drive, id: context.videoID, name: context.videoName,
                                                files: files.filter { $0.kind == kind && drive.plays($0) })
        }
    }
}

struct PlaybackCatalog {
    let video: Video
    let client: CatalogClient
    let scope: String
    /// Short labels (第1集) for lines whose episode names are file names, by episode id.
    var labels: [Episode.ID: String] = [:]
    /// Resolution and size read from file names (4K · 5.2G, #620), shown under the episodes, by episode id.
    var details: [Episode.ID: String] = [:]
    var playlist: EpisodePlaylist { EpisodePlaylist(video.episodes) }
}

/// A subscription as iCloud sync keeps it: the entry and its place in the list.
struct SyncedSubscription: Codable, Equatable, Sendable {
    var entry: SubscriptionEntry
    var rank: Int
    /// Optional for compatibility with devices that synchronized only entry/rank.
    var group: LocalSourceGroup? = nil
}
