#if os(iOS)
import SwiftUI
import Perception
import AVKit
import TVCore

/// iPhone and iPad share one playback session, including while its PiP window owns the picture.
/// Every operation below targets KSPlaybackEngine; AVQueuePlayer is retained idle only for
/// source compatibility with helpers compiled for other platforms.
@MainActor @Perceptible final class PlaybackSession {
    static let sharedLocal = PlaybackSession()
    static weak var current: PlaybackSession?
    let engine = KSPlaybackEngine()
    let player = AVQueuePlayer()
    let enhancer: VideoEnhancer
    let catalogDanmaku = CatalogDanmakuModel()
    @PerceptionIgnored lazy var mediaEnhancements = NativeMediaEnhancements(catalog: catalogDanmaku)
    let remoteSkip = NativeRemoteSkip()
    @PerceptionIgnored lazy var aiSubtitles = NativeAISubtitles(session: self)
    let externalSubtitles = ExternalSubtitles()
    let subtitles = SubtitleCues()
    var pictureInPictureActive = false
    @PerceptionIgnored var pictureInPictureController: PictureInPicture?
    var orientationPolicy = PlaybackOrientationPolicy()
    var history = PlaybackHistory.shared
    var skipDefaults = UserDefaults.standard
    var error: String?
    var loading = true
    var looping = false { didSet { if looping { discardUpcoming() } } }
    private(set) var buffering = false
    private(set) var showsPicture = false
    private(set) var errorSymbol = "play.slash.fill"
    private(set) var restoredPosition: Double?
    private(set) var requestedResumePosition: Double?
    private(set) var skipSettings = EpisodeSkipSettings()
    var position: Double { engine.position }
    var duration: Double { engine.duration }
    var paused: Bool { engine.paused }
    var muted: Bool { engine.muted }
    var hasTimeline: Bool { engine.isReady && engine.seekable && engine.duration > 0 && !isLive }
    private(set) var isLive = false
    private(set) var qualities: [StreamQuality] = []
    private(set) var quality: Int?
    var audioChoices: [UngroupedAudio.Choice] { [] }
    var audioChoice: CMPersistentTrackID? { engine.tracks.first { $0.kind == .audio && $0.selected }.flatMap { Int32($0.id) } }
    private(set) var activeChannelID: String?
    @PerceptionIgnored private var activeObserver: NSObjectProtocol?
    @PerceptionIgnored private var lockObserver: NSObjectProtocol?
    @PerceptionIgnored private var lockPaused = false
    @PerceptionIgnored private var videoCacheObserver: NSObjectProtocol?
    @PerceptionIgnored private var cachePreparation: Task<Void, Never>?
    @PerceptionIgnored private var cachePreparationID = UUID()
    @PerceptionIgnored private var needsVideoCacheActivation = false
    @PerceptionIgnored private var recovery: Task<Void, Never>?
    @PerceptionIgnored private var recoveryAttempts = 0
    @PerceptionIgnored private var decoderRecoveryAttempts = 0
    @PerceptionIgnored private var lastRecovery: Date?
    var onPlaybackEnded: (() -> Void)?
    var onUnplayableFile: (() -> String?)?
    var upcomingEpisode: (@MainActor () async -> Channel?)?
    var playsOn: @MainActor () -> Bool = { false }
    var onAdvance: (@MainActor (Channel) -> Void)?
    private(set) var boost: Float?
    private(set) var boostWanted: Float?
    var preferredSpeed: Float { selectedSpeed }
    @PerceptionIgnored private var selectedSpeed: Float = 1
    @PerceptionIgnored private var throttle: SpeedBoost.Throttle?
    @PerceptionIgnored private var generation = UUID()
    @PerceptionIgnored private var preparation: Task<Void, Never>?
    @PerceptionIgnored private var sampler: Task<Void, Never>?
    @PerceptionIgnored private var transferTicker: Task<Void, Never>?
    @PerceptionIgnored private var runtimePinTask: Task<Void, Never>?
    @PerceptionIgnored private var runtimePinnedURLs = Set<URL>()
    @PerceptionIgnored private var enhancementTicker: Task<Void, Never>?
    @PerceptionIgnored private var preparationStarted = Date()
    @PerceptionIgnored private var discSelection: Task<Void, Never>?
    @PerceptionIgnored private var discSelectionID = UUID()
    private(set) var selectingDiscTitle = false
    var currentPlaybackURL: URL? { _ = engine.mediaID; return currentPrepared?.url }
    var currentPlaybackHeaders: [String: String] { _ = engine.mediaID; return currentPrepared?.headers ?? [:] }
    var currentAudioSamplingUsesSeparateInput: Bool { _ = engine.mediaID; return currentPrepared?.audioURL != nil }
    var currentAudioSamplingURL: URL? {
        _ = engine.mediaID
        guard let prepared = currentPrepared else { return nil }
        return prepared.audioCacheIOURL ?? prepared.audioURL ?? prepared.cacheIOURL ?? prepared.url
    }
    var currentAudioSamplingHeaders: [String: String] {
        _ = engine.mediaID
        guard let prepared = currentPrepared else { return [:] }
        if prepared.audioURL != nil {
            return prepared.audioHeaders.isEmpty ? prepared.headers : prepared.audioHeaders
        }
        // The app-owned cache may redirect an extensionless HLS input to its
        // original manifest. Sampling must retain authorization on that path.
        return prepared.headers
    }
    var discTitles: [DiscPlaybackTitle] { _ = engine.mediaID; return currentPrepared?.disc?.titles ?? [] }
    var selectedDiscPlaylist: UInt32? { _ = engine.mediaID; return currentPrepared?.disc?.playlist }
    @PerceptionIgnored private var chat: BilibiliLiveChat?
    @PerceptionIgnored private var chatGeneration = UUID()
    @PerceptionIgnored private var playing: Channel?
    @PerceptionIgnored private var sourceChannel: Channel?
    @PerceptionIgnored private var historyContext: PlaybackHistoryContext?
    @PerceptionIgnored private var pendingResume: Double?
    @PerceptionIgnored private var restoringPosition = false
    @PerceptionIgnored private var skipScope: String?
    @PerceptionIgnored private var skipPass = EpisodeSkipPass()
    @PerceptionIgnored private var editingSkip = false
    @PerceptionIgnored private var resumeAfterEditing = false
    @PerceptionIgnored private var seekingSegment = false
    @PerceptionIgnored private var automatic: URL?
    @PerceptionIgnored private var currentPrepared: Prepared?
    private var sourceDanmaku: [Danmaku] = []
    @PerceptionIgnored private var sourceDanmakuLoading: Task<Void, Never>?
    @PerceptionIgnored private var sourceDanmakuGeneration = UUID()
    @PerceptionIgnored private var sourceDanmakuLoaded = false
    @PerceptionIgnored private var savedDownload = false
    private var switchNotice: String?
    @PerceptionIgnored private var healthyPrefetchSince: Date?
    @PerceptionIgnored private var upcomingTask: Task<Void, Never>?
    @PerceptionIgnored private var upcoming: (Channel, Prepared)?
    @PerceptionIgnored private var upcomingAttempted = false
    @PerceptionIgnored private var prefetchWarm: Task<Void, Never>?
    @PerceptionIgnored private var prefetchComplete = false
    @PerceptionIgnored private var prefetchWarmID = UUID()
    @PerceptionIgnored private var advancing = false
    @PerceptionIgnored private var keepPausedAfterRestore = false
    private(set) var transfer = Transfer()
    private(set) var steps: [String] = []
    struct Transfer {
        var received: Int64 = 0
        var bytesPerSecond: Double?
        var required: Double?
        var host: String?
        var failure: String?
        var httpStatus: Int?
    }
    var danmaku: [Danmaku] {
        guard catalogDanmaku.enabled else { return [] }
        if mediaEnhancements.hasSelectedTrack { return mediaEnhancements.comments }
        if catalogDanmaku.selection.hasExplicitChoice { return catalogDanmaku.renderedComments }
        return sourceDanmaku.isEmpty || !LocalDanmakuPreferences.builtinEnabled() ? catalogDanmaku.renderedComments : sourceDanmaku
    }
    var danmakuOpacity: Double { catalogDanmaku.opacity }
    var danmakuRevision: String {
        if mediaEnhancements.hasSelectedTrack { return mediaEnhancements.revision.uuidString }
        return sourceDanmaku.isEmpty || catalogDanmaku.selection.hasExplicitChoice ? catalogDanmaku.renderedRevision : ""
    }
    var danmakuSourceRevision: String {
        if mediaEnhancements.hasSelectedTrack { return mediaEnhancements.sourceRevision.uuidString }
        return sourceDanmaku.isEmpty || catalogDanmaku.selection.hasExplicitChoice
            ? catalogDanmaku.renderedRevision : (engine.mediaID ?? "") + "|source"
    }
    init() {
        enhancer = VideoEnhancer(player: player)
        externalSubtitles.cues = subtitles
        catalogDanmaku.nativeSourceReload = { [weak self] in await self?.loadSourceDanmaku() }
        externalSubtitles.engine = engine
        externalSubtitles.changed = { [weak self] in self?.updateSubtitles() }
        subtitles.nativeChosen = { [weak self] in self?.externalSubtitles.nativeChosen() }
        engine.onReady = { [weak self] in self?.ready() }
        engine.onTick = { [weak self] in self?.updatePictureState(); self?.updateSubtitles() }
        engine.onFinish = { [weak self] error in self?.finished(error) }
        engine.onDecoderChange = { [weak self] in self?.reopenCurrent() }
        engine.pictureInPictureSubtitleProvider = { [weak self] time in
            guard let self else { return (PlayerSubtitlePresentation(), PlayerSubtitlePresentation()) }
            self.subtitles.updateKS(lines: self.engine.subtitleLines, pictureSize: self.engine.presentationSize)
            self.subtitles.advance(to: time)
            let external = self.externalSubtitles.document != nil
            let primary = PlayerSubtitlePresentation(lines: self.subtitles.lines,
                styledParts: external ? self.subtitles.styledParts : self.engine.subtitleStyledParts,
                sourceTime: external ? self.subtitles.styledSourceTime : self.engine.subtitleSourceTime,
                bitmaps: self.engine.subtitleBitmaps)
            let usesAI = !self.aiSubtitles.lines.isEmpty
            let secondary = PlayerSubtitlePresentation(lines: usesAI ? self.aiSubtitles.lines : self.engine.secondarySubtitleLines,
                styledParts: usesAI ? [] : self.engine.secondarySubtitleStyledParts,
                sourceTime: self.engine.secondarySubtitleSourceTime,
                bitmaps: usesAI ? [] : self.engine.secondarySubtitleBitmaps)
            return (primary, secondary)
        }
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverAfterForeground() }
        }
        lockObserver = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleDeviceLock() }
        }
        videoCacheObserver = NotificationCenter.default.addObserver(forName: MobileMediaServices.videoCacheChanged,
            object: nil, queue: .main) { [weak self] notification in
            let enabled = notification.userInfo?["enabled"] as? Bool ?? false
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.needsVideoCacheActivation = enabled
                if enabled { self.activateVideoCache() }
                else { self.cachePreparationID = UUID(); self.cachePreparation?.cancel(); self.cachePreparation = nil }
            }
        }
    }
    func togglePlayback() { if paused { engine.play() } else { engine.pause(); clearBoost() } }
    func skip(_ seconds: Double) { engine.seek(to: position + seconds) }
    func chooseAudio(_ id: CMPersistentTrackID) { engine.selectAudio(id: String(id)) }
    func setSpeed(_ speed: Float) { selectedSpeed = min(8, max(0.25, speed)); clearBoost(); engine.speed = selectedSpeed }
    func setBoost(_ rate: Float?) {
        guard rate == nil || !paused else { return }
        throttle = rate.map { SpeedBoost.Throttle(wanted: Double($0), after: throttle) }; applyBoost()
    }
    private func applyBoost() {
        boost = throttle.map { Float($0.rate) }; boostWanted = throttle.flatMap { $0.limited ? Float($0.wanted) : nil }
        engine.speed = boost ?? selectedSpeed
    }
    private func clearBoost() { throttle = nil; boost = nil; boostWanted = nil; engine.speed = selectedSpeed }
    func beginEditingSkip() { editingSkip = true; resumeAfterEditing = !paused; engine.pause() }
    func endEditingSkip() { editingSkip = false; if resumeAfterEditing { engine.play() }; resumeAfterEditing = false }
    func applySkipSettings(_ settings: EpisodeSkipSettings) {
        guard let skipScope else { return }
        settings.save(scope: skipScope, defaults: skipDefaults); skipSettings = settings; skipPass = EpisodeSkipPass(); remoteSkip.settingsChanged()
    }
    func lineSwitchFailed(_ message: String) { switchNotice = nil; error = message; loading = false }
    func start(_ channel: Channel) {
        Self.current = self
        if sourceChannel == channel, error == nil, engine.mediaID != nil { return }
        // A manual switch to the episode that is already prepared must consume
        // the preparation, not release it in stop() and resolve from cold.
        if consumeUpcoming(for: channel) { return }
        stop()
        begin(channel); sourceChannel = channel
        let active = generation
        preparation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == active { self.preparation = nil } }
            do {
                var next = channel
                var liveQualities: [StreamQuality] = [], liveQuality: Int?
                if let (platform, id) = LiveCatalog.room(channel.url), platform.chat == "bilibili", let room = Int(id) { self.listen(room: room) }
                if LiveCatalog.isRoom(channel.url) { (next, liveQualities, liveQuality) = try await LiveCatalog.resolve(channel) }
                let prepared = try await self.prepare(next)
                guard self.generation == active, !Task.isCancelled else { Self.release(next, prepared); return }
                self.playing = next
                self.currentPrepared = prepared
                self.automatic = prepared.url
                self.activeChannelID = channel.id
                let sourceQualities = PlaybackQualityRegistry.qualities(for: channel.url)
                self.qualities = sourceQualities.isEmpty ? liveQualities : sourceQualities
                self.quality = PlaybackQualityRegistry.selected(for: channel.url) ?? liveQuality
                self.open(prepared, channel: next)
                self.externalSubtitles.begin(next, playing: prepared.url)
                self.mediaEnhancements.begin(channel: channel, sessionID: active.uuidString.lowercased(), engine: self.engine)
                self.startSampler(generation: active)
                await self.loadSourceDanmaku()
            } catch {
                guard self.generation == active, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.loading = false
                Diagnostics.shared.failure("player", "KS prepare", error)
            }
        }
    }
    private func loadSourceDanmaku() async {
        guard LocalDanmakuPreferences.enabled(), LocalDanmakuPreferences.builtinEnabled(), !sourceDanmakuLoaded,
              let channel = sourceChannel, DanmakuSource.has(channel.url) else { return }
        if let sourceDanmakuLoading { await sourceDanmakuLoading.value; return }
        let active = sourceDanmakuGeneration
        let task = Task { [weak self] in
            guard let comments = await DanmakuSource.comments(for: channel.url), !Task.isCancelled, let self,
                  self.sourceDanmakuGeneration == active, !self.catalogDanmaku.selection.hasExplicitChoice,
                  LocalDanmakuPreferences.enabled(), LocalDanmakuPreferences.builtinEnabled() else { return }
            self.sourceDanmaku = comments; self.sourceDanmakuLoaded = true
            self.mediaEnhancements.sourceLoaded(count: comments.count)
        }
        sourceDanmakuLoading = task
        await task.value
        if sourceDanmakuGeneration == active { sourceDanmakuLoading = nil }
    }
    private func begin(_ channel: Channel) {
        error = nil; loading = true; showsPicture = false; buffering = false; steps = ["正在解析播放地址"]
        preparationStarted = Date()
        transfer = Transfer(); transfer.host = channel.url.host()
        historyContext = channel.historyContext; requestedResumePosition = channel.resumePosition
        // Zero is an explicit restart. It must never become a lookup of the previous history.
        pendingResume = channel.resumePosition.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        restoringPosition = false; restoredPosition = nil
        skipScope = channel.skipScope ?? channel.historyContext?.id ?? "direct:" + channel.id
        skipSettings = skipScope.map { EpisodeSkipSettings.load(scope: $0, defaults: skipDefaults) } ?? EpisodeSkipSettings()
        skipPass = EpisodeSkipPass(); seekingSegment = false
        savedDownload = channel.url.scheme == DownloadLibrary.scheme
        isLive = channel.playback?.isLive == true || MediaAddress.streamingSchemes.contains(channel.url.scheme?.lowercased() ?? "")
            || LiveCatalog.isRoom(channel.url) || channel.group == L10n.text("Bilibili Live") || MediaDanmakuRegistry.descriptor(for: channel.url)?.live != nil
        let source = channel.historyContext?.sourceKey
        if !DanmakuSource.has(channel.url), source != Bilibili.siteKey, source != CloudFiles.sourceKey { catalogDanmaku.startAutomatic(channel.historyContext) }
        ErrorReports.shared.playing(live: isLive, format: channel.playback?.format.isEmpty == false ? channel.playback!.format : channel.url.pathExtension,
                                    source: source, danmaku: catalogDanmaku.enabled, sharper: false)
    }
    private func open(_ prepared: Prepared, channel: Channel, selections: KSPlaybackSelections? = nil) {
        updateRuntimePlaybackPins(Set([channel.url, prepared.url, prepared.audioURL].compactMap { $0 }))
        error = nil; loading = true; showsPicture = false; buffering = false
        remoteSkip.begin(channel: channel, isLive: isLive)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { Diagnostics.shared.failure("player", "KS audio session", error) }
        let descriptor = channel.playback
        steps = ["正在连接视频", "等待第一帧画面"]
        Diagnostics.shared.record(.info, "player.startup", "stage=prepared elapsed=\(Date().timeIntervalSince(preparationStarted)) live=\(isLive) format=\(descriptor?.format ?? "")")
        engine.open(url: prepared.url, headers: prepared.headers, mediaID: generation.uuidString,
                    format: prepared.disc == nil ? descriptor?.format : "mpegts", isLive: isLive,
                    audioURL: prepared.audioURL, audioHeaders: prepared.audioHeaders,
                    cacheIOURL: prepared.cacheIOURL, audioCacheIOURL: prepared.audioCacheIOURL, selections: selections)
        if selections != nil { externalSubtitles.restoreAfterReopen(channel) }
        engine.speed = selectedSpeed
        if keepPausedAfterRestore { engine.pause() }
        if let disc = prepared.disc {
            engine.setDiscChapters(disc.chapters.enumerated().map { index, chapter in
                KSPlaybackChapter(id: index, title: chapter.title, start: chapter.time,
                                  end: index + 1 < disc.chapters.count ? disc.chapters[index + 1].time : disc.duration)
            })
        }
        ExternalDisplay.shared.refresh()
    }
    private func updateRuntimePlaybackPins(_ addresses: Set<URL>) {
        let addresses = Set(addresses.filter {
            ["127.0.0.1", "localhost", "::1", "[::1]"].contains($0.host?.lowercased() ?? "")
        })
        guard addresses != runtimePinnedURLs else { return }
        let removed = runtimePinnedURLs.subtracting(addresses)
        runtimePinnedURLs = addresses
        let previous = runtimePinTask
        runtimePinTask = Task {
            await previous?.value
            // Keep host commands ordered through rapid episode/core changes.
            // A delayed release of an old source cannot clear a newer owner.
            for url in removed {
                _ = await EmbeddedPythonHost.shared.setPlaybackPinned(url: url, pinned: false)
                _ = await EmbeddedNodeHost.shared.setPlaybackPinned(url, pinned: false)
            }
            // Multiple URLs may share one source proxy. Releasing its previous
            // address can release that source's owner, so reassert every desired
            // address after all removals rather than only newly added URLs.
            for url in addresses.sorted(by: { $0.absoluteString < $1.absoluteString }) {
                _ = await EmbeddedPythonHost.shared.setPlaybackPinned(url: url, pinned: true)
                _ = await EmbeddedNodeHost.shared.setPlaybackPinned(url, pinned: true)
            }
        }
    }
    private func ready() {
        guard recovery == nil else { return }
        buffering = false
        Diagnostics.shared.record(.info, "player.startup", "stage=ready elapsed=\(Date().timeIntervalSince(preparationStarted))")
        if let requested = pendingResume {
            let target = PlaybackHistoryEntry.resumeTarget(requested, duration: duration)
            pendingResume = nil
            guard let target else { loading = false; return }
            restoringPosition = true
            steps = ["正在恢复播放进度"]
            let active = generation
            engine.seek(to: target) { [weak self] success in
                guard let self, self.generation == active else { return }
                self.restoringPosition = false; self.loading = false
                if success { self.restoredPosition = self.position }
                else if !self.engine.seeking { self.error = L10n.text("The player could not restore the saved position. Try again.") }
                if self.editingSkip { self.engine.pause() }
                self.keepPausedAfterRestore = false
            }
        } else {
            loading = false
            if editingSkip { engine.pause() }
            keepPausedAfterRestore = false
        }
    }
    private func updateSubtitles() {
        subtitles.updateKS(lines: engine.subtitleLines, pictureSize: engine.presentationSize)
        subtitles.advance(to: engine.displayPosition)
        aiSubtitles.tick()
    }
    private func updatePictureState() {
        guard recovery == nil else { return }
        buffering = engine.buffering
        guard engine.isReady, !restoringPosition, pendingResume == nil else { return }
        loading = false
        if engine.hasPicture && !showsPicture {
            Diagnostics.shared.record(.info, "player.startup", "stage=first-picture elapsed=\(Date().timeIntervalSince(preparationStarted))")
            steps = []
        }
        showsPicture = engine.hasPicture
    }
    private func startSampler(generation active: UUID) {
        sampler?.cancel()
        transferTicker?.cancel()
        enhancementTicker?.cancel()
        transferTicker = Task { [weak self] in
            var rate = PlaybackTransferRate()
            var previousInput: UUID?, previousOrigin: Bool?
            var rateIdentity = UUID()
            while !Task.isCancelled {
                guard let self, self.generation == active else { return }
                let input = self.engine.inputRevision
                let owner = self.currentPrepared?.owner
                var bytes = self.engine.bytesRead, originStatistics = false
                if let owner, let statistics = try? await MobileMediaServices.videoCacheStatistics(owner), !statistics.nativeFallback {
                    bytes = statistics.networkBytes
                    originStatistics = true
                }
                guard !Task.isCancelled, self.generation == active, self.engine.inputRevision == input,
                      self.currentPrepared?.owner == owner else { return }
                if previousInput != input || previousOrigin != originStatistics {
                    rateIdentity = UUID(); previousInput = input; previousOrigin = originStatistics
                }
                self.transfer.bytesPerSecond = rate.sample(bytes: bytes, at: ProcessInfo.processInfo.systemUptime,
                    identity: rateIdentity)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Network-backed comments must never hold the picture/readiness sampler.
        enhancementTicker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == active else { return }
                await self.mediaEnhancements.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        sampler = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self, self.generation == active else { return }
                self.buffering = self.engine.buffering
                self.updatePictureState()
                if self.needsVideoCacheActivation { self.activateVideoCache() }
                let bytes = self.engine.bytesRead
                self.transfer.received = bytes
                self.transfer.required = self.engine.bitrate > 0 ? self.engine.bitrate / 8 : nil
                if var throttle = self.throttle, !self.paused {
                    throttle.update(ahead: max(0, self.engine.bufferedPosition - self.position), waiting: self.buffering)
                    self.throttle = throttle; self.applyBoost()
                }
                self.remoteSkip.tick(settings: self.skipSettings, duration: self.duration, chapters: self.engine.chapters,
                                     sessionID: self.mediaEnhancements.sessionID, ready: self.mediaEnhancements.serviceReady)
                self.updateSkipping()
                self.queueUpcomingIfDue()
                ticks += 1
                if ticks % 5 == 0 { self.saveHistory() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func updateSkipping() {
        guard !isLive, !editingSkip, !seekingSegment, !engine.seeking, pendingResume == nil, !restoringPosition, engine.isReady else { return }
        guard let action = remoteSkip.nextAction(time: position, duration: duration, playing: !paused && !buffering, enabled: skipSettings.enabled) else { return }
        seekingSegment = true
        let active = generation
        engine.seek(to: action.target) { [weak self] success in
            guard let self, self.generation == active else { return }
            self.seekingSegment = false
            self.remoteSkip.complete(action, succeeded: success)
        }
    }
    private func finished(_ failure: Error?) {
        guard recovery == nil else { return }
        if let failure {
            Diagnostics.shared.record(.warning, "player.recovery", "event=failure code=\(PlaybackFailureDiagnostics.codes(failure)) attempts=\(recoveryAttempts) decoderAttempts=\(decoderRecoveryAttempts) \(engine.failureDiagnostic)")
            if failure is KSPlaybackFailure {
                // First-open incompatibility needs another line/decoder. Only a
                // decoder that already presented this input may be rebuilt once.
                if engine.hasPresentedPicture, decoderRecoveryAttempts == 0,
                   recoverPlayback(reusePrepared: true) { decoderRecoveryAttempts += 1; return }
            } else if recoverPlayback() { return }
            engine.pause()
            error = failure.localizedDescription; loading = false; buffering = false
            Diagnostics.shared.record(.error, "player.recovery", "event=terminal code=\(PlaybackFailureDiagnostics.codes(failure)) \(engine.failureDiagnostic)")
            return
        }
        if looping { engine.seek(to: 0) { [weak self] ok in if ok { self?.engine.play() } }; return }
        saveHistory(completed: true)
        if playsOn(), playUpcoming() { return }
        onPlaybackEnded?()
    }
    func saveHistory(completed: Bool = false, item: AVPlayerItem? = nil) {
        guard let context = historyContext, engine.isReady, pendingResume == nil, !restoringPosition, !seekingSegment, !engine.seeking else { return }
        history.record(context, position: completed && duration > 0 ? duration : position, duration: duration)
    }
    func choose(quality: Int?) {
        guard let channel = playing, quality != self.quality else { return }
        let sourceURL = sourceChannel?.url ?? channel.url, requested = quality
        let savedPosition = position, wasPaused = paused
        cancelDiscSelection()
        recovery?.cancel(); recovery = nil
        preparation?.cancel(); discardUpcoming(); saveHistory()
        generation = UUID(); let active = generation
        preparation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == active { self.preparation = nil } }
            do {
                var next: Channel
                if let resolved = try await PlaybackQualityRegistry.resolve(for: sourceURL, quality: requested) {
                    next = Channel(name: channel.name, group: resolved.group, url: resolved.url, logo: channel.logo,
                                   headers: resolved.headers, skipScope: channel.skipScope, historyContext: channel.historyContext,
                                   resumePosition: savedPosition, subtitles: resolved.subtitles, playback: resolved.playback)
                } else if let url = requested.flatMap({ id in self.qualities.first { $0.id == id }?.url }) ?? self.automatic {
                    next = Channel(name: channel.name, group: channel.group, url: url, logo: channel.logo, headers: channel.headers,
                                   skipScope: channel.skipScope, historyContext: channel.historyContext, resumePosition: savedPosition,
                                   subtitles: channel.subtitles, playback: channel.playback)
                } else { return }
                if LiveCatalog.isRoom(next.url) { next = try await LiveCatalog.resolve(next).channel }
                let prepared = try await self.prepare(next)
                guard self.generation == active, !Task.isCancelled else { Self.release(next, prepared); return }
                if let previous = self.currentPrepared { Self.release(channel, previous) }
                self.pendingResume = savedPosition; self.restoringPosition = false; self.keepPausedAfterRestore = wasPaused
                self.currentPrepared = prepared; self.quality = requested; self.playing = next
                self.externalSubtitles.begin(next, playing: prepared.url)
                self.open(prepared, channel: next)
                self.startSampler(generation: active)
            } catch {
                guard self.generation == active, !Task.isCancelled else { return }
                self.switchNotice = error.localizedDescription
                self.startSampler(generation: active)
            }
        }
    }
    private func reopenCurrent() {
        guard let channel = playing, let prepared = currentPrepared else { return }
        cancelDiscSelection()
        recovery?.cancel(); recovery = nil
        preparation?.cancel(); preparation = nil
        saveHistory(); pendingResume = position; keepPausedAfterRestore = paused
        let selections = engine.selections
        externalSubtitles.prepareForReopen()
        generation = UUID()
        open(prepared, channel: channel, selections: selections); startSampler(generation: generation)
    }
    private func activateVideoCache() {
        if currentPrepared?.owner != nil { needsVideoCacheActivation = false; return }
        guard cachePreparation == nil, preparation == nil, recovery == nil, !isLive,
              !engine.pictureInPictureActive, !PictureInPicture.shared.busy, !engine.seeking, !restoringPosition,
              !selectingDiscTitle, let channel = playing, let original = currentPrepared,
              original.owner == nil, original.disc == nil, engine.mediaID != nil else { return }
        let active = generation, input = engine.inputRevision, identity = UUID()
        cachePreparationID = identity
        cachePreparation = Task { [weak self] in
            guard let self else { return }
            defer { if self.cachePreparationID == identity { self.cachePreparation = nil } }
            do {
                let prepared = try await self.prepare(channel)
                guard !Task.isCancelled, self.cachePreparationID == identity, self.generation == active,
                      self.playing?.id == channel.id, self.preparation == nil, self.recovery == nil,
                      self.engine.inputRevision == input, !self.engine.pictureInPictureActive, !PictureInPicture.shared.busy,
                      !self.engine.seeking, !self.restoringPosition else { Self.release(channel, prepared); return }
                guard prepared.owner != nil else {
                    self.needsVideoCacheActivation = false
                    Self.release(channel, prepared)
                    return
                }
                let selections = self.engine.selections
                // Reading and cache setup leave the active player running. Use
                // the latest transport state when the replacement is ready.
                self.pendingResume = self.pendingResume ?? self.position
                self.keepPausedAfterRestore = self.paused
                self.restoringPosition = false
                self.currentPrepared = prepared
                self.needsVideoCacheActivation = false
                self.externalSubtitles.prepareForReopen()
                self.generation = UUID()
                self.open(prepared, channel: channel, selections: selections)
                if self.keepPausedAfterRestore { self.engine.pause() }
                self.startSampler(generation: self.generation)
                Self.release(channel, original)
            } catch {
                guard !Task.isCancelled, self.cachePreparationID == identity, self.generation == active else { return }
                self.needsVideoCacheActivation = false
                self.switchNotice = error.localizedDescription
            }
        }
    }
    func selectDiscTitle(_ playlist: UInt32) {
        guard !selectingDiscTitle, let channel = playing, let previous = currentPrepared,
              let disc = previous.disc, disc.playlist != playlist,
              disc.titles.contains(where: { $0.playlist == playlist }), let backing = previous.backingURL else { return }
        cancelDiscSelection()
        recovery?.cancel(); recovery = nil
        generation = UUID()
        preparation?.cancel(); preparation = nil; discardUpcoming()
        startSampler(generation: generation)
        selectingDiscTitle = true
        let active = generation, selection = discSelectionID, wasPaused = paused
        discSelection = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.discSelectionID == selection { self.selectingDiscTitle = false; self.discSelection = nil }
            }
            do {
                let replacement = try await DiscPlayback.prepare(url: backing, headers: previous.backingHeaders, playlist: playlist)
                guard self.generation == active, self.discSelectionID == selection, !Task.isCancelled else { replacement.close(); return }
                self.engine.shutdown()
                previous.disc?.close()
                let prepared = Prepared(url: replacement.playbackURL, headers: [:], backingURL: backing,
                                        backingHeaders: previous.backingHeaders, disc: replacement)
                self.pendingResume = nil; self.restoringPosition = false; self.keepPausedAfterRestore = wasPaused
                self.currentPrepared = prepared; self.loading = true; self.showsPicture = false; self.error = nil
                var descriptor = channel.playback ?? PlaybackDescriptor(format: "iso")
                descriptor.discPlaylist = Int(playlist)
                self.playing = channel.withPlayback(descriptor)
                if let source = self.sourceChannel { self.sourceChannel = source.withPlayback(descriptor) }
                self.open(prepared, channel: channel)
                if wasPaused { self.engine.pause() }
            } catch {
                guard self.generation == active, self.discSelectionID == selection, !Task.isCancelled else { return }
                self.switchNotice = error.localizedDescription
            }
        }
    }
    private func cancelDiscSelection() {
        discSelectionID = UUID(); discSelection?.cancel(); discSelection = nil; selectingDiscTitle = false
    }
    func stop() {
        updateRuntimePlaybackPins([])
        needsVideoCacheActivation = false
        cachePreparationID = UUID(); cachePreparation?.cancel(); cachePreparation = nil
        cancelDiscSelection()
        saveHistory()
        generation = UUID()
        recovery?.cancel(); recovery = nil; recoveryAttempts = 0; decoderRecoveryAttempts = 0; lastRecovery = nil
        enhancementTicker?.cancel(); enhancementTicker = nil; selectingDiscTitle = false
        preparation?.cancel(); preparation = nil; sampler?.cancel(); sampler = nil
        transferTicker?.cancel(); transferTicker = nil
        discardUpcoming()
        if let playing, let currentPrepared { Self.release(playing, currentPrepared) }
        currentPrepared = nil; automatic = nil
        aiSubtitles.stop()
        remoteSkip.stop(); mediaEnhancements.stop(); externalSubtitles.stop(); subtitles.resetKS()
        engine.shutdown(); player.pause(); player.removeAllItems()
        catalogDanmaku.clear(); sourceDanmaku = []; chatGeneration = UUID(); chat?.stop(); chat = nil
        sourceDanmakuGeneration = UUID()
        sourceDanmakuLoading?.cancel(); sourceDanmakuLoading = nil; sourceDanmakuLoaded = false
        if playing != nil { ErrorReports.shared.stoppedPlaying() }
        playing = nil; sourceChannel = nil; activeChannelID = nil; historyContext = nil; pendingResume = nil
        requestedResumePosition = nil; restoredPosition = nil; restoringPosition = false; keepPausedAfterRestore = false; lockPaused = false
        skipScope = nil; skipPass = EpisodeSkipPass(); skipSettings = EpisodeSkipSettings()
        editingSkip = false; resumeAfterEditing = false; seekingSegment = false
        transfer = Transfer(); steps = []; switchNotice = nil; orientationPolicy = PlaybackOrientationPolicy()
        qualities = []; quality = nil; showsPicture = false; buffering = false; loading = true
        onPlaybackEnded = nil; onUnplayableFile = nil; upcomingEpisode = nil; onAdvance = nil; playsOn = { false }
        clearBoost(); healthyPrefetchSince = nil; upcomingAttempted = false; advancing = false
    }
    /// The device is locking (protected data going away). Video pauses and does
    /// not resume by itself when the device unlocks — the user presses play
    /// (upstream build03 behaviour). A video caught buffering or mid-scrub also
    /// drops its pending resume, so nothing queued can restart it later.
    /// Audio-only playback is not paused: music and audiobooks run in their own
    /// player, and this session's picture-off listening (video track "no")
    /// keeps playing too.
    private func handleDeviceLock() {
        guard engine.mediaID != nil, engine.selections.video != "no" else { return }
        lockPaused = true
        if buffering || engine.seeking {
            pendingResume = nil
            keepPausedAfterRestore = true
        }
        if !paused { engine.pause() }
    }
    private func recoverAfterForeground() {
        guard let prepared = currentPrepared, engine.mediaID != nil else { return }
        // The cache, HLS proxy and disc reader intentionally use loopback URLs.
        // Returning from PiP changes the surface; it does not invalidate any of those readers.
        engine.resumeAfterForeground()
        if lockPaused {
            // Locked while playing: whatever the core did in the background,
            // the video stays paused until the user presses play.
            lockPaused = false
            engine.pause()
            return
        }
        guard !paused else { return }
        if prepared.disc?.isAvailable == false || error != nil { _ = recoverPlayback() }
    }
    @discardableResult private func recoverPlayback(reusePrepared: Bool = false) -> Bool {
        guard recovery == nil, recoveryAttempts < 2, !selectingDiscTitle,
              preparation == nil || engine.mediaID == generation.uuidString,
              let selected = playing ?? sourceChannel else { return false }
        let source: Channel
        if !reusePrepared, let room = sourceChannel, LiveCatalog.isRoom(room.url) { source = room }
        else { source = selected }
        if reusePrepared, currentPrepared == nil { return false }
        if let lastRecovery, Date().timeIntervalSince(lastRecovery) < 2 { return false }
        saveHistory()
        cancelDiscSelection()
        preparation?.cancel(); preparation = nil; discardUpcoming()
        recoveryAttempts += 1; lastRecovery = Date()
        Diagnostics.shared.record(.info, "player.recovery", "event=begin reuseInput=\(reusePrepared) attempt=\(recoveryAttempts) \(engine.failureDiagnostic)")
        let savedPosition = pendingResume ?? position, savedTimeline = engine.timelineRevision
        generation = UUID(); let active = generation
        restoringPosition = false; seekingSegment = false; pendingResume = nil
        preparationStarted = Date()
        error = nil; loading = true; buffering = false
        steps = [reusePrepared ? "正在恢复视频解码" : "正在重新解析播放地址"]
        recovery = Task { [weak self] in
            guard let self, self.generation == active, !Task.isCancelled else { return }
            do {
                let channel = !reusePrepared && LiveCatalog.isRoom(source.url) ? try await LiveCatalog.resolve(source).0 : source
                let prepared: Prepared
                if reusePrepared, let current = self.currentPrepared { prepared = current }
                else { prepared = try await self.prepare(channel) }
                guard self.generation == active, !Task.isCancelled else {
                    if !reusePrepared { Self.release(channel, prepared) }
                    return
                }
                // Take the latest intent: pause/seek can be used while network
                // preparation runs. Shutdown callbacks belong to the old epoch.
                let wasPaused = self.paused
                let resume = self.engine.seeking || self.engine.timelineRevision != savedTimeline ? self.position : savedPosition
                let selections = self.engine.selections
                self.externalSubtitles.prepareForReopen()
                self.engine.shutdown()
                if !reusePrepared, let previous = self.currentPrepared { Self.release(source, previous) }
                self.currentPrepared = prepared; self.playing = channel
                self.pendingResume = self.isLive ? nil : resume; self.keepPausedAfterRestore = wasPaused
                self.recovery = nil
                self.open(prepared, channel: channel, selections: selections)
                self.startSampler(generation: active)
                Diagnostics.shared.record(.info, "player.recovery", "event=reopened attempt=\(self.recoveryAttempts) resume=\(self.pendingResume ?? 0) paused=\(wasPaused)")
            } catch {
                guard self.generation == active, !Task.isCancelled else { return }
                self.engine.pause()
                self.error = error.localizedDescription; self.loading = false; self.buffering = false
                Diagnostics.shared.record(.error, "player.recovery", "event=prepare-failed code=\(PlaybackFailureDiagnostics.codes(error)) attempt=\(self.recoveryAttempts)")
            }
            if self.generation == active { self.recovery = nil }
        }
        return true
    }
    private func listen(room: Int) {
        chat?.stop()
        chatGeneration = UUID()
        let activeChat = chatGeneration
        let chat = BilibiliLiveChat(room: room); self.chat = chat
        chat.start { [weak self] text, color, position in
            Task { @MainActor [weak self] in
                guard let self, self.chatGeneration == activeChat else { return }
                self.sourceDanmaku.append(Danmaku(time: max(self.position + 0.2, self.sourceDanmaku.last?.time ?? 0), position: position, color: color, text: text))
                if self.sourceDanmaku.count > 4000 { self.sourceDanmaku.removeFirst(1000) }
            }
        }
    }
    private struct Prepared {
        var url: URL
        var headers: [String: String]
        var owner: String?
        var backingURL: URL?
        var backingHeaders: [String: String] = [:]
        var disc: DiscPlaybackResource?
        var audioURL: URL?
        var audioHeaders: [String: String] = [:]
        var cacheIOURL: URL?
        var audioCacheIOURL: URL?
    }
    private func prepare(_ channel: Channel) async throws -> Prepared {
        var address = channel.url
        var headers = channel.headers
        try Task.checkCancellation()
        // A source's HTTP URL is already a native FFmpeg input. Only relocate
        // a suspended local server; keep its path, selected quality and query.
        if address.scheme == "http", ["127.0.0.1", "localhost"].contains(address.host ?? ""),
           let relocated = await EmbeddedNodeHost.shared.relocate(address) { address = relocated }
        if CloudFiles.isFile(address) { address = try await CloudFiles.prepare(address) }
        if let source = await CloudStreams.source(for: address) {
            address = source.url; headers.merge(source.headers) { _, value in value }
        }
        try Task.checkCancellation()
        if address.scheme == DownloadLibrary.scheme {
            address = try await DownloadLibrary.shared.playbackAddress(for: address, preserveContainer: true) { _ in }
        }
        if address.scheme == HongguoStreams.scheme {
            address = try await HongguoStreams.playbackURL(for: address)
        }
        if let upstream = LiveRepair.upstream(address) {
            headers.merge(LiveRepair.headers(for: address)) { _, value in value }; address = upstream
        }
        if DiscPlayback.canHandle(url: address, format: channel.playback?.format) {
            let playlist = channel.playback?.discPlaylist.flatMap { $0 >= 0 && $0 <= Int(UInt32.max) ? UInt32($0) : nil }
            let disc = try await DiscPlayback.prepare(url: address, headers: headers, playlist: playlist)
            do { try Task.checkCancellation() }
            catch { disc.close(); throw error }
            return Prepared(url: disc.playbackURL, headers: [:], backingURL: address, backingHeaders: headers, disc: disc)
        }
        var descriptor = channel.playback
        if let audio = descriptor?.audioURL, audio.scheme == "http", ["127.0.0.1", "localhost"].contains(audio.host ?? ""),
           let relocated = await EmbeddedNodeHost.shared.relocate(audio) { descriptor?.audioURL = relocated }
        let next = Channel(name: channel.name, group: channel.group, url: address, logo: channel.logo, headers: headers,
                           skipScope: channel.skipScope, historyContext: channel.historyContext, resumePosition: channel.resumePosition,
                           subtitles: channel.subtitles, playback: descriptor)
        let prepared = try await MobileMediaServices.preparePlayable(next,
            cacheEnabled: UserDefaults.standard.object(forKey: "local.videoCache.enabled") as? Bool ?? true,
            sizeGB: max(1, min(4, UserDefaults.standard.integer(forKey: "local.videoCache.sizeGB"))),
            adClean: UserDefaults.standard.object(forKey: "local.hlsAdClean") as? Bool ?? true, isLive: isLive)
        return Prepared(url: prepared.url, headers: prepared.headers, owner: prepared.ownerID, backingURL: address,
                        audioURL: prepared.audioURL, audioHeaders: prepared.audioHeaders,
                        cacheIOURL: prepared.cacheIOURL, audioCacheIOURL: prepared.audioCacheIOURL)
    }
    private static func release(_ channel: Channel, _ prepared: Prepared) {
        if let owner = prepared.owner { Task { _ = try? await MobileMediaServices.call("playback.release", ["id": .string(owner)]) } }
        prepared.disc?.close()
        HongguoStreams.stop(channel.url)
        CloudStreams.stop(prepared.backingURL ?? prepared.url)
    }
    private func queueUpcomingIfDue() {
        let enabled = UserDefaults.standard.object(forKey: "local.playback.prefetchNext") as? Bool ?? true
        let ahead = max(0, engine.bufferedPosition - position)
        let healthy = NextMediaPolicy.mayPrepare(enabled: enabled, paused: paused, buffering: buffering,
            seeking: engine.seeking || restoringPosition || seekingSegment, bufferedSeconds: ahead, speed: Double(engine.speed))
        guard healthy else {
            healthyPrefetchSince = nil
            prefetchWarmID = UUID(); prefetchWarm?.cancel(); prefetchWarm = nil
            return
        }
        if healthyPrefetchSince == nil { healthyPrefetchSince = Date() }
        if upcoming != nil { warmUpcomingIfSafe(); return }
        // Arm as soon as playback is healthy, not in the last seconds of the
        // episode: the next episode is resolved, prepared and head-warmed while
        // this one plays, so a manual switch can reuse it like an automatic one.
        guard Date().timeIntervalSince(healthyPrefetchSince!) >= 3, !upcomingAttempted, !looping, !isLive,
              duration > 0, let upcomingEpisode else { return }
        upcomingAttempted = true; let active = generation
        upcomingTask = Task { [weak self] in
            guard let next = await upcomingEpisode(), let self, self.generation == active, !Task.isCancelled else { return }
            do {
                let prepared = try await self.prepare(next)
                guard self.generation == active, !Task.isCancelled else { Self.release(next, prepared); return }
                self.upcoming = (next, prepared); self.prefetchComplete = false; self.warmUpcomingIfSafe()
            } catch { Diagnostics.shared.record(.warning, "player", "KS next preparation: \(error.localizedDescription)") }
        }
    }
    private func warmUpcomingIfSafe() {
        let healthy = NextMediaPolicy.mayPrepare(enabled: UserDefaults.standard.object(forKey: "local.playback.prefetchNext") as? Bool ?? true,
            paused: paused, buffering: buffering, seeking: engine.seeking || restoringPosition || seekingSegment,
            bufferedSeconds: max(0, engine.bufferedPosition - position), speed: Double(engine.speed))
        guard healthy, let since = healthyPrefetchSince, Date().timeIntervalSince(since) >= 3 else { return }
        guard !prefetchComplete, prefetchWarm == nil, let owner = upcoming?.1.owner else { return }
        let active = generation, warmID = UUID()
        prefetchWarmID = warmID
        prefetchWarm = Task { [weak self] in
            do {
                try await MobileMediaServices.prefetchPlayback(owner)
                guard let self, self.generation == active, self.prefetchWarmID == warmID, !Task.isCancelled else { return }
                self.prefetchComplete = true
            } catch {}
            if let self, self.generation == active, self.prefetchWarmID == warmID { self.prefetchWarm = nil }
        }
    }
    private func discardUpcoming() {
        prefetchWarmID = UUID(); prefetchWarm?.cancel(); prefetchWarm = nil; prefetchComplete = false
        upcomingTask?.cancel(); upcomingTask = nil
        if let (channel, prepared) = upcoming { Self.release(channel, prepared) }; upcoming = nil
    }
    /// True when `channel` is the prepared upcoming episode (same video, episode
    /// and line; the freshly resolved copy need not be the same object or URL)
    /// and it has been taken over for playback.
    private func consumeUpcoming(for channel: Channel) -> Bool {
        guard let (next, _) = upcoming else { return false }
        if next == channel { return playUpcoming() }
        guard let wanted = channel.historyContext, let prepared = next.historyContext,
              wanted.id == prepared.id, wanted.episodeID == prepared.episodeID,
              wanted.episodeFlag == prepared.episodeFlag else { return false }
        return playUpcoming()
    }
    func playUpcoming() -> Bool {
        guard let (channel, prepared) = upcoming, !advancing else { return false }
        advancing = true; upcoming = nil
        let advance = onAdvance, end = onPlaybackEnded, resolve = upcomingEpisode, shouldPlay = playsOn
        saveHistory()
        stop(); begin(channel); sourceChannel = channel
        onAdvance = advance; onPlaybackEnded = end; upcomingEpisode = resolve; playsOn = shouldPlay
        playing = channel; currentPrepared = prepared; automatic = prepared.url; activeChannelID = channel.id
        open(prepared, channel: channel)
        externalSubtitles.begin(channel, playing: prepared.url)
        mediaEnhancements.begin(channel: channel, sessionID: generation.uuidString.lowercased(), engine: engine)
        startSampler(generation: generation)
        onAdvance?(channel)
        advancing = false
        return true
    }
    var loadingProgress: LoadingProgress {
        var progress = LoadingProgress(title: L10n.text(loading ? "Connecting…" : "Buffering…"))
        progress.steps = steps
        if let switchNotice { progress.reason = switchNotice }
        else if let failure = transfer.failure { progress.reason = failure }
        if let speed = transfer.bytesPerSecond { progress.detail = L10n.text("Downloading at %@", Self.rate(speed)) }
        return progress
    }
    func wait(elapsed: TimeInterval, resume: Double?, linesHint: Bool) -> PlaybackWait {
        var result = PlaybackWait(message: loading ? Self.preparing(resume) : L10n.text("Buffering…"), caption: switchNotice,
                                  suggestsLines: linesHint && elapsed >= LoadingCard.patience)
        if elapsed >= PlaybackWait.detailsAfter { result.detail = loadingProgress.detail; result.steps = steps }
        return result
    }
    static func server(_ host: String?) -> String {
        guard let host, !host.isEmpty, !["127.0.0.1", "localhost"].contains(host) else { return L10n.text("the video server") }; return host
    }
    private static func rate(_ value: Double) -> String {
        L10n.text("%@/s", ByteCountFormatter.string(fromByteCount: Int64(value.isFinite ? min(1e15, max(0, value)) : 0), countStyle: .file))
    }
    static func preparing(_ resume: Double?) -> String {
        guard let resume, resume.isFinite, resume >= 5 else { return L10n.text("Getting it ready") }
        return L10n.text("Getting it ready · from %@", Duration.seconds(Int(resume)).formatted(.time(pattern: resume >= 3600 ? .hourMinuteSecond : .minuteSecond)))
    }
}
#endif
