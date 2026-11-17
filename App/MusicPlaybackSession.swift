import AVFoundation
import SwiftUI
import Perception
import TVCore

/// AVFoundation brings AudioToolbox's `MusicTrack` (a sequencer track) into scope too; in this app the name means the song.
typealias MusicTrack = TVCore.MusicTrack

/// Plays a queue of songs, apart from the video player and its history, skipping and danmaku.
/// Each song's channel comes from `MusicResolver`; when playback fails the channel is resolved
/// once more, then another is tried, continuing at the same second only on a stream of the same
/// length. A song no channel can play is skipped, until several in a row fail. Songs that play go
/// into the history, and where listening is gets saved, to continue later.
/// A new song, or Stop, cancels everything for the old one, so a late answer never plays.
@MainActor @Perceptible final class MusicPlaybackSession {
    enum Phase: Equatable {
        case idle
        /// Finding a channel.
        case resolving
        /// A stream is set; waiting for sound.
        case loading
        case playing
        case paused
        case failed(String)
    }

    private(set) var queue: MusicQueue?
    var track: MusicTrack? { queue?.current }
    private(set) var selection: MusicPlaybackSelection?
    private(set) var phase: Phase = .idle
    /// Every channel tried for this song, with how it went.
    private(set) var attempts: [MusicAttempt] = []
    /// Diagnostics for the last failure; never holds addresses.
    private(set) var failureDetail: String?
    /// A song that was skipped, and why; cleared when the next one plays.
    private(set) var notice: String?
    private(set) var position: Double = 0
    private(set) var duration: Double?
    /// Where a seek in flight is going: until it lands, the clock still reports the old time, and
    /// showing that made the slider jump back and forth.
    private(set) var seekingTo: Double?
    /// Explicit timeline changes also recenter lyrics when the active line did not change.
    private(set) var timelineRevision = UUID()
    private(set) var lyrics: MusicLyrics?
    private(set) var lyricsLoading = false
    /// tvOS shows playback full screen, where the remote reaches every control; set when a song
    /// starts, and by Now Playing.
    var presentsPlayer = false
    /// What the Mac's Now Playing shows beside the cover.
    var nowPlayingPanel: MusicNowPlayingPanel = .lyrics
    /// Off, the whole queue again, or the one song again; remembered across launches.
    private(set) var repeatMode = MusicRepeatMode(rawValue: UserDefaults.standard.string(forKey: "musicRepeat") ?? "") ?? .off
    private(set) var playbackMode: MusicPlaybackMode
    private let modeDefaults: UserDefaults
    /// The songs after this one play in random order; turning it off puts the queue back as it came.
    private(set) var shuffled = false
    private var unshuffled: [MusicTrack]?
    /// The player's own volume, under the system's; remembered across launches.
    var volume: Double = UserDefaults.standard.object(forKey: "musicVolume") == nil ? 1 : UserDefaults.standard.double(forKey: "musicVolume") {
        didSet { player.volume = Float(volume); UserDefaults.standard.set(volume, forKey: "musicVolume") }
    }
    var preferences = MusicPreferences.load() {
        didSet {
            if preferences != oldValue { preferences.save(); refreshPreparation() }
        }
    }
    let library: MusicLibrary

    let player = AVQueuePlayer()
    private var wantsPlayback = true
    private var pendingFailureSkip: UUID?
    private var preparationTask: Task<Void, Never>?
    private var preparationID = UUID()
    private var prepared: PreparedNext?
    private var currentItemObservation: NSKeyValueObservation?
    private struct PreparedNext {
        let origin: UUID
        let queue: MusicQueue
        let selection: MusicPlaybackSelection
        let item: AVPlayerItem
    }
    private var generation = UUID()
    private var seekRevision = UUID()
    private var task: Task<Void, Never>?
    private var startWatch: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var cache = MusicStreamCache()
    private var recovery = MusicRecovery()
    private var retriedLXSourceIDs: Set<String> = []
    private var failedLXSourceIDs: Set<String> = []
    private var itemObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var consecutiveFailures = 0
    /// When the song was asked for, and when its current stream was set, for the time-to-sound log.
    private var requestedAt = Date()
    private var streamSetAt: Date?
    private var recordedPlay = false
    private var lyricsFor: String?
    private var lastSavedPosition: Double = -10
    /// AVPlayer gets this long from a stream being set to sound playing before the stream counts as failed.
    static let startWindow: Duration = .seconds(10)

    // MARK: TVBox episodes (#289)

    /// Turns a TVBox episode into its stream through its source; set by the store, which has the subscriptions.
    @PerceptionIgnored var resolveSource: ((MusicSourceEpisode) async throws -> Channel)?
    /// Opens a TVBox episode in the video player at a second: its stream has a picture (`true`), or this player
    /// can't play it and the video player, with more ways to play, might. The last is whether Now Playing was open.
    @PerceptionIgnored var handOffSource: ((Channel, Double, Bool, Bool) -> Void)?
    /// Saves where a TVBox episode is under its book, as the video player saves a series.
    @PerceptionIgnored var recordSource: ((MusicSourceEpisode, Double, Double) -> Void)?
    /// The stream of the TVBox episode playing.
    private(set) var sourceStream: Channel?
    /// The first episode's stream, which the page that started the queue already resolved.
    private var givenStream: (track: String, channel: Channel)?
    private var pictureObservation: NSKeyValueObservation?

    init(library: MusicLibrary = .shared, defaults: UserDefaults = .standard) {
        self.library = library
        modeDefaults = defaults
        playbackMode = MusicPlaybackMode.load(defaults)
        #if os(iOS)
        repeatMode = playbackMode == .repeatOne ? .one : playbackMode == .random ? .all : .off
        shuffled = playbackMode == .random
        #endif
        player.volume = Float(volume)
        player.actionAtItemEnd = .pause
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.adoptPreparedIfAdvanced() }
        }
        // AirPlay gets the sound this player makes, not the stream's address. Allowed to, AVPlayer hands the address
        // to a receiver that can play video, and an Android TV box's AirPlay app then plays the FLAC itself: with
        // static on some songs, or not at all (-11870, "external playback not supported for asset") (#376).
        player.allowsExternalPlayback = false
    }

    var busy: Bool { phase == .resolving || phase == .loading }
    /// A stream is set: a music channel's, or a TVBox episode's.
    var hasStream: Bool { selection != nil || sourceStream != nil }
    var canSeek: Bool { player.currentItem != nil && (phase == .playing || phase == .paused || phase == .loading) }
    var isPlaying: Bool { phase == .playing || phase == .loading && player.rate > 0 }
    var failure: String? { if case .failed(let message) = phase { message } else { nil } }
    /// Seconds the lyrics run ahead of the audio for this song, set by the viewer: positive shows
    /// lines earlier. Covers lyrics timed a little off and slow outputs such as Bluetooth.
    private(set) var lyricsOffset: Double = 0
    var currentLyric: Int? { lyrics?.index(at: (seekingTo ?? position) + lyricsOffset) }
    private static let offsetsKey = "musicLyricsOffsets"

    func adjustLyrics(by seconds: Double) {
        setLyricsOffset(((lyricsOffset + seconds) * 10).rounded() / 10)
    }

    func resetLyricsOffset() { setLyricsOffset(0) }

    /// Plays from a lyric line, where it is heard with the offset.
    func seek(toLyric line: MusicLyricLine) { seek(to: max(0, line.time - lyricsOffset)) }

    private func setLyricsOffset(_ value: Double) {
        lyricsOffset = max(-10, min(10, value))
        guard let id = track?.id else { return }
        var offsets = UserDefaults.standard.dictionary(forKey: Self.offsetsKey) as? [String: Double] ?? [:]
        offsets[id] = lyricsOffset == 0 ? nil : lyricsOffset
        UserDefaults.standard.set(offsets, forKey: Self.offsetsKey)
    }

    private func savedLyricsOffset(for id: String) -> Double {
        (UserDefaults.standard.dictionary(forKey: Self.offsetsKey) as? [String: Double])?[id] ?? 0
    }

    /// The channels the viewer can switch to: those that played or were not tried.
    var alternatives: [MusicCandidate] {
        let playable = attempts.compactMap { attempt -> MusicCandidate? in
            if case .playable = attempt.outcome, attempt.candidate != selection?.candidate { return attempt.candidate }
            return nil
        }
        let skipped = attempts.compactMap { attempt -> MusicCandidate? in
            if case .skipped = attempt.outcome { return attempt.candidate }
            return nil
        }
        return playable + (selection?.untried ?? []).filter { !playable.contains($0) } + skipped.filter { !playable.contains($0) }
    }

    // MARK: - Viewer actions

    /// Plays one song on its own.
    func play(_ track: MusicTrack) { play(MusicQueue(tracks: [track])) }

    /// Plays a queue from its current song, at `position` when continuing.
    func play(_ queue: MusicQueue, at position: Double? = nil, stream: Channel? = nil, restoring: Bool = false) {
        guard let current = queue.current else { return }
        givenStream = stream.map { (current.id, $0) }
        #if os(iOS)
        let domain: MusicPlaybackMode.Domain = current.source == nil ? .music : .listening
        playbackMode = MusicPlaybackMode.load(modeDefaults, domain: domain)
        if queue.isShuffled && !restoring {
            // A playlist's explicit Shuffle action chooses random mode; resuming uses the saved preference.
            playbackMode = .random
            playbackMode.save(modeDefaults, domain: domain)
        }
        repeatMode = playbackMode == .repeatOne ? .one : playbackMode == .random ? .all : .off
        modeDefaults.set(repeatMode.rawValue, forKey: domain.repeatKey)
        var ordered = queue
        ordered.setDomainShuffled(playbackMode == .random)
        self.queue = ordered
        shuffled = playbackMode == .random
        #else
        self.queue = queue
        shuffled = false; unshuffled = nil
        #endif
        consecutiveFailures = 0
        loadCurrent(at: position)
        #if os(tvOS)
        presentsPlayer = true
        #endif
    }

    /// Continues where listening stopped, even after the app was closed.
    func resume() {
        guard let point = library.resumePoint else { return }
        play(point.queue, at: point.position, restoring: true)
    }

    /// The next song, or the first again when the whole queue repeats.
    func next() {
        adoptPreparedIfAdvanced()
        if let prepared, prepared.origin == generation, preparationIsFresh(prepared), player.items().contains(where: { $0 === prepared.item }) {
            wantsPlayback = true
            player.advanceToNextItem()
            adoptPreparedIfAdvanced()
            player.play()
            return
        }
        guard var queue else { return }
        if queue.advance() == nil {
            guard repeatMode == .all, queue.repeatingTrackCount > 1 else { return }
            if shuffled && queue.isShuffled {
                guard queue.restartShuffledPass() != nil else { return }
            } else {
                guard queue.jump(to: 0) != nil else { return }
            }
        }
        self.queue = queue
        synchronizePlaybackMode()
        loadCurrent(at: nil)
    }

    var canAdvance: Bool { queue?.hasNext == true || repeatMode == .all && (queue?.repeatingTrackCount ?? 0) > 1 }

    func cyclePlaybackMode() { setPlaybackMode(playbackMode.next) }

    /// Reorders only the queue: the AVPlayer item, seek and transport state keep running untouched.
    func setPlaybackMode(_ mode: MusicPlaybackMode) {
        adoptPreparedIfAdvanced()
        playbackMode = mode
        repeatMode = mode == .repeatOne ? .one : mode == .random ? .all : .off
        shuffled = mode == .random
        queue?.setDomainShuffled(shuffled)
        unshuffled = nil
        let domain: MusicPlaybackMode.Domain = queue?.current?.source == nil ? .music : .listening
        mode.save(modeDefaults, domain: domain)
        modeDefaults.set(repeatMode.rawValue, forKey: domain.repeatKey)
        saveResumePoint(force: true)
        library.flush()
        refreshPreparation()
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        let domain: MusicPlaybackMode.Domain = queue?.current?.source == nil ? .music : .listening
        modeDefaults.set(repeatMode.rawValue, forKey: domain.repeatKey)
        refreshPreparation()
    }

    /// A manually mixed queue can cross domains through Next, Previous, Jump or natural EOF.
    /// Restore that segment's saved mode without moving any surrounding book chapters.
    private func synchronizePlaybackMode() {
        #if os(iOS)
        guard let current = queue?.current else { return }
        let domain: MusicPlaybackMode.Domain = current.source == nil ? .music : .listening
        let mode = MusicPlaybackMode.load(modeDefaults, domain: domain)
        playbackMode = mode
        repeatMode = mode == .repeatOne ? .one : mode == .random ? .all : .off
        shuffled = mode == .random
        queue?.continueDomainShuffled(shuffled)
        #endif
    }

    /// Shuffles the songs after this one, or puts them back in their order.
    func toggleShuffle() {
        #if os(iOS)
        setPlaybackMode(shuffled ? .sequential : .random)
        #else
        guard let queue, let current = queue.current else { return }
        if shuffled, let original = unshuffled {
            self.queue = MusicQueue(tracks: original, start: original.firstIndex(of: current) ?? 0, source: queue.source, collection: queue.collection)
            unshuffled = nil
        } else {
            unshuffled = queue.tracks
            let upcoming = queue.tracks[(queue.index + 1)...].shuffled()
            self.queue = MusicQueue(tracks: Array(queue.tracks[...queue.index]) + upcoming, start: queue.index, source: queue.source, collection: queue.collection)
        }
        shuffled.toggle()
        #endif
    }

    /// Plays `tracks` after this song; with nothing playing, plays them now.
    func playNext(_ tracks: [MusicTrack]) {
        adoptPreparedIfAdvanced()
        guard !tracks.isEmpty else { return }
        guard var queue else { play(MusicQueue(tracks: tracks)); return }
        // A cross-domain insertion has an explicit next position. Keep the
        // visible pass, including every pending occurrence, as its baseline.
        if let current = queue.current, tracks.contains(where: { ($0.source != nil) != (current.source != nil) }) {
            queue.preservePlaybackOrder()
        }
        queue.insertNext(tracks)
        self.queue = queue
        unshuffled?.append(contentsOf: tracks)
        refreshPreparation()
    }

    /// Plays `tracks` after everything already queued; with nothing playing, plays them now.
    func addToUpNext(_ tracks: [MusicTrack]) {
        adoptPreparedIfAdvanced()
        guard !tracks.isEmpty else { return }
        guard var queue else { play(MusicQueue(tracks: tracks)); return }
        if let current = queue.current, tracks.contains(where: { ($0.source != nil) != (current.source != nil) }) {
            queue.preservePlaybackOrder()
        }
        queue.append(tracks)
        self.queue = queue
        unshuffled?.append(contentsOf: tracks)
        refreshPreparation()
    }

    /// Back to the start of the song once a few seconds played, otherwise to the song before.
    func previous() {
        adoptPreparedIfAdvanced()
        if currentSeconds > MusicQueue.restartThreshold || queue?.hasPrevious != true { seek(to: 0); return }
        guard var queue, queue.back() != nil else { return }
        self.queue = queue
        synchronizePlaybackMode()
        loadCurrent(at: nil)
    }

    func jump(to index: Int) {
        adoptPreparedIfAdvanced()
        guard var queue, queue.jump(to: index) != nil else { return }
        self.queue = queue
        synchronizePlaybackMode()
        consecutiveFailures = 0
        loadCurrent(at: nil)
    }

    /// Plays a channel the viewer picked, at the same second when it is the same recording.
    func choose(_ candidate: MusicCandidate) {
        adoptPreparedIfAdvanced()
        guard let track else { return }
        let previous = selection?.probe, at = currentSeconds
        let run = UUID(); generation = run
        task?.cancel(); startWatch?.cancel()
        tearDownItem()
        position = at
        phase = .resolving
        let resolver = MusicResolver(preferences: preferences), preference = preferences.quality, cache = cache
        task = Task {
            do {
                var chosen = try await resolver.refresh(candidate, track: track, preference: preference, cache: cache)
                guard self.generation == run else { return }
                chosen.untried = self.alternatives.filter { $0 != candidate }
                self.record(chosen.attempts)
                self.start(chosen, at: previous.flatMap { MusicRecovery.canResume(from: $0, to: chosen.probe) ? at : nil }, run: run)
            } catch {
                guard self.generation == run else { return }
                let failure = MusicProviderError(error)
                self.record([MusicAttempt(candidate: candidate, outcome: .failed(failure), seconds: 0)])
                self.fail(failure)
            }
        }
    }

    func retry() {
        adoptPreparedIfAdvanced()
        consecutiveFailures = 0
        loadCurrent(at: currentSeconds > 1 ? currentSeconds : nil)
    }

    func toggle() {
        adoptPreparedIfAdvanced()
        switch phase {
        case .playing, .loading: pause()
        case .paused:
            wantsPlayback = true
            if player.currentItem != nil { activateAudioSession(); player.play(); phase = .loading }
            else if pendingFailureSkip == generation {
                pendingFailureSkip = nil
                next()
            } else { phase = .resolving }
        case .failed: retry()
        case .idle, .resolving: break
        }
    }

    func pause() {
        adoptPreparedIfAdvanced()
        guard phase == .playing || phase == .loading || phase == .resolving else { return }
        wantsPlayback = false
        cancelPreparation()
        player.pause(); phase = .paused
        saveResumePoint(force: true)
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, canSeek, let item = player.currentItem else { return }
        let target = max(0, min(seconds, (duration ?? seconds) - 0.5))
        let previous = currentSeconds
        let run = generation, seek = UUID()
        seekRevision = seek
        position = target; seekingTo = target
        timelineRevision = UUID()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] finished in
            Task { @MainActor [weak self, weak item] in
                // Repeated targets still represent different seeks. A canceled completion
                // belongs to its original item and must never release a later seek's clock.
                guard let self, let item, self.generation == run,
                      self.player.currentItem === item, self.seekRevision == seek else { return }
                let actual = item.currentTime().seconds
                self.position = actual.isFinite ? max(0, actual) : finished ? target : previous
                self.seekingTo = nil
            }
        }
    }

    func skip(by seconds: Double) { seek(to: currentSeconds + seconds) }

    /// Whether the mini player or the Mac's bar shows: while a song is loaded, and never over a video, which
    /// has its own controls. The bar comes back when the video closes.
    func showsStrip(videoPlaying: Bool) -> Bool { track != nil && !videoPlaying }

    /// Stops and hides the player. Where listening was stays saved, to continue from the Music page.
    func stop() {
        adoptPreparedIfAdvanced()
        wantsPlayback = false
        pendingFailureSkip = nil
        saveResumePoint(force: true)
        generation = UUID()
        task?.cancel(); startWatch?.cancel(); lyricsTask?.cancel()
        tearDownItem()
        queue = nil; selection = nil; attempts = []; phase = .idle; failureDetail = nil; notice = nil; presentsPlayer = false
        sourceStream = nil; givenStream = nil
        position = 0; duration = nil; seekingTo = nil; lyrics = nil; lyricsFor = nil
        library.flush()
    }

    // MARK: - Playback

    private var currentSeconds: Double {
        if let seekingTo { return seekingTo }
        let seconds = player.currentItem?.currentTime().seconds ?? .nan
        return seconds.isFinite ? seconds : position
    }

    /// Finds a channel for the queue's current song and plays it.
    private func loadCurrent(at resumeAt: Double?) {
        guard let track else { return }
        let run = UUID(); generation = run
        wantsPlayback = true
        pendingFailureSkip = nil
        task?.cancel(); startWatch?.cancel(); lyricsTask?.cancel()
        tearDownItem()
        selection = nil; attempts = []; failureDetail = nil; sourceStream = nil
        position = resumeAt ?? 0; duration = track.duration; seekingTo = nil
        lyrics = nil; lyricsLoading = false; lyricsFor = nil; recordedPlay = false
        lyricsOffset = savedLyricsOffset(for: track.id)
        cache = MusicStreamCache(); recovery = MusicRecovery()
        retriedLXSourceIDs = []; failedLXSourceIDs = []
        requestedAt = Date()
        phase = .resolving
        if let source = track.source { loadSource(source, track: track, at: resumeAt, run: run); return }
        let resolver = MusicResolver(preferences: preferences), preference = preferences.quality, cache = cache
        // A downloaded song plays from its file, with no channel to find.
        if let saved = MusicDownloadLibrary.shared.localSelection(for: track) {
            Diagnostics.shared.record(.info, "music", "play downloaded \(saved.probe.format.label)")
            let length = saved.probe.duration ?? track.duration
            start(saved, at: resumeAt.flatMap { seconds in length.map { seconds < $0 - 5 } == true ? seconds : nil }, run: run)
            return
        }
        Diagnostics.shared.record(.info, "music", "play \(track.ids.keys.map(\.rawValue).sorted().joined(separator: "+")) preference=\(preference.rawValue)")
        task = Task {
            do {
                let selection = try await resolver.select(track, preference: preference, cache: cache)
                guard self.generation == run else { return }
                self.attempts = selection.attempts
                // A saved position only applies to a stream as long as the song, well before its end.
                let length = selection.probe.duration ?? track.duration
                let at = resumeAt.flatMap { seconds in length.map { seconds < $0 - 5 } == true ? seconds : nil }
                self.start(selection, at: at, run: run)
            } catch {
                guard self.generation == run else { return }
                self.songFailed(MusicProviderError(error), run: run)
            }
        }
    }

    private func start(_ selection: MusicPlaybackSelection, at seconds: Double?, run: UUID, preparedItem: AVPlayerItem? = nil) {
        if preparedItem == nil { tearDownItem() } else { removeItemObservers() }
        self.selection = selection
        duration = selection.probe.duration ?? track?.duration
        let stream = selection.stream
        setItem(url: stream.url, headers: stream.headers, metadata: track ?? selection.track, at: seconds, run: run, preparedItem: preparedItem)
        loadLyrics(for: selection)
        Diagnostics.shared.record(.info, "music", "start \(selection.candidate.provider.rawValue) host=\(stream.url.host() ?? "-") \(selection.probe.format.label)\(selection.degraded ? " degraded" : "")")
    }

    /// Plays a stream, watching for its failure and its end, and for no sound within the start window.
    @discardableResult private func setItem(url: URL, headers: [String: String], metadata track: MusicTrack, at seconds: Double?, run: UUID, preparedItem: AVPlayerItem? = nil) -> AVPlayerItem {
        activateAudioSession()
        let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = preparedItem ?? AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 15
        #if os(tvOS)
        // AVKit's transport bar and info panel show the song from these.
        item.externalMetadata = Self.metadata(for: track)
        #endif
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed, detail = item.error.map { String(describing: type(of: $0)) + " " + (($0 as NSError).code.description) }
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.generation == run, self.player.currentItem === item, failed else { return }
                self.playbackFailed("item failed \(detail ?? "-")", run: run)
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self, weak item] note in
            let code = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.code
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else { return }
                self.playbackFailed("interrupted \(code.map(String.init) ?? "-")", run: run)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else { return }
                self.songEnded(run: run)
            }
        })
        if preparedItem == nil { player.insert(item, after: nil) }
        position = seconds ?? 0
        phase = wantsPlayback ? .loading : .paused
        streamSetAt = Date()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let item else { return }
                self?.tick(item: item, run: run)
            }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self, weak item] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.generation == run, self.player.currentItem === item,
                      self.player.timeControlStatus == status else { return }
                self.statusChanged(status)
            }
        }
        // Initial resume is a seek too: keep the lyric clock at its target until it lands.
        if let seconds { seek(to: seconds) }
        if wantsPlayback { player.play() }
        else { player.pause() }
        if preparedItem != nil { statusChanged(player.timeControlStatus) }
        // Buffering, pausing and interruptions are not failures; no sound at all within the window is.
        startWatch = Task { [weak self, weak item] in
            try? await Task.sleep(for: Self.startWindow)
            guard let self, let item, !Task.isCancelled, self.generation == run,
                  self.player.currentItem === item, self.phase == .loading, self.player.rate > 0 else { return }
            self.playbackFailed("no sound within 10 s", run: run)
        }
        return item
    }

    /// A TVBox episode: its source gives the stream, unless the page that started the queue already has it.
    private func loadSource(_ source: MusicSourceEpisode, track: MusicTrack, at resumeAt: Double?, run: UUID) {
        let given = givenStream?.track == track.id ? givenStream?.channel : nil
        givenStream = nil
        let resolve = resolveSource
        task = Task {
            do {
                let stream: Channel
                if let given { stream = given }
                else if let resolve { stream = try await resolve(source) }
                else { throw CancellationError() }
                guard self.generation == run else { return }
                self.startSource(stream, track: track, at: resumeAt, run: run)
            } catch {
                guard self.generation == run else { return }
                self.songFailed(MusicProviderError(error), run: run, message: error.localizedDescription)
            }
        }
    }

    private func startSource(_ stream: Channel, track: MusicTrack, at seconds: Double?, run: UUID) {
        tearDownItem()
        sourceStream = stream
        // Addresses only the video player can open (its own schemes for drives and remuxed streams) go there.
        guard ["http", "https", "file"].contains(stream.url.scheme?.lowercased() ?? "") else {
            handOff(stream, reason: "scheme \(stream.url.scheme ?? "-")", picture: false)
            return
        }
        let item = setItem(url: stream.url, headers: stream.headers, metadata: track, at: seconds, run: run)
        Diagnostics.shared.record(.info, "music", "start source host=\(stream.url.host() ?? "-")")
        // A stream with a picture belongs in the video player. AVPlayer gives the picture's size once it has one:
        // at once for a file, and for HLS when a variant with video loads; a song's cover art has none.
        pictureObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            guard size.width > 0, size.height > 0 else { return }
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.generation == run, self.player.currentItem === item, self.sourceStream == stream else { return }
                self.handOff(stream, reason: "picture \(Int(size.width))x\(Int(size.height))", picture: true)
            }
        }
    }

    /// The source's episode playing, in the video player instead.
    func openInVideoPlayer() {
        guard let stream = sourceStream else { return }
        handOff(stream, reason: "viewer", picture: false)
    }

    /// Stops here and opens the episode in the video player where it was. Nothing of it stays in Continue Playing.
    private func handOff(_ stream: Channel, reason: String, picture: Bool) {
        let at = currentSeconds > 1 ? currentSeconds : position, covered = presentsPlayer
        Diagnostics.shared.record(.info, "music", "source to the video player: \(reason)")
        sourceStream = nil
        stop()
        handOffSource?(stream, at, picture, covered)
    }

    private func loadLyrics(for selection: MusicPlaybackSelection) {
        guard let item = player.currentItem else { return }
        let run = generation
        let songID = selection.track.id
        // Lyrics belong to the actual platform recording and imported source. A failed lookup
        // may retry after recovery, and switching providers must not keep the old timing.
        let identity = songID + "|" + selection.candidate.id + "|" + (selection.stream.sourceID ?? "")
        guard lyricsFor != identity || (lyrics == nil && !lyricsLoading) else { return }
        let recordingChanged = lyricsFor != identity
        lyricsFor = identity
        lyricsTask?.cancel()
        if recordingChanged { lyrics = nil }
        if selection.stream.url.isFileURL,
           let saved = MusicDownloadLibrary.shared.lyrics(for: selection.track), saved.platform == selection.candidate.platform {
            lyrics = saved; lyricsLoading = false
            return
        }
        lyricsLoading = true
        let loader = MusicLyricsLoader(), platform = selection.candidate.platform, sourceID = selection.stream.sourceID
        var track = selection.track
        track.ids[platform] = selection.candidate.songID
        lyricsTask = Task { [weak item] in
            let found = await loader.lyrics(for: track, playing: platform, sourceID: sourceID)
            guard let item, !Task.isCancelled, self.generation == run, self.player.currentItem === item,
                  self.lyricsFor == identity, self.selection?.track.id == songID else { return }
            self.lyrics = found; self.lyricsLoading = false
        }
    }

    private func songEnded(run: UUID) {
        guard generation == run else { return }
        guard wantsPlayback else { return }
        if repeatMode == .one || repeatMode == .all && queue?.hasNext != true && queue?.repeatingTrackCount == 1 {
            seek(to: 0); activateAudioSession(); player.play(); phase = .loading
            return
        }
        if canAdvance { next(); return }
        phase = .paused
        seek(to: 0)
        saveResumePoint(force: true)
    }

    /// No channel could play the song: skip it while a queue goes on, otherwise stop and say why.
    private func songFailed(_ error: MusicProviderError, run: UUID, message: String? = nil) {
        consecutiveFailures += 1
        if let queue, queue.skipsAfterFailure(consecutive: consecutiveFailures), let title = track?.title {
            notice = L10n.text("Skipped “%@”: %@", title, message ?? error.localizedDescription)
            Diagnostics.shared.record(.warning, "music", "skipped after: \(error.detail)")
            phase = wantsPlayback ? .resolving : .paused
            pendingFailureSkip = run
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.generation == run, self.pendingFailureSkip == run, self.wantsPlayback else { return }
                self.pendingFailureSkip = nil
                self.next()
            }
            return
        }
        fail(error, message: message)
    }

    /// A stream that stopped working: refresh it, then try another channel, then give up.
    private func playbackFailed(_ reason: String, run: UUID) {
        // The video player has more ways to play a source's stream (its own demuxer, proxies).
        if generation == run, let stream = sourceStream { handOff(stream, reason: reason, picture: false); return }
        guard generation == run, let selection, let track else { return }
        Diagnostics.shared.record(.warning, "music", "playback failed \(selection.candidate.provider.rawValue): \(reason)")
        let at = currentSeconds, previous = selection.probe
        if let sourceID = selection.stream.sourceID {
            // One fresh address is allowed for expiry. A second real playback failure must
            // fall through to another import instead of resolving the same healthy header.
            if !retriedLXSourceIDs.insert(sourceID).inserted { failedLXSourceIDs.insert(sourceID) }
        }
        startWatch?.cancel()
        let mayTryAnotherImport = selection.candidate.provider == .lx && !failedLXSourceIDs.isEmpty && recovery.resolvesLeft > 0
        var step = recovery.next(failed: selection.candidate, untried: alternatives)
        // Honor a selected provider fallback. Another import may use the remaining slot only
        // when the normal policy found no provider candidate; it must not displace that choice.
        if case .giveUp = step, mayTryAnotherImport { step = .refresh(selection.candidate) }
        let resolver = MusicResolver(preferences: preferences, excludingLXSourceIDs: failedLXSourceIDs), preference = preferences.quality, cache = cache
        switch step {
        case .giveUp:
            failureDetail = reason
            tearDownItem()
            songFailed(MusicProviderError.invalidResponse(reason), run: run, message: L10n.text("Playback stopped, and no other channel could continue it."))
        case .refresh(let candidate), .switchTo(let candidate):
            let next = UUID(); generation = next
            task?.cancel()
            tearDownItem()
            position = at
            phase = .resolving
            task = Task {
                do {
                    var chosen = try await resolver.refresh(candidate, track: track, preference: preference, cache: cache)
                    guard self.generation == next else { return }
                    chosen.untried = self.alternatives.filter { $0 != candidate }
                    self.record(chosen.attempts)
                    if candidate == selection.candidate || MusicRecovery.canResume(from: previous, to: chosen.probe) {
                        self.start(chosen, at: at, run: next)
                    } else {
                        // Another version must not take over at the same second: the viewer decides.
                        self.selection = chosen
                        self.fail(MusicProviderError.differentRecording(chosen.probe.duration ?? 0),
                                  message: L10n.text("The other channel has a different version. Choose a channel to continue."))
                    }
                } catch {
                    guard self.generation == next else { return }
                    self.record([MusicAttempt(candidate: candidate, outcome: .failed(MusicProviderError(error)), seconds: 0)])
                    self.playbackFailedAgain(candidate, reason: MusicProviderError(error).detail, run: next)
                }
            }
        }
    }

    private func playbackFailedAgain(_ candidate: MusicCandidate, reason: String, run: UUID) {
        guard var selection else { return }
        selection.candidate = candidate
        self.selection = selection
        playbackFailed(reason, run: run)
    }

    private func fail(_ error: MusicProviderError, message: String? = nil) {
        cancelPreparation()
        startWatch?.cancel()
        failureDetail = failureDetail ?? error.detail
        phase = .failed(message ?? error.localizedDescription)
        // Another version of the song waiting for the listener's choice is not a failure.
        let expected: Bool
        switch error { case .differentRecording, .cancelled: expected = true; default: expected = false }
        Diagnostics.shared.record(expected ? .warning : .error, "music", "failed provider=\(selection?.candidate.provider.rawValue ?? "-"): \(error.detail)")
    }

    private func record(_ new: [MusicAttempt]) {
        for attempt in new {
            if let index = attempts.firstIndex(where: { $0.candidate == attempt.candidate }) { attempts[index] = attempt } else { attempts.append(attempt) }
        }
    }

    private func tick(item: AVPlayerItem, run: UUID) {
        guard generation == run, player.currentItem === item, track != nil, seekingTo == nil else { return }
        // The callback's CMTime may have been queued before a seek. Sample this item now,
        // so a late callback cannot jump the lyrics back to an abandoned timeline.
        let seconds = item.currentTime().seconds
        guard seconds.isFinite else { return }
        position = max(0, seconds)
        let itemDuration = item.duration.seconds
        if itemDuration.isFinite, itemDuration > 0 { duration = itemDuration }
        saveResumePoint(force: false)
        if let prepared, !preparationIsFresh(prepared) { cancelPreparation() }
        prepareNextIfNeeded()
    }

    /// Saves where listening is every few seconds of playback, and at once on pause and stop.
    private func saveResumePoint(force: Bool) {
        guard let queue, selection != nil || sourceStream != nil else { return }
        guard force || abs(position - lastSavedPosition) >= 5 else { return }
        lastSavedPosition = position
        library.saveResumePoint(MusicResumePoint(queue: queue, position: position))
        if let source = queue.current?.source { recordSource?(source, position, duration ?? 0) }
    }

    private func statusChanged(_ status: AVPlayer.TimeControlStatus) {
        guard track != nil else { return }
        switch status {
        case .playing:
            guard wantsPlayback else { player.pause(); return }
            if phase == .loading || phase == .paused { phase = .playing; startWatch?.cancel() }
            if let set = streamSetAt {
                streamSetAt = nil
                Diagnostics.shared.record(.info, "music", String(format: "sound after %.1fs (stream %.1fs) at %.0fs", Date().timeIntervalSince(requestedAt), Date().timeIntervalSince(set), position))
            }
            if !recordedPlay, let track {
                recordedPlay = true; consecutiveFailures = 0; notice = nil
                // A source's episodes are kept under their book in the playback history instead.
                if track.source == nil { library.recordPlay(track) }
            }
            prepareNextIfNeeded()
        case .waitingToPlayAtSpecifiedRate:
            if phase == .playing { phase = .loading }
        case .paused:
            if phase == .playing { phase = .paused }
        @unknown default: break
        }
    }

    private func tearDownItem() {
        cancelPreparation()
        removeItemObservers()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        player.removeAllItems()
    }

    private func removeItemObservers() {
        seekRevision = UUID(); seekingTo = nil; timelineRevision = UUID()
        lyricsTask?.cancel(); lyricsTask = nil
        lyrics = nil; lyricsFor = nil; lyricsLoading = false
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        itemObservation = nil; pictureObservation = nil; rateObservation = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        streamSetAt = nil
    }

    // MARK: - One upcoming media item

    private func cancelPreparation() {
        preparationID = UUID()
        preparationTask?.cancel(); preparationTask = nil
        player.actionAtItemEnd = .pause
        if let prepared, player.currentItem !== prepared.item { player.remove(prepared.item) }
        prepared = nil
    }

    private func refreshPreparation() {
        adoptPreparedIfAdvanced()
        cancelPreparation()
        prepareNextIfNeeded()
    }

    private func preparationIsFresh(_ next: PreparedNext) -> Bool {
        next.selection.stream.expiresAt.map { $0.timeIntervalSinceNow > 30 } ?? true
    }

    /// Resolving/decoding the upcoming item is kept away from startup, and close enough to EOF
    /// that temporary media URLs remain useful. AVQueuePlayer alone owns both media items.
    private func prepareNextIfNeeded() {
        guard wantsPlayback, phase == .playing, preparationTask == nil, prepared == nil,
              sourceStream == nil, selection != nil, repeatMode != .one,
              let duration, duration - position <= 30, duration - position > 0,
              var nextQueue = queue, nextQueue.tracks.count > 1 else { return }
        if nextQueue.advance() == nil {
            guard repeatMode == .all else { return }
            if shuffled && nextQueue.isShuffled { guard nextQueue.restartShuffledPass() != nil else { return } }
            else { guard nextQueue.jump(to: 0) != nil else { return } }
        }
        guard let nextTrack = nextQueue.current, nextTrack.source == nil else { return }
        if nextQueue.isShuffled && !nextQueue.isShuffledWithinCurrentDomain { return }
        let intendedQueue = nextQueue, run = generation, request = UUID()
        preparationID = request
        let resolver = MusicResolver(preferences: preferences), quality = preferences.quality
        preparationTask = Task { [weak self] in
            do {
                let selection: MusicPlaybackSelection
                if let saved = MusicDownloadLibrary.shared.localSelection(for: nextTrack) { selection = saved }
                else { selection = try await resolver.select(nextTrack, preference: quality) }
                guard let self, !Task.isCancelled, self.generation == run, self.preparationID == request,
                      self.wantsPlayback, let current = self.player.currentItem else { return }
                let stream = selection.stream
                guard stream.expiresAt.map({ $0.timeIntervalSinceNow > max(30, (self.duration ?? 0) - self.position + 15) }) ?? true else {
                    return
                }
                let asset = AVURLAsset(url: stream.url, options: stream.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 15
                guard self.player.canInsert(item, after: current) else { return }
                self.prepared = PreparedNext(origin: run, queue: intendedQueue, selection: selection, item: item)
                self.player.insert(item, after: current)
                self.player.actionAtItemEnd = .advance
                Diagnostics.shared.record(.info, "music", "prepared one next media item")
            } catch {
                // EOF will use the ordinary resolver/recovery path. A failed preparation
                // must neither skip the current song nor start a second playback task.
            }
            // Keep a completed task as a one-attempt marker until this queue intent changes.
        }
    }

    /// AVQueuePlayer has already moved the audio timeline. Only its observers/metadata change;
    /// the buffered item is neither replaced nor sought, which preserves continuous output.
    private func adoptPreparedIfAdvanced() {
        guard let next = prepared, player.currentItem === next.item, next.origin == generation else { return }
        prepared = nil
        preparationTask?.cancel(); preparationTask = nil
        preparationID = UUID()
        player.actionAtItemEnd = .pause
        task?.cancel(); startWatch?.cancel(); lyricsTask?.cancel()
        let run = UUID(); generation = run
        queue = next.queue
        synchronizePlaybackMode()
        attempts = next.selection.attempts; failureDetail = nil; sourceStream = nil
        position = 0; duration = next.selection.probe.duration ?? next.selection.track.duration
        recordedPlay = false; lyricsFor = nil; lyrics = nil
        lyricsOffset = savedLyricsOffset(for: next.selection.track.id)
        cache = MusicStreamCache(); recovery = MusicRecovery(); requestedAt = Date()
        retriedLXSourceIDs = []; failedLXSourceIDs = []
        start(next.selection, at: nil, run: run, preparedItem: next.item)
        if next.item.status == .failed { playbackFailed("prepared media failed", run: run) }
    }

    #if os(tvOS)
    private static func metadata(for track: MusicTrack) -> [AVMetadataItem] {
        func entry(_ identifier: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
            guard let value, !value.isEmpty else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item.copy() as? AVMetadataItem
        }
        return [entry(.commonIdentifierTitle, track.title), entry(.commonIdentifierArtist, track.artistLine),
                entry(.commonIdentifierAlbumName, track.album)].compactMap { $0 }
    }
    #endif

    private func activateAudioSession() {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}

enum MusicNowPlayingPanel: Hashable { case lyrics, queue }

enum MusicRepeatMode: String {
    case off, all, one
    var next: MusicRepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
    var label: String {
        switch self {
        case .off: L10n.text("Repeat Off")
        case .all: L10n.text("Repeat All")
        case .one: L10n.text("Repeat One")
        }
    }
}
