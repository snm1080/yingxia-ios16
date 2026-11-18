#if os(iOS)
import SwiftUI
import Perception
@preconcurrency import AVKit
import MediaPlayer
import TVCore
import UniformTypeIdentifiers

/// The iPhone and iPad player. The picture plays in a layer of our own and every control is drawn here: AVKit's
/// controls on iOS keep AirPlay and volume in a row of their own above anything laid over them and take no buttons
/// of ours, so the title, our buttons, AirPlay and Picture in Picture couldn't share one row. Back and the title sit
/// on the left of the top row, the buttons on the right, play and skip in the middle, and the seek bar at the bottom.
struct MobilePlayerView: View {
    let channel: Channel
    let session: PlaybackSession
    let orientationID: PlayerOrientation.Presentation
    @Binding var showsDanmaku: Bool
    @Binding var upscalesVideo: Bool
    @Binding var smoothsVideo: Bool
    var waiting: PlaybackWaitContent?
    /// Whether the controls show. The player screen runs the timer that hides them.
    let chromeVisible: Bool
    /// A tap on the picture shows or hides the controls.
    let toggleChrome: () -> Void
    /// A control was used: the controls stay up a while longer.
    let poke: () -> Void
    /// The seek bar is held (true) or let go (false): the controls stay up until it is let go.
    let hold: (Bool) -> Void
    let close: () -> Void
    /// The whole screen, or the top of an iPhone watch page.
    var layout: MobilePlayerLayout = .screen
    /// On a watch page: Full Screen, or back to the page.
    var toggleFullScreen: (() -> Void)? = nil

    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pip = PictureInPicture.shared
    @State private var clock = PlayerClock()
    @State private var importsPlayerFile = false
    @State private var playerFileKind = PlayerFileKind.subtitle
    @State private var playerFileSession = ""
    @State private var importingDanmaku = false
    @State private var danmakuImportError: String?
    @State private var danmakuImportWork: Task<Void, Never>?
    @State private var danmakuImportSession = ""
    @State private var danmakuImportID = UUID()
    @State private var nowPlaying = VideoNowPlaying()
    @State private var videoAspect = PlayerVideoAspect.load()
    @State private var subtitleStyle = SubtitleStyle.load()
    @State private var speed: Float = 1
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @State private var localPanel: LocalPlayerPanel?
    @State private var playerSize = CGSize.zero
    @State private var keyboardTop: CGFloat?
    @State private var subtitleTab = "轨道"
    @State private var subtitleTarget = SubtitleTrackSelection.Target.primary
    @State private var danmakuTab = "来源"
    @State private var queueGrid = true
    @AppStorage("local.playback.prefetchNext") private var prefetchNext = true
    /// Devices with Yingxia open, for the Play On button; and the one the video was sent to.
    @State private var tvBrowser = PlayOnBrowser()
    @State private var playingOn: String?
    /// Touching and holding the picture plays faster while the finger is down, or after sliding down kept it.
    @State private var boost: SpeedBoost?
    @State private var holding = false
    @AppStorage(SpeedBoost.key) private var holdSpeed = SpeedBoost.standard
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    /// The heads-up line over the picture — progress, picture size, frame rate, the clock and the download
    /// rate — as WebHTV shows it; on by default, its switch sits in the player settings.
    @AppStorage("local.playback.osd") private var showsOSD = true
    /// The full-screen top row's height, which the info panel keeps clear of while the controls show.
    @State private var topRowHeight: CGFloat = 44
    @State private var bottomControlsHeight: CGFloat = 0
    @State private var noticeStackHeight: CGFloat = 0
    @State private var noticeExpiryRevision = 0
    /// Double taps on a side skip (YouTube); the run's total shows on that side for a moment.
    @State private var taps = PictureTaps()
    @State private var skipped: (forward: Bool, total: Double)?
    @State private var skippedTask: Task<Void, Never>?
    /// Controls a tap just brought up let a second tap through to the picture, which may be a double tap.
    @State private var settling = false
    @State private var settleTask: Task<Void, Never>?
    /// Sliding sideways across the picture: where the slide began.
    @State private var swipeStart: Double?
    /// Sliding up or down: the brightness in the left third, episodes in the middle, the volume in the right third.
    @AppStorage(PictureLevel.key) private var slidesLevels = true
    @State private var level: (volume: Bool, start: Double, value: Double)?
    @State private var leveling = false
    @State private var levelTask: Task<Void, Never>?
    /// Sliding up or down in the middle third steps episodes: whether this slide
    /// is an episode slide, and whether it has already fired (one step per slide).
    @State private var episodeSliding = false
    @State private var episodeSlideFired = false
    /// "Already the first/last episode", shown briefly when an episode slide
    /// runs off the end of the list.
    @State private var episodeEdge: String?
    @State private var episodeEdgeTask: Task<Void, Never>?
    /// The system's volume slider, on screen only around a slide, which keeps the system's own volume overlay away.
    @State private var systemVolume = MusicVolumeSlider.SystemSlider()
    @State private var mountsVolume = false
    /// The screen's brightness before the first slide changed it, put back when the player closes.
    @State private var brightnessBefore: CGFloat?
    /// Full screen, the controls and every touch on the picture can be locked, so a hand on the screen doesn't skip or
    /// pause. A tap then shows the lock button alone for a moment.
    @State private var locked = false
    @State private var showsLock = false
    @State private var lockTask: Task<Void, Never>?

    var body: some View {
        WithPerceptionTracking {
            playbackPresentations
        }
    }

    private var playbackSurface: some View {
        GeometryReader { viewport in
            WithPerceptionTracking {
                ZStack {
                    playbackPicture
                    playbackInteractionOverlay
                    playbackInformationOverlay
                    playbackOSDOverlay
                    controls.opacity(chromeVisible && !locked ? 1 : 0)
                        .allowsHitTesting(chromeVisible && !locked && !settling)
                    playbackNotices
                    localPopup
                        .opacity(chromeVisible && !locked ? 1 : 0)
                        .allowsHitTesting(chromeVisible && !locked && localPanel != nil)
                    if !inline { lockButton }
                }
                // The screen proposes the viewport. A previous landscape control width must
                // never enlarge the portrait player and become its next measured size.
                .frame(width: viewport.size.width, height: viewport.size.height)
                .onAppear { playerSize = viewport.size }
                .appOnChange(of: viewport.size) { _, size in playerSize = size }
            }
        }
    }

    private var playbackPicture: some View {
        WithPerceptionTracking {
            ZStack {
                KSPlayerSurface(engine: session.engine, aspect: videoAspect,
                                revision: session.engine.renderingRevision).playerBleed(!inline)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("视频画面")
                    .accessibilityValue(session.showsPicture ? "画面已就绪" : "正在准备画面")
                    .accessibilityIdentifier("player.picture")
                    .onAppear { attachPictureInPicture() }
                    .appOnChange(of: session.engine.renderingRevision) { _, _ in attachPictureInPicture() }
                    .appOnChange(of: session.engine.isReady) { _, _ in attachPictureInPicture() }
                    .appOnChange(of: pip.active) { _, active in
                        session.pictureInPictureActive = active
                        session.pictureInPictureController = pip
                    }
                if showsDanmaku {
                    DanmakuOverlay(engine: session.engine, comments: session.danmaku, opacity: session.danmakuOpacity,
                                   revision: session.danmakuRevision, sourceID: session.danmakuSourceRevision)
                        // Across the whole width, but below the Dynamic Island and above the home indicator when upright.
                        .playerBleed(!inline, edges: .horizontal)
                }
                let external = session.externalSubtitles.document != nil
                let primary = PlayerSubtitlePresentation(lines: session.subtitles.lines,
                    styledParts: external ? session.subtitles.styledParts : session.engine.subtitleStyledParts,
                    sourceTime: external ? session.subtitles.styledSourceTime : session.engine.subtitleSourceTime,
                    bitmaps: session.engine.subtitleBitmaps)
                let usesAI = !session.aiSubtitles.lines.isEmpty
                let secondary = PlayerSubtitlePresentation(lines: usesAI ? session.aiSubtitles.lines : session.engine.secondarySubtitleLines,
                    styledParts: usesAI ? [] : session.engine.secondarySubtitleStyledParts,
                    sourceTime: session.engine.secondarySubtitleSourceTime,
                    bitmaps: usesAI ? [] : session.engine.secondarySubtitleBitmaps)
                PlayerCombinedSubtitleOverlay(primary: primary, secondary: secondary,
                    pictureSize: session.engine.presentationSize, fills: fillsScreen, videoAspect: videoAspect).playerBleed(!inline)
                // The artwork dissolves into the first frame.
                if let waiting {
                    if inline {
                        // On a watch page: the cover across the player, blurred, as before it started; the full-screen
                        // player keeps its own wait.
                        Group {
                            if waiting.starting { WatchCoverBackdrop(poster: waiting.artwork.poster, headers: waiting.artwork.headers, loading: session.error == nil) }
                            else { WaitSpinner(status: waiting.state) }
                        }
                        .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.16))))
                    } else {
                        waiting.view.playerBleed(true)
                            .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.16))))
                    }
                }
                if pip.active { pipPlaceholder }
                if playingOn != nil { Color.black.playerBleed(!inline) }
            }.onReceive(NotificationCenter.default.publisher(for: SubtitleStyle.changed)) { _ in subtitleStyle = SubtitleStyle.load() }
        }
    }

    private var playbackInteractionOverlay: some View {
        WithPerceptionTracking {
            ZStack {
                // A tap on the picture shows or hides the controls; a tap on a control keeps them up (see `rows`).
                // Two taps on a side skip, touching and holding plays faster, and sliding sideways seeks.
                PictureGestures(tap: tapped, hold: held, swipe: swiped, levels: slidesLevels && !inline) { wider in
                    guard !locked else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { fillsScreen = wider }
                }
                .playerBleed(!inline)
                .accessibilityHidden(true)
                if mountsVolume {
                    MusicVolumeSlider.HiddenVolumeView(system: systemVolume).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                }
                boostLabel
                skippedLabel
                swipeLabel
                levelLabel
                episodeEdgeLabel
                if let playingOn {
                    PlayOnPlaceholder(receiver: playingOn) {
                        self.playingOn = nil
                        if session.paused { session.togglePlayback() }
                    }
                }
            }
        }
    }

    private var playbackInformationOverlay: some View {
        WithPerceptionTracking {
                // While the controls show it moves below their top row; on a watch page, too small for both, they take
                // its corner and it comes back with the bare picture.
                if showsPlaybackInfo && session.error == nil && session.showsPicture && !pip.active && playingOn == nil {
                    PlaybackInfoPanel(session: session)
                        .padding(inline ? 8 : 16)
                        .padding(.top, chromeVisible && !inline ? topRowHeight + 12 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .opacity(chromeVisible && inline ? 0 : 1)
                        .animation(.appSmooth(duration: 0.25), value: chromeVisible)
                        .allowsHitTesting(false)
                }
        }
    }

    /// The heads-up line stays with the bare picture (it is a display, not a control), but keeps clear of
    /// the top row while the controls show and of the technical information panel when both are on; on a
    /// watch page it yields its corner to the controls exactly as that panel does.
    private var playbackOSDOverlay: some View {
        WithPerceptionTracking {
                if showsOSD && session.error == nil && session.showsPicture && !pip.active && playingOn == nil {
                    PlayerOSD(session: session)
                        .padding(inline ? 8 : 16)
                        .padding(.top, (chromeVisible && !inline ? topRowHeight + 12 : 0) + (showsPlaybackInfo ? 68 : 0))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .opacity(chromeVisible && inline ? 0 : 1)
                        .animation(.appSmooth(duration: 0.25), value: chromeVisible)
                        .allowsHitTesting(false)
                }
        }
    }

    private var playbackNotices: some View {
        WithPerceptionTracking {
                let _ = noticeExpiryRevision
                let uptime = ProcessInfo.processInfo.systemUptime
                let allNotices = [session.mediaEnhancements.notice, session.remoteSkip.notice].compactMap { $0 }
                let notices = allNotices.filter { $0.isVisible(at: uptime) }
                let nextExpiry = scenePhase == .active && !pip.active && playingOn == nil
                    ? PlayerNotice.nextExpiry(allNotices, at: uptime) : nil
                VStack(spacing: 6) {
                    ForEach(notices) { notice in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: notice.kind == .success ? "checkmark.circle" : notice.kind == .warning ? "exclamationmark.circle" : "info.circle")
                                .foregroundStyle(notice.kind == .warning ? Color.orange : Color.white.opacity(0.85))
                            Text(notice.message).font(.system(size: inline ? 11 : 13, weight: .medium)).lineLimit(3)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .localPlayerGlassSurface(cornerRadius: 12)
                        .accessibilityIdentifier("player.notice")
                    }
                }
                .foregroundStyle(.white).frame(maxWidth: min(380, max(0, playerSize.width - 32)))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if abs(noticeStackHeight - height) > 0.5 { noticeStackHeight = height }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, noticeBottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .opacity(pip.active || playingOn != nil ? 0 : 1)
                .allowsHitTesting(false)
                .task(id: nextExpiry) {
                    guard let nextExpiry else { return }
                    let remaining = max(0, nextExpiry - ProcessInfo.processInfo.systemUptime)
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                    guard !Task.isCancelled else { return }
                    noticeExpiryRevision &+= 1
                }
        }
    }

    private var noticeBottomInset: CGFloat {
        let resting: CGFloat = inline ? 12 : 28
        guard chromeVisible && !locked && showsTransport else { return resting }
        let clearance = bottomControlsHeight + (inline ? 8 : 16) + 10
        return min(clearance, max(0, playerSize.height - noticeStackHeight - 8))
    }

    private var playbackLifecycle: some View {
        WithPerceptionTracking {
            playbackSurface
            .onAppear {
                PlayerOrientation.begin(presentationID: orientationID)
                guard PlayerOrientation.owns(orientationID) else { return }
                session.orientationPolicy.begin(mediaID: channel.id)
                if PlayerOrientation.available, let direction = session.orientationPolicy.currentDirection {
                    PlayerOrientation.set(landscape: direction == .landscape, presentationID: orientationID)
                } else {
                    // The iOS16 initial onChange callback can precede this onAppear.
                    // Already-ready media will not publish another size change.
                    applyOrientation(orientationSample)
                }
                clock.attach(session.engine)
                speed = session.engine.speed
                session.engine.setSubtitleDelay(UserDefaults.standard.double(forKey: "local.playback.subtitleDelay"))
                nowPlaying.start(session)
                nowPlaying.update(title: channel.name, session: session)
                tvBrowser.start()
            }
            .onDisappear {
                clock.detach(); nowPlaying.stop(); tvBrowser.stop()
                if let brightnessBefore { screen?.brightness = brightnessBefore }
            }
            // Played here again (the Lock Screen, say): the other device no longer has it to itself.
            .appOnChange(of: session.paused) { _, paused in if !paused { playingOn = nil } }
            .appOnChange(of: session.engine.speed) { _, value in if session.boost == nil { speed = value } }
            .appOnChange(of: nowPlayingState, initial: true) { nowPlaying.update(title: channel.name, session: session) }
            .appOnChange(of: nowPlayingArtwork, initial: true) { _, artwork in nowPlaying.show(artwork, session: session) }
        }
    }

    private var playbackGestures: some View {
        WithPerceptionTracking {
            playbackLifecycle
            // Pausing ends the faster speed in the session; another episode or quality plays at the chosen one.
            .appOnChange(of: session.boost == nil) { _, ended in if ended { boost = nil } }
            .appOnChange(of: session.engine.mediaID) { endBoost(); clock.replaceMedia() }
            .appOnChange(of: boost) { old, new in
                guard let new else { return }
                guard let old else { UIImpactFeedbackGenerator(style: .light).impactOccurred(); return }
                if new.locked != old.locked { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                else if new.rate != old.rate { UISelectionFeedbackGenerator().selectionChanged() }
            }
        }
    }

    private var playbackMedia: some View {
        WithPerceptionTracking {
            playbackGestures
            .appOnChange(of: orientationSample, initial: true) { _, sample in applyOrientation(sample) }
            .appOnChange(of: locked) { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            // A failure, or a watch page's player back from full screen, has controls to reach.
            .appOnChange(of: session.error != nil || inline) { _, unlock in if unlock { setLocked(false) } }
        }
    }

    private var playbackPresentations: some View {
        WithPerceptionTracking {
            playbackMedia
            .localDocumentImporter(isPresented: $importsPlayerFile, kind: playerFileKind.documentKind, completion: receivePlayerFile)
            .appOnChange(of: videoAspect) { _, value in value.save() }
            .appOnChange(of: localPanel) { _, panel in
                hold(panel != nil)
                if panel == nil { keyboardTop = nil }
            }
            .appOnChange(of: channel.id) { if localPanel != .episodes { localPanel = nil } }
            .appOnChange(of: session.mediaEnhancements.sessionID) { _, _ in
                danmakuImportID = UUID()
                danmakuImportWork?.cancel(); importingDanmaku = false; importsPlayerFile = false
            }
            .onDisappear { danmakuImportID = UUID(); danmakuImportWork?.cancel() }
        }
    }

    private struct OrientationSample: Equatable {
        let mediaID: String
        let ready: Bool
        let width: Double
        let height: Double
    }

    private var orientationSample: OrientationSample {
        let size = session.engine.presentationSize
        return OrientationSample(mediaID: channel.id, ready: session.activeChannelID == channel.id && session.engine.isReady,
                                 width: size.width, height: size.height)
    }

    private func applyOrientation(_ sample: OrientationSample) {
        guard sample.ready, PlayerOrientation.available, PlayerOrientation.owns(orientationID) else { return }
        session.orientationPolicy.begin(mediaID: sample.mediaID)
        guard let direction = session.orientationPolicy.picture(width: sample.width, height: sample.height) else { return }
        PlayerOrientation.set(landscape: direction == .landscape, presentationID: orientationID)
    }

    private func rotatePlayer() {
        guard PlayerOrientation.owns(orientationID) else { return }
        session.orientationPolicy.begin(mediaID: channel.id)
        let landscape = UIApplication.shared.appWindowScene?.interfaceOrientation.isLandscape ?? (playerSize.width > playerSize.height)
        PlayerOrientation.set(landscape: session.orientationPolicy.rotate(currentlyLandscape: landscape) == .landscape,
                              presentationID: orientationID)
        poke()
    }

    /// What the Lock Screen's Now Playing shows, besides the position the system runs on from the rate.
    private struct NowPlayingState: Equatable {
        var title: String
        var paused: Bool
        var live: Bool
        var timeline: Bool
        var duration: Double
        var speed: Float
        var boost: Float?
    }

    private var nowPlayingState: NowPlayingState {
        NowPlayingState(title: channel.name, paused: session.paused, live: session.isLive, timeline: session.hasTimeline,
                        duration: clock.duration, speed: speed, boost: session.boost)
    }

    /// The poster the waiting screen shows, for the Lock Screen and Control Center.
    private var nowPlayingArtwork: PlaybackArtwork {
        let catalog = store.catalog(for: channel)
        return PlaybackArtwork(poster: catalog?.video.poster ?? channel.historyContext?.poster,
                               headers: catalog?.video.posterHeaders ?? channel.historyContext?.posterHeaders ?? [:])
    }

    // MARK: Taps and slides

    private func tapped(_ x: CGFloat, _ width: CGFloat) {
        #if DEBUG
        Diagnostics.shared.record(.debug, "player.chrome", "event=picture-tap x=\(x) width=\(width) visible=\(chromeVisible) settling=\(settling) locked=\(locked)")
        #endif
        // Locked, a tap shows (or hides) the lock button and nothing else: no controls, no skip, no pause.
        if locked {
            if showsLock { withAnimation(.easeOut(duration: 0.2)) { showsLock = false } } else { flashLock() }
            return
        }
        let zone = PictureTaps.zone(x: x, width: width, seekable: seekable && showsTransport && playingOn == nil && !pip.active)
        switch taps.tap(at: ProcessInfo.processInfo.systemUptime, in: zone) {
        case .toggleControls:
            let showing = !chromeVisible
            toggleChrome()
            if showing { settle(); clearLabels() }
        case .togglePlayback:
            toggleChrome()
            session.togglePlayback()
        case .skip(let seconds, let total, _):
            // Hidden whether the first tap showed the controls or hid them.
            hideChrome()
            session.skip(seconds)
            nowPlaying.update(title: channel.name, session: session)
            withAnimation(.appSnappy(duration: 0.25)) { skipped = (seconds > 0, total) }
            skippedTask?.cancel()
            skippedTask = Task {
                try? await Task.sleep(for: .seconds(PictureTaps.streak + 0.1))
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { skipped = nil } }
            }
        }
    }

    /// For as long as a second tap would make a double tap, it reaches the picture rather than the controls it showed.
    private func settle() {
        settling = true
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: .seconds(PictureTaps.interval))
            if !Task.isCancelled { settling = false }
        }
    }

    /// A gesture's label has the picture to itself: the controls make way, unless loading or a failure keeps them up.
    private func hideChrome() {
        if chromeVisible && showsTransport { toggleChrome() }
    }

    /// The controls a tap brings up replace the labels a skip or a slide leaves for a moment.
    private func clearLabels() {
        skippedTask?.cancel(); skipped = nil
        episodeEdgeTask?.cancel(); episodeEdge = nil
        guard !leveling else { return }
        levelTask?.cancel(); level = nil; mountsVolume = false
    }

    private var screen: UIScreen? { UIApplication.shared.appWindowScene?.screen }

    private func swiped(_ phase: PictureGestures.Swipe) {
        #if DEBUG
        Diagnostics.shared.record(.debug, "player.picture-gesture", "phase=\(String(describing: phase)) visible=\(chromeVisible) settling=\(settling)")
        #endif
        if locked, case .began = phase { return }
        switch phase {
        case .began(.seek):
            guard showsTransport, seekable, clock.duration > 0, playingOn == nil, !pip.active else { return }
            let start = clock.currentPosition
            swipeStart = start
            clock.scrub(to: start)
            hideChrome()
        case .began(.episode):
            // Nothing happens yet: the slide must first travel far enough
            // (see .moved), so a short middle slide stays a no-op.
            episodeSliding = true
            episodeSlideFired = false
        case .began(let slide):
            let volume = slide == .volume
            guard volume || screen != nil else { return }
            let start = volume ? Double(AVAudioSession.sharedInstance().outputVolume) : Double(screen?.brightness ?? 0)
            if !volume, brightnessBefore == nil { brightnessBefore = screen?.brightness }
            levelTask?.cancel()
            if volume { mountsVolume = true }
            level = (volume, start, start)
            leveling = true
            hideChrome()
        case .moved(let moved, let size):
            if let swipeStart {
                clock.scrub(to: PictureSeek.target(from: swipeStart, moved: moved.width, width: size.width, duration: clock.duration))
            } else if leveling, var level {
                level.value = PictureLevel.value(from: level.start, moved: moved.height, height: size.height)
                self.level = level
                if level.volume { systemVolume.set(level.value) } else { screen?.brightness = CGFloat(level.value) }
            } else if episodeSliding, !episodeSlideFired,
                      abs(moved.height) >= 60, abs(moved.height) >= abs(moved.width) * 1.5 {
                // One step per slide, past 60pt of vertical travel: up is the
                // next episode, down is the previous one.
                episodeSlideFired = true
                stepEpisode(back: moved.height > 0)
            }
        case .ended:
            if swipeStart != nil {
                swipeStart = nil
                clock.endScrub()
                nowPlaying.update(title: channel.name, session: session)
            }
            if leveling {
                leveling = false
                levelTask = Task {
                    try? await Task.sleep(for: .seconds(0.8))
                    guard !Task.isCancelled else { return }
                    level = nil; mountsVolume = false
                }
            }
            episodeSliding = false
            episodeSlideFired = false
        }
    }

    /// An episode slide (or the boundary note at either end), through the same
    /// step the Previous/Next buttons take — no second implementation.
    private func stepEpisode(back: Bool) {
        if let action = store.step(back: back, from: channel, session: session) {
            if !action.busy { action.go() }
        } else if store.step(back: !back, from: channel, session: session) != nil {
            // The other direction exists, so this end of the list is real. A
            // title with no episodes at all stays silent either way.
            episodeEdge = back ? "已是第一集" : "已是最后一集"
            episodeEdgeTask?.cancel()
            episodeEdgeTask = Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                episodeEdge = nil
            }
        }
    }

    /// The brightness or the volume a slide up or down sets, in the middle.
    @ViewBuilder private var levelLabel: some View {
        if let level {
            HStack(spacing: 12) {
                Image(systemName: level.volume ? (level.value <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") : "sun.max.fill")
                    .frame(width: 26)
                Capsule().fill(.white.opacity(0.3)).frame(width: 150, height: 6)
                    .overlay(alignment: .leading) { WithPerceptionTracking { Capsule().fill(.white).frame(width: 150 * level.value, height: 6) } }
                // Sam: show the number, not just the bar. Display only — the value
                // is the one the slide gesture already computed and applied.
                Text(level.value, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().frame(minWidth: 46, alignment: .leading)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .glassSurface(.regular, in: Capsule())
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text(level.volume ? "Volume" : "Brightness"))
            .accessibilityValue(Text(level.value, format: .percent.precision(.fractionLength(0))))
            .accessibilityIdentifier("player.level")
        }
    }

    /// "Already the first/last episode", in the middle, in the level label's form.
    @ViewBuilder private var episodeEdgeLabel: some View {
        if let episodeEdge {
            Text(episodeEdge)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .glassSurface(.regular, in: Capsule())
                .environment(\.colorScheme, .dark)
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityIdentifier("player.episodeEdge")
        }
    }

    /// How far a run of double taps skipped, on its side.
    @ViewBuilder private var skippedLabel: some View {
        if let skipped {
            // Glass like the other gesture labels, with the skip buttons' symbol; it bounces on each further tap.
            VStack(spacing: 4) {
                Image(systemName: skipped.forward ? "goforward.10" : "gobackward.10")
                    .font(.system(size: 30, weight: .medium))
                    .appBounce(value: skipped.total)
                Text((skipped.forward ? "+" : "\u{2212}") + L10n.text("%lld s", Int(skipped.total)))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(countsDown: !skipped.forward))
            }
            .foregroundStyle(.white)
            .frame(width: 96, height: 96)
            .glassSurface(.regular, in: Circle())
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: skipped.forward ? .trailing : .leading)
            .padding(.horizontal, 48)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.8, anchor: skipped.forward ? .trailing : .leading).combined(with: .opacity))
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("player.tapSkip")
            .accessibilityValue("\(skipped.forward ? "+" : "-")\(Int(skipped.total))")
        }
    }

    /// Where a slide across the picture will seek to: the frame there, the time and how far it moves.
    @ViewBuilder private var swipeLabel: some View {
        if let swipeStart {
            let target = clock.scrubbing ?? swipeStart
            let moved = target - swipeStart
            VStack(spacing: 10) {
                if let preview = clock.preview {
                    let size = PlaybackThumbnailLayout.size(imageWidth: preview.width, imageHeight: preview.height,
                        availableWidth: max(1, playerSize.width - 48), maximumWidth: 220, maximumHeight: 160)
                    Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height).fixedSize()
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("进度预览").accessibilityIdentifier("player.thumbnail")
                }
                Text(SeekBar<EmptyView>.format(target) + " / " + SeekBar<EmptyView>.format(clock.duration))
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text((moved < 0 ? "\u{2212}" : "+") + SeekBar<EmptyView>.format(abs(moved)))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)
            .padding(16)
            .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 20))
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.swipeSeek")
            .accessibilityValue("\(Int(target))")
        }
    }

    // MARK: Lock

    /// On the left edge, halfway down, as in Bilibili: with the controls while unlocked, alone for a moment after a tap
    /// while locked.
    @ViewBuilder private var lockButton: some View {
        let visible = locked ? showsLock : chromeVisible && showsTransport
        Button {
            setLocked(!locked)
        } label: {
            Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                .appSymbolReplaceTransition().playerControlTarget()
        }
        .buttonStyle(PlayerToolbarButtonStyle(selected: locked))
        .environment(\.colorScheme, .dark)
        .accessibilityLabel(L10n.text(locked ? "Unlock Controls" : "Lock Controls"))
        .accessibilityIdentifier("player.lock")
        .padding(.leading, 16)
        .offset(y: playerSize.width > playerSize.height ? -36 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible && !settling)
        .animation(.easeOut(duration: 0.2), value: visible)
    }

    private func setLocked(_ lock: Bool) {
        guard lock != locked else { return }
        lockTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { locked = lock }
        if lock {
            // The picture to itself; the lock button stays a moment to show where it is.
            endBoost()
            hideChrome()
            clearLabels()
            flashLock()
        } else {
            showsLock = false
            if !chromeVisible { toggleChrome() } else { poke() }
        }
    }

    private func flashLock() {
        withAnimation(.easeOut(duration: 0.2)) { showsLock = true }
        lockTask?.cancel()
        lockTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showsLock = false }
        }
    }

    // MARK: Touch and hold

    /// Only while a video with a timeline plays here.
    private var boosts: Bool { showsTransport && seekable && !session.paused && playingOn == nil && !pip.active }

    private func held(_ phase: PictureGestures.Hold) {
        switch phase {
        case .began:
            guard boosts, !locked else { return }
            // A new hold replaces a kept speed: it ends with the finger unless slid down again.
            let started = SpeedBoost(rate: holdSpeed)
            boost = started; holding = true
            session.setBoost(Float(started.rate))
            // The picture to itself, as in YouTube and Douyin.
            hideChrome()
        case .moved(let offset):
            guard holding, var moved = boost else { return }
            moved.moved(x: offset.width, y: offset.height)
            guard moved != boost else { return }
            if moved.rate != boost?.rate { session.setBoost(Float(moved.rate)) }
            boost = moved
        case .ended:
            guard holding else { return }
            holding = false
            if boost?.locked != true { endBoost() }
        }
    }

    private func endBoost() {
        boost = nil; holding = false
        session.setBoost(nil)
    }

    /// The faster speed at the top, as in Douyin and YouTube; once kept, a tap on it goes back to the chosen speed.
    @ViewBuilder private var boostLabel: some View {
        if let boost {
            let rate = session.boost ?? Float(boost.rate)
            VStack(spacing: 8) {
                Button(action: endBoost) {
                    HStack(spacing: 6) {
                        if boost.locked { Image(systemName: "lock.fill") }
                        Text(Self.speedLabel(rate))
                        // Held lower than asked: the connection can't keep up with the faster speed.
                        if let wanted = session.boostWanted { Text(Self.speedLabel(wanted)).strikethrough().opacity(0.55) }
                        Image(systemName: "forward.fill")
                    }
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 14).padding(.vertical, 8).playerControlTarget()
                    .glassSurface(.regular, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(boost.locked)
                .accessibilityLabel(L10n.text("Back to Normal Speed"))
                .accessibilityValue(Self.speedLabel(rate))
                .accessibilityIdentifier("player.boost")
                if session.boostWanted != nil {
                    Text(L10n.text("Slowed down to keep up with the connection"))
                        .font(.caption).shadow(color: .black.opacity(0.6), radius: 4)
                        .accessibilityHidden(true)
                } else if holding && !boost.locked {
                    Text(L10n.text("Slide sideways to change the speed, or down to keep it"))
                        .font(.caption).shadow(color: .black.opacity(0.6), radius: 4)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            // Below the top row when the controls show.
            .padding(.top, inline ? (chromeVisible ? 58 : 10) : chromeVisible ? 112 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeOut(duration: 0.2), value: chromeVisible)
            .transition(.opacity)
        }
    }

    /// Play, skip and the seek bar wait for the stream: while it connects or after it fails, only the top row shows.
    private var showsTransport: Bool { !session.loading && session.error == nil }
    /// At the top of a watch page: smaller controls, and the page has the title.
    private var inline: Bool { layout == .inline }
    private var seekable: Bool { session.hasTimeline && !session.isLive }

    private var controls: some View {
        ZStack {
            // Scrims, so white controls read over a bright picture.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: inline ? 70 : 150)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).frame(height: inline ? 80 : 150)
            }
            .playerBleed(!inline)
            .allowsHitTesting(false)
            VStack(spacing: 0) {
                topRow
                Spacer(minLength: 0)
                if showsTransport {
                    VStack(spacing: 0) {
                        infoRow
                        bottomRow
                        localBottomControls
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs(bottomControlsHeight - height) > 0.5 { bottomControlsHeight = height }
                    }
                }
            }
            .padding(inline ? 8 : 16)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Top row

    /// Always-visible corner actions share 44 pt targets. The rotation button stays at the upper right.
    private var topRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.historyContext?.videoName ?? channel.name)
                        .font(.system(size: inline ? 13 : 18, weight: .semibold)).lineLimit(1)
                        .accessibilityIdentifier("player.title")
                    if let episode = channel.historyContext?.episodeName, !episode.isEmpty,
                       episode != channel.historyContext?.videoName {
                        Text(episode).font(.system(size: inline ? 10 : 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                            .accessibilityIdentifier("player.episodeTitle")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if playerSize.width > 600 {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        WithPerceptionTracking {
                            HStack(spacing: 8) {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(max(0, session.transfer.bytesPerSecond ?? 0)), countStyle: .file) + "/s")
                                Text(context.date, style: .time)
                            }.font(.caption2.monospacedDigit()).lineLimit(1)
                        }
                    }
                }
            }.padding(.horizontal, 6)
            HStack(spacing: playerSize.width < 350 ? 2 : 8) {
            Button(action: close) { Image(systemName: "chevron.backward").playerControlTarget() }
                .buttonStyle(PlayerToolbarButtonStyle()).accessibilityLabel("返回").accessibilityIdentifier("player.close")
            Button { togglePanel(.cast) } label: {
                Image(systemName: "airplayvideo").playerControlTarget()
            }.buttonStyle(PlayerToolbarButtonStyle(selected: localPanel == .cast)).accessibilityLabel("投屏")
                .accessibilityIdentifier("player.cast")
            Button { togglePanel(.aspect) } label: {
                Image(systemName: "aspectratio").playerControlTarget()
            }.buttonStyle(PlayerToolbarButtonStyle(selected: localPanel == .aspect)).accessibilityLabel("画面比例")
                .accessibilityIdentifier("player.aspect")
            Button { togglePanel(.information) } label: {
                Image(systemName: "info.circle").playerControlTarget()
            }.buttonStyle(PlayerToolbarButtonStyle(selected: localPanel == .information)).accessibilityLabel("视频信息")
                .accessibilityIdentifier("player.information")
            Spacer(minLength: 4)
            Button { pip.toggle() } label: { Image(systemName: pip.active ? "pip.exit" : "pip.enter").playerControlTarget() }
                .buttonStyle(PlayerToolbarButtonStyle(selected: pip.active)).disabled(!pip.supported || !pip.possible && !pip.active)
                .accessibilityLabel("画中画").accessibilityIdentifier("player.pip")
            if PlayerOrientation.available {
                Button(action: rotatePlayer) {
                    Image(systemName: "rotate.right").playerControlTarget()
                }.buttonStyle(PlayerToolbarButtonStyle())
                    .accessibilityLabel(playerSize.width > playerSize.height ? "切换竖屏" : "切换横屏")
                    .accessibilityIdentifier("player.rotate")
            }
            }
        }.simultaneousGesture(TapGesture().onEnded { poke() })
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topRowHeight = $0 }
    }

    /// The title area uses one presentation at a time, with technical information in its own popup.
    private var infoRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlayerTitleLogo(channel: channel, compact: verticalSizeClass != .compact && horizontalSizeClass == .compact)
            PlayerMediaBadges(session: session, channel: channel)
                .frame(maxWidth: min(520, playerSize.width * 0.8), alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 2)
    }

    private var fillsScreen: Bool {
        get { videoAspect.mode == .crop }
        nonmutating set { videoAspect.mode = newValue ? .crop : .original }
    }

    private static let speeds: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 6, 8]
    private static func speedLabel(_ speed: Float) -> String {
        Double(speed).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    // MARK: Middle and bottom

    private var centerRow: some View {
        HStack(spacing: 20) {
            if seekable && !inline {
                Button { session.skip(-10); sought() } label: { Image(systemName: "gobackward.10").playerControlTarget(52) }
                    .buttonStyle(PlayerCircleStyle(size: 52))
                    .accessibilityLabel(L10n.text("Back 10 seconds"))
            }
            Button { session.togglePlayback() } label: {
                // Swapped as the music player's is.
                Image(systemName: session.paused ? "play.fill" : "pause.fill").appSymbolReplaceTransition().playerControlTarget(inline ? 50 : 68)
            }
                .buttonStyle(PlayerCircleStyle(size: inline ? 50 : 68))
                .accessibilityLabel(L10n.text(session.paused ? "Play" : "Pause"))
                .accessibilityIdentifier("player.playPause")
            if seekable && !inline {
                Button { session.skip(10); sought() } label: { Image(systemName: "goforward.10").playerControlTarget(52) }
                    .buttonStyle(PlayerCircleStyle(size: 52))
                    .accessibilityLabel(L10n.text("Forward 10 seconds"))
            }
        }
        .simultaneousGesture(TapGesture().onEnded { poke() })
    }

    /// Previous and Next Episode, small and at the right of the time above the seek bar. Beside ±10 and play, a tap
    /// that ran past +10 out of habit changed the episode. Then 选集, which opens the episodes in a sheet (#524).
    @ViewBuilder private var stepButtons: some View {
        let previous = store.step(back: true, from: channel, session: session)
        let next = store.step(back: false, from: channel, session: session)
        // On a watch page the episodes are on the page itself.
        let episodes = !inline && PlayerEpisodesSheet.offered(for: channel, in: store)
        if previous != nil || next != nil || episodes || toggleFullScreen != nil {
            HStack(spacing: 10) {
                if let previous {
                    Button { previous.go() } label: { Image(systemName: "backward.end.fill").playerControlTarget() }
                        .buttonStyle(PlayerCircleStyle(size: 44))
                        .disabled(previous.busy)
                        .accessibilityLabel(L10n.text("Previous Episode"))
                }
                if let next {
                    Button { next.go() } label: { Image(systemName: "forward.end.fill").playerControlTarget() }
                        .buttonStyle(PlayerCircleStyle(size: 44))
                        .disabled(next.busy)
                        .accessibilityLabel(L10n.text("Next Episode"))
                }
                if episodes {
                    Button { togglePanel(.episodes) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: PlayerEpisodesSheet.symbol)
                            Text(L10n.text("Episodes"))
                        }
                        .font(.system(size: 18, weight: .medium)).padding(.horizontal, 8).playerControlTarget()
                    }
                    .buttonStyle(PlayerToolbarButtonStyle(selected: localPanel == .episodes))
                    .accessibilityLabel("选集").accessibilityIdentifier("player.episodes")
                }
                if let toggleFullScreen {
                    let full = layout == .pageFullScreen
                    Button(action: toggleFullScreen) {
                        Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").playerControlTarget()
                    }
                    .buttonStyle(PlayerCircleStyle(size: 44))
                    .accessibilityLabel(L10n.text(full ? "Exit Full Screen" : "Full Screen"))
                    .accessibilityIdentifier("player.fullScreen")
                }
            }
            .simultaneousGesture(TapGesture().onEnded { poke() })
        }
    }

    @ViewBuilder private var bottomRow: some View {
        if session.isLive {
            HStack {
                Text(L10n.text("LIVE")).font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.red, in: Capsule())
                Spacer(minLength: 0)
            }
        } else if session.hasTimeline {
            // Dragging holds the controls up itself (`hold`); a tap gesture here would compete with the scrubber's drag.
            SeekBar(clock: clock, moving: chromeVisible && !locked && !session.paused && !pip.active && scenePhase == .active, hold: hold, sought: sought) { EmptyView() }
        }
    }

    private var localBottomControls: some View {
        GeometryReader { viewport in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    transportButtons
                    Spacer(minLength: 12)
                    panelButtons
                    if let toggleFullScreen {
                        Button(action: toggleFullScreen) {
                            Image(systemName: layout == .pageFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").playerControlTarget()
                        }.buttonStyle(PlayerToolbarButtonStyle())
                            .accessibilityLabel(layout == .pageFullScreen ? "退出全屏" : "全屏")
                            .accessibilityIdentifier("player.fullScreen")
                    }
                }.frame(minWidth: viewport.size.width, alignment: .leading)
            }.accessibilityIdentifier("player.controls.bottom")
        }
        .frame(height: 48)
        .padding(.top, 2)
    }

    private func togglePanel(_ panel: LocalPlayerPanel) {
        localPanel = localPanel == panel ? nil : panel
        poke()
    }

    private var localPopup: some View {
        GeometryReader { geometry in
            WithPerceptionTracking {
                if let panel = localPanel {
                    let overlap = keyboardTop.map { max(0, geometry.frame(in: .global).maxY - $0) } ?? 0
                    let availableHeight = max(0, geometry.size.height - overlap)
                    let panelSize = PlayerPopupLayout.size(viewport: geometry.size, keyboardOverlap: overlap,
                        preferred: CGSize(width: panel == .speed || panel == .volume || panel == .aspect ? 300 : panel == .information ? 560 : 420,
                                          height: popupHeight(panel)))
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(0.10).contentShape(Rectangle()).onTapGesture { localPanel = nil; poke() }
                        CompactPlayerPopup(title: panel.title, scrolls: ![.episodes, .danmakuList, .danmakuConfiguration].contains(panel), close: { localPanel = nil; poke() }) {
                            localPanelContent(panel)
                        }
                        .accessibilityIdentifier("player.popup." + panel.rawValue)
                        .frame(width: panelSize.width, height: panelSize.height)
                        .clipped()
                        .frame(maxWidth: .infinity, maxHeight: availableHeight, alignment: .trailing)
                        .padding(.trailing, 12)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.colorScheme, .dark)
                        .environment(\.usesLocalDock, false)
                        .environment(\.localDockInset, 0)
                        .transition(.opacity)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            keyboardTop = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.minY
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardTop = nil }
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: localPanel)
        .clipped()
        .zIndex(20)
    }

    private func popupHeight(_ panel: LocalPlayerPanel) -> CGFloat {
        switch panel {
        case .cast: 430
        case .speed: 260
        case .volume: 180
        case .aspect: 410
        default: 520
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 3) {
            let previous = store.step(back: true, from: channel, session: session)
            let next = store.step(back: false, from: channel, session: session)
            Button { previous?.go(); poke() } label: { Image(systemName: "backward.end.fill").playerControlTarget() }
                .disabled(previous == nil || previous?.busy == true).accessibilityLabel("上一集")
                .accessibilityIdentifier("player.previous")
            Button { session.togglePlayback(); poke() } label: { Image(systemName: session.paused ? "play.fill" : "pause.fill").playerControlTarget() }
                .accessibilityLabel(session.paused ? "播放" : "暂停")
                .accessibilityIdentifier("player.playPause")
            Button { next?.go(); poke() } label: { Image(systemName: "forward.end.fill").playerControlTarget() }
                .disabled(next == nil || next?.busy == true).accessibilityLabel("下一集")
                .accessibilityIdentifier("player.next")
            Button { togglePanel(.speed) } label: { Text(Self.speedLabel(speed)).font(.system(size: 17, weight: .semibold)).playerControlTarget() }
                .accessibilityLabel("倍速")
                .accessibilityIdentifier("player.panel.speed").disabled(session.isLive)
            Button { togglePanel(.volume) } label: {
                Image(systemName: session.engine.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").playerControlTarget()
            }.accessibilityLabel("音量").accessibilityIdentifier("player.panel.volume")
        }.buttonStyle(PlayerToolbarButtonStyle())
    }

    private var panelButtons: some View {
        HStack(spacing: 3) {
            ForEach(availablePanels) { panel in
                Button { togglePanel(panel) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: panel.symbol).font(.system(size: 24))
                        if playerSize.width >= 760 { Text(panel.title).font(.system(size: 15)) }
                    }
                    .padding(.horizontal, playerSize.width >= 760 ? 7 : 0).playerControlTarget()
                }.buttonStyle(PlayerToolbarButtonStyle(selected: localPanel == panel)).accessibilityLabel(panel.title)
                    .accessibilityIdentifier("player.panel." + panel.rawValue)
            }
        }
    }

    private var availablePanels: [LocalPlayerPanel] {
        var panels: [LocalPlayerPanel] = [.episodes, .quality, .video, .audio, .subtitle, .danmaku]
        if !session.engine.chapters.isEmpty || !session.discTitles.isEmpty { panels.append(.chapters) }
        if channel.skipScope != nil && !session.isLive { panels.append(.skip) }
        return panels
    }

    @ViewBuilder private func localPanelContent(_ panel: LocalPlayerPanel) -> some View {
        switch panel {
        case .cast: castingPanel
        case .aspect: PlayerAspectPanel(value: $videoAspect) { localPanel = nil; poke() }
        case .speed: speedPanel
        case .volume: volumePanel
        case .information: CompactPlayerInformationPanel(session: session, channel: channel)
        case .episodes: CompactPlayerQueuePanel(channel: channel)
        case .quality: qualityPanel
        case .video: trackChoices(.video)
        case .audio: audioPanel
        case .subtitle: subtitlesPanel
        case .danmaku: danmakuPanel
        case .chapters: chaptersPanel
        case .skip: CompactEpisodeSkipPanel(session: session)
        case .subtitleAddress: CompactSubtitleAddressPanel(subtitles: session.externalSubtitles) { localPanel = .subtitle }
        case .danmakuList: embeddedDanmakuList
        case .danmakuConfiguration: danmakuConfigurationPanel
        }
    }

    private var castingPanel: some View {
        CompactPlayerCastingPanel(channel: channel, session: session, browser: tvBrowser) { receiver in
            session.engine.pause(); playingOn = receiver; localPanel = nil; poke()
        }
    }

    private var speedPanel: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(Self.speeds, id: \.self) { value in
                WithPerceptionTracking {
                    Button { speed = value; session.setSpeed(value); localPanel = nil; poke() } label: {
                        Text(Self.speedLabel(value)).font(.system(size: 13, weight: .medium).monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            .background(speed == value ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityAddTraits(speed == value ? [.isSelected] : [])
                }
            }
        }
    }

    private var volumePanel: some View {
        WithPerceptionTracking {
            VStack(spacing: 12) {
                HStack {
                    Button { session.engine.setMuted(!session.engine.muted) } label: {
                        Image(systemName: session.engine.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").playerControlTarget()
                    }.buttonStyle(.plain).accessibilityLabel(session.engine.muted ? "取消静音" : "静音")
                    Spacer()
                    Text("\(Int(session.engine.volume * 100))%").monospacedDigit()
                }
                Slider(value: playbackVolume, in: 0...1).accessibilityLabel("播放音量")
            }
        }
    }
    private var playbackVolume: Binding<Double> {
        Binding(get: { Double(session.engine.volume) }, set: { value in
            session.engine.setVolume(Float(value)); if value > 0 { session.engine.setMuted(false) }
        })
    }

    private var qualityPanel: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 12) {
                if session.qualities.isEmpty { Text("当前媒体没有可选画质。").font(.caption).foregroundStyle(.secondary) }
                else {
                    selectionRow("自动选择", selected: session.quality == nil) { session.choose(quality: nil) }
                    ForEach(session.qualities) { quality in
                        WithPerceptionTracking { selectionRow(quality.label, selected: session.quality == quality.id) { session.choose(quality: quality.id) } }
                    }
                }
                decoderChoices
            }
        }
    }
    private var decoderChoices: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 12) {
                Text("视频解码").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(["auto", "hardware", "software"], id: \.self) { decoder in
                    WithPerceptionTracking {
                        selectionRow(decoder == "auto" ? "自动硬解" : decoder == "hardware" ? "VideoToolbox 硬解" : "软件解码", selected: session.engine.decoder == decoder) {
                            session.engine.setDecoder(decoder)
                        }
                    }
                }
                Text("当前解码：" + session.engine.currentDecoder).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 12) { trackChoices(.audio); audioTiming }
    }
    private var audioTiming: some View {
        WithPerceptionTracking {
            HStack {
                Text("声音时间")
                Text(String(format: "%+.1f s", session.engine.audioDelay)).monospacedDigit()
                Spacer(minLength: 2)
                Button { session.engine.setAudioDelay(session.engine.audioDelay - 0.1) } label: { Image(systemName: "minus").playerControlTarget() }.accessibilityLabel("声音提前 0.1 秒")
                Button { session.engine.setAudioDelay(session.engine.audioDelay + 0.1) } label: { Image(systemName: "plus").playerControlTarget() }.accessibilityLabel("声音延后 0.1 秒")
                Button { session.engine.setAudioDelay(0) } label: { Image(systemName: "arrow.counterclockwise").playerControlTarget() }.accessibilityLabel("重置声音时间")
            }.font(.system(size: 12)).buttonStyle(.plain)
        }
    }

    private var subtitlesPanel: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 12) {
                CompactPlayerTabs(names: ["轨道", "外观", "位置", "时间", "在线", "AI 字幕"], selected: $subtitleTab)
                subtitleTabContent
            }
        }
    }
    @ViewBuilder private var subtitleTabContent: some View {
        if subtitleTab == "轨道" { subtitleTracksPanel }
        else if subtitleTab == "在线" {
            LocalOnlineSubtitlePanel(session: session, channel: channel, target: $subtitleTarget) { target in
                subtitleTarget = target; subtitleTab = "轨道"
            }
        }
        else if subtitleTab == "AI 字幕" { LocalAISubtitlePlayerPanel(session: session) }
        else { CompactSubtitleStylePanel(section: subtitleTab, subtitles: session.externalSubtitles, engine: session.engine) }
    }
    private var subtitleTracksPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            subtitleTrackChoices(.primary)
            subtitleTrackChoices(.secondary)
            subtitleImportControls
        }
    }
    private func subtitleTrackChoices(_ target: SubtitleTrackSelection.Target) -> some View {
        WithPerceptionTracking {
            let current = session.engine.resolvedSubtitleSelection(target)
            let requested = target == .primary ? session.engine.subtitleSelection : session.engine.secondarySubtitleSelection
            let native = session.engine.tracks.filter { track in
                track.kind == .subtitle && !session.externalSubtitles.entries.contains { $0.id == track.id }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(target.title).font(.subheadline.bold())
                Text(subtitleSelectionLabel(current, requested: requested)).font(.caption).foregroundStyle(.secondary)
                if target == .secondary && (session.aiSubtitles.generate || session.aiSubtitles.translate) {
                    Text("AI 字幕优先显示；关闭 AI 字幕后显示所选副字幕轨道。").font(.caption).foregroundStyle(.secondary)
                }
                selectionRow("关闭" + target.title, selected: requested == "no") {
                    selectSubtitleTrack(nil, target: target, automatic: false)
                }
                selectionRow("自动选择内嵌字幕", selected: requested == nil) {
                    selectSubtitleTrack(nil, target: target, automatic: true)
                }
                ForEach(native) { track in
                    WithPerceptionTracking {
                        selectionRow(trackLabel(track), selected: current == track.id) {
                            selectSubtitleTrack(track.id, target: target)
                        }
                    }
                }
                ForEach(session.externalSubtitles.entries) { entry in
                    WithPerceptionTracking { externalSubtitleChoice(entry, target: target) }
                }
                if native.isEmpty && session.externalSubtitles.entries.isEmpty {
                    Text("当前没有可选择的字幕").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func subtitleSelectionLabel(_ id: String?, requested: String?) -> String {
        if let id, let entry = session.externalSubtitles.entries.first(where: { $0.id == id }) { return "当前：外挂 · " + entry.title }
        if let id, let track = session.engine.tracks.first(where: { $0.kind == .subtitle && $0.id == id }) {
            return "当前：" + (requested == nil ? "自动 · " : "内嵌 · ") + trackLabel(track)
        }
        return requested == "no" ? "当前：已关闭" : requested == nil ? "当前：自动（无可用内嵌字幕）" : "当前：所选字幕不可用"
    }
    private func selectSubtitleTrack(_ id: String?, target: SubtitleTrackSelection.Target, automatic: Bool = false) {
        if target == .primary { session.engine.selectSubtitle(id: automatic ? nil : id ?? "no") }
        else { session.engine.selectSecondarySubtitle(id: automatic ? nil : id ?? "no") }
        session.externalSubtitles.nativeChosen(target: target)
    }
    @ViewBuilder private func externalSubtitleChoice(_ entry: ExternalSubtitles.Entry, target: SubtitleTrackSelection.Target) -> some View {
        switch entry.state {
        case .ready:
            selectionRow("外挂 · " + entry.title, selected: session.externalSubtitles.selection(for: target) == entry.id) {
                session.externalSubtitles.select(entry.id, target: target)
            }
        case .loading: ProgressView("外挂 · " + entry.title)
        case .failed(let reason):
            Text(entry.title + "：" + reason).font(.caption).foregroundStyle(.orange)
            if entry.subtitle != nil {
                Button("重试并应用到" + target.title) {
                    session.externalSubtitles.importTarget = target; session.externalSubtitles.retry(entry.id)
                }
            }
        }
    }
    private var subtitleImportControls: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 12) {
                Picker("添加字幕到", selection: $subtitleTarget) {
                    ForEach(SubtitleTrackSelection.Target.allCases, id: \.self) { target in Text(target.title).tag(target) }
                }.pickerStyle(.segmented)
                Button {
                    session.externalSubtitles.importTarget = subtitleTarget
                    beginPlayerFileImport(.subtitle)
                } label: {
                    Label("本地字幕 → " + subtitleTarget.title, systemImage: "doc.text").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(CompactPlayerControlStyle())
                Button("从网址添加到" + subtitleTarget.title) {
                    session.externalSubtitles.importTarget = subtitleTarget; localPanel = .subtitleAddress
                }.buttonStyle(CompactPlayerControlStyle())
                if let issue = session.externalSubtitles.importFailure { Text(issue).font(.caption).foregroundStyle(.orange) }
                Text("外挂字幕可分别放入主字幕或副字幕；同一轨道只占一个位置。在线下载成功后返回对应轨道列表。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var danmakuPanel: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 12) {
                CompactPlayerTabs(names: ["来源", "花式弹幕", "外观", "时间", "密度"], selected: $danmakuTab)
                if danmakuTab == "来源" { danmakuSourcePanel }
                else { CompactDanmakuStylePanel(section: danmakuTab, model: session.catalogDanmaku) }
            }
        }
    }
    private var danmakuSourcePanel: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("显示弹幕", isOn: $showsDanmaku)
                Toggle("自动匹配弹幕", isOn: automaticDanmaku)
                Text(danmakuStatus).font(.caption).foregroundStyle(.secondary)
                if session.catalogDanmaku.automaticState == "unavailable" {
                    Button("重新加载弹幕") { session.catalogDanmaku.retryAutomatic() }.buttonStyle(.bordered)
                }
                LocalDanmakuCatalogPanel(enhancements: session.mediaEnhancements, model: session.catalogDanmaku,
                                         importFile: beginDanmakuImport, importing: importingDanmaku, importError: danmakuImportError,
                                         openConfiguration: { localPanel = .danmakuConfiguration })
                Button("弹幕列表") { localPanel = .danmakuList }.buttonStyle(.bordered)
            }
        }
    }
    private func beginDanmakuImport() {
        danmakuImportError = nil
        beginPlayerFileImport(.danmaku)
    }
    private enum PlayerFileKind {
        case subtitle, danmaku
        var documentKind: LocalDocumentSelectionKind {
            switch self {
            case .subtitle: .subtitleFile
            case .danmaku: .danmakuFile
            }
        }
    }
    private func beginPlayerFileImport(_ kind: PlayerFileKind) {
        guard !importsPlayerFile else { return }
        playerFileKind = kind
        playerFileSession = session.mediaEnhancements.sessionID
        if kind == .subtitle { session.externalSubtitles.importFailure = nil }
        importsPlayerFile = true
    }
    private func receivePlayerFile(_ result: Result<LocalDocumentSelection, Error>) {
        importsPlayerFile = false
        guard playerFileSession == session.mediaEnhancements.sessionID else {
            if case .success(let selection) = result { selection.release() }
            return
        }
        if case .failure(let error) = result {
            if playerFileKind == .subtitle { session.externalSubtitles.importFailure = error.localizedDescription }
            else { danmakuImportError = error.localizedDescription }
            return
        }
        guard case .success(let selection) = result else { return }
        switch playerFileKind {
        case .subtitle:
            session.externalSubtitles.add(selection: selection)
        case .danmaku:
            danmakuImportSession = playerFileSession
            receiveDanmakuFile(selection)
        }
    }
    private func receiveDanmakuFile(_ selection: LocalDocumentSelection) {
        guard danmakuImportSession == session.mediaEnhancements.sessionID else { selection.release(); return }
        let active = danmakuImportSession
        let operation = UUID(); danmakuImportID = operation
        danmakuImportWork?.cancel(); importingDanmaku = true
        danmakuImportWork = Task {
            defer { selection.release() }
            defer { if active == session.mediaEnhancements.sessionID, danmakuImportID == operation { importingDanmaku = false; danmakuImportWork = nil } }
            do {
                let data = try await selection.readData(maxBytes: 32 * 1024 * 1024)
                try Task.checkCancellation()
                guard active == session.mediaEnhancements.sessionID, danmakuImportID == operation else { return }
                try await session.mediaEnhancements.importData(data)
                try Task.checkCancellation()
                guard active == session.mediaEnhancements.sessionID, danmakuImportID == operation else { return }
                danmakuTab = "来源"; localPanel = .danmaku
            } catch {
                if !Task.isCancelled && active == session.mediaEnhancements.sessionID && danmakuImportID == operation { danmakuImportError = error.localizedDescription }
            }
        }
    }
    private var automaticDanmaku: Binding<Bool> {
        Binding(get: { session.catalogDanmaku.automatic }, set: { session.catalogDanmaku.automatic = $0 })
    }
    private var danmakuStatus: String {
        guard showsDanmaku else { return "弹幕已关闭" }
        let status = session.mediaEnhancements.status
        if !status.isEmpty { return status }
        return session.catalogDanmaku.automaticState == "searching" ? "正在匹配弹幕…" : "已加载 \(session.danmaku.count) 条弹幕"
    }
    private var embeddedDanmakuList: some View {
        DanmakuListView(engine: session.engine, comments: session.danmaku, embedded: true) { localPanel = .danmaku; poke() }
    }
    private var danmakuConfigurationPanel: some View {
        ConfigCenterView(address: { await NativeDanmakuCatalog(context: session.catalogDanmaku.context).configurationWebsite() },
                         embedded: true, close: { localPanel = .danmaku; poke() })
    }

    private var chaptersPanel: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 12) {
                if !session.discTitles.isEmpty { discTitleChoices }
                if session.engine.chapters.isEmpty { Text("当前媒体没有可用章节").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(session.engine.chapters) { chapter in
                    WithPerceptionTracking {
                        selectionRow(chapterLabel(chapter), selected: currentChapterID == chapter.id) {
                            clock.seek(to: chapter.start); sought()
                        }
                    }
                }
            }
        }
    }
    private var discTitleChoices: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 12) {
                LocalGlassChoicePicker(title: "原盘标题", selection: discTitleSelection,
                                       options: session.discTitles.enumerated().map { index, title in
                                           LocalGlassChoice(title.playlist, discTitleLabel(title, index: index))
                                       }).disabled(session.selectingDiscTitle)
                if session.selectingDiscTitle { ProgressView("正在打开原盘标题…") }
            }
        }
    }
    private var discTitleSelection: Binding<UInt32> {
        Binding(get: { session.selectedDiscPlaylist ?? session.discTitles.first?.playlist ?? 0 }, set: { session.selectDiscTitle($0) })
    }
    private var currentChapterID: Int? { session.engine.chapters.last { $0.start <= clock.position }?.id }
    private func chapterLabel(_ chapter: KSPlaybackChapter) -> String {
        var time = EpisodeSkipSettings.formatTime(chapter.start)
        if let end = chapter.end, end > chapter.start { time += " / " + EpisodeSkipSettings.formatTime(end - chapter.start) }
        return String(format: "%02d", chapter.id + 1) + "  " + chapter.title + " · " + time
    }
    private func discTitleLabel(_ title: DiscPlaybackTitle, index: Int) -> String {
        var parts = [index == 0 ? "默认标题" : "标题 \(index + 1)", EpisodeSkipSettings.formatTime(title.duration)]
        if let count = title.chapterCount { parts.append("\(count) 章") }
        parts.append(String(format: "%05d", title.playlist))
        return parts.joined(separator: " · ")
    }

    private func trackChoices(_ kind: KSPlaybackTrack.Kind) -> some View {
        WithPerceptionTracking {
            let options = session.engine.tracks.filter { $0.kind == kind }
            let selection = kind == .video ? session.engine.videoSelection : kind == .audio ? session.engine.audioSelection : session.engine.subtitleSelection
            VStack(spacing: 2) {
                if kind != .subtitle {
                    selectionRow("自动选择", selected: selection == nil) { selectTrack(kind, id: nil) }
                }
                selectionRow(kind == .video ? "关闭视轨" : kind == .audio ? "关闭音轨" : "关闭字幕", selected: (selection == "no" || kind == .subtitle && selection == nil && !options.contains(where: \.selected)) && (kind != .subtitle || session.externalSubtitles.selected == nil)) {
                    if kind == .subtitle { session.externalSubtitles.select(nil) }
                    selectTrack(kind, id: "no")
                }
                ForEach(options) { option in
                    WithPerceptionTracking {
                        selectionRow(trackLabel(option), selected: (selection == option.id || kind == .subtitle && selection == nil && option.selected) && (kind != .subtitle || session.externalSubtitles.selected == nil)) {
                            selectTrack(kind, id: option.id)
                            if kind == .subtitle { session.externalSubtitles.nativeChosen() }
                        }
                    }
                }
                if options.isEmpty { Text("当前媒体没有可选择的" + (kind == .video ? "视频轨道" : kind == .audio ? "音轨" : "内嵌字幕")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }

    private func selectTrack(_ kind: KSPlaybackTrack.Kind, id: String?) {
        switch kind {
        case .video: session.engine.selectVideo(id: id)
        case .audio: session.engine.selectAudio(id: id)
        case .subtitle: session.engine.selectSubtitle(id: id)
        }
    }

    private func trackLabel(_ track: KSPlaybackTrack) -> String {
        var values = [track.title, track.codec, track.language].compactMap { $0 }.filter { !$0.isEmpty }
        if let width = track.width, let height = track.height, width > 0, height > 0 { values.append("\(width) × \(height)") }
        return values.joined(separator: " · ")
    }

    private func selectionRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); if selected { Image(systemName: "checkmark") } }
                .font(.system(size: 14)).padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(CompactPlayerControlStyle(selected: selected, inset: false))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .disabled(session.loading)
    }

    /// The position moved by a button or the seek bar: the Lock Screen follows.
    private func sought() {
        poke()
        nowPlaying.update(title: channel.name, session: session)
    }

    private func attachPictureInPicture() {
        pip.attach(engine: session.engine)
        // The cover is gone during PiP. Close the shared session and its catalog
        // selection directly instead of calling a dismissed view's dismiss().
        pip.onClose = { [weak session, weak store] in
            let closingID = session?.activeChannelID
            session?.stop()
            if store?.playing?.id == closingID { store?.playing = nil }
        }
    }

    private var pipPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "pip").font(.system(size: 48, weight: .light))
            Text(L10n.text("Playing in Picture in Picture")).font(.callout)
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .playerBleed(!inline)
    }
}

/// The top of an iPhone watch page before the picture: the cover filling the width, blurred, under a spinner.
/// While nothing is starting, the whole cover shows clear over that blur.
struct WatchCoverBackdrop: View {
    let poster: URL?
    var headers: [String: String] = [:]
    var loading = true
    var clear = false
    /// What the wait has to say, by how long it has run (see `WaitSpinner`).
    var status: (@MainActor (TimeInterval) -> PlaybackWait)? = nil
    @State private var aspect: CGFloat?
    var body: some View {
        WithPerceptionTracking {
            ZStack {
                Color.black
                PosterImage(url: poster, headers: headers)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .blur(radius: 24).scaleEffect(1.2)
                    .overlay(Color.black.opacity(0.35))
                    .accessibilityHidden(true)
                if clear, poster != nil {
                    PosterImage(url: poster, headers: headers, aspect: $aspect)
                        .aspectRatio(aspect ?? 2.0 / 3, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                        .padding(.vertical, 14)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
                if loading { WaitSpinner(status: status) }
            }
            .animation(.easeOut(duration: 0.3), value: clear)
            .clipped()
        }
    }
}

/// A spinner first; once the wait has run `PlaybackWait.detailsAfter`, its line and small print along the bottom,
/// so the spinner stays where it was.
struct WaitSpinner: View {
    var status: (@MainActor (TimeInterval) -> PlaybackWait)?
    @State private var started = Date()
    var body: some View {
        WithPerceptionTracking {
            ZStack {
                ProgressView().controlSize(.large).tint(.white)
                if let status {
                    TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                        WithPerceptionTracking {
                            let elapsed = max(0, timeline.date.timeIntervalSince(started))
                            let speaks = elapsed >= PlaybackWait.detailsAfter
                            VStack(spacing: 5) {
                                if speaks {
                                    let wait = status(elapsed)
                                    Text(wait.message).font(.footnote.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                                    WaitDetails(detail: wait.detail, steps: Array(wait.steps.suffix(2)))
                                }
                            }
                            .padding(.horizontal, 24).padding(.bottom, 12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .animation(.appSmooth(duration: 0.45), value: speaks)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Where the iPhone and iPad player is drawn.
enum MobilePlayerLayout {
    /// A screen of its own (the full-screen player).
    case screen
    /// The top of an iPhone watch page, under the status bar.
    case inline
    /// A watch page's player filling the screen; Back returns to the page.
    case pageFullScreen
}

/// The player at the top of an iPhone watch page (`VideoDetailView`).
struct WatchPlayback {
    /// Filling the screen, or at the top of the page.
    var fullScreen: Bool
    /// Full Screen, or back to the page. True when the picture is wider than tall, so the phone turns.
    var toggleFullScreen: (_ landscape: Bool) -> Void
    /// Back, out of the page.
    var leave: () -> Void
    /// The picture, or an error, has taken the place of the wait: the page's cover can go.
    var started: (Bool) -> Void = { _ in }
    /// The page's player, so the cover over it can say how its wait goes.
    var opened: (PlaybackSession) -> Void = { _ in }
}

/// Playback controls and their presented panels keep a consistent dark appearance.
struct PlayerScheme: ViewModifier {
    let ownsScreen: Bool
    func body(content: Content) -> some View {
        content.environment(\.colorScheme, .dark)
    }
}

extension View {
    /// Under the status bar and the home indicator on a screen of its own; inside its frame at the top of a page,
    /// where reaching into the safe area would run the picture under the status bar. Keep one structural
    /// view identity across full-screen changes so KSPlayer's mounted surface and PiP source survive.
    func playerBleed(_ bleeds: Bool, edges: Edge.Set = .all) -> some View {
        ignoresSafeArea(edges: bleeds ? edges : [])
    }
}

/// The position and the length in a capsule over a scrubber the width of the screen, as in YouTube's player, and
/// scrubbing as in Telegram's: while dragged, only the bar, the time and a frame from that point (above the handle)
/// follow the finger, and the video seeks once, when the finger lifts. Seeking the playing video along with the finger
/// left it stuttering behind. A view of its own, so only it redraws as the position moves.
private struct SeekBar<Accessory: View>: View {
    /// The time row leaves room for accessible episode-button targets.
    static var timeRow: CGFloat { 44 }
    let clock: PlayerClock
    /// Playing with the controls showing: the bar follows the player every frame.
    let moving: Bool
    let hold: (Bool) -> Void
    let sought: () -> Void
    /// At the right of the time: the episode buttons.
    @ViewBuilder let accessory: () -> Accessory
    /// Where a drag began: the position then and the finger's start. The handle moves by as much as the finger does
    /// (Telegram), rather than jumping under it; a touch away from the handle puts it there first.
    @State private var drag: (position: Double, location: CGPoint)?
    /// Slower scrubbing while the finger moves away from the bar: half, a quarter and a tenth of the speed (Telegram).
    @State private var fineness = 1.0
    @State private var width: CGFloat = 0

    var body: some View {
        WithPerceptionTracking {
            // Every display frame while it plays, as AVKit's bar does; paused, held or hidden, only when the clock changes.
            let follows = moving && clock.scrubbing == nil
            TimelineView(.animation(paused: !follows)) { _ in
                WithPerceptionTracking {
                    bar(clock.scrubbing ?? (follows ? clock.currentPosition : clock.position))
                }
            }
            // Outside the bar, which is one accessibility element. Gone while scrubbing, when the time grows with the
            // scrubbing speed's label and the finger is there to scrub.
            .overlay(alignment: .topTrailing) {
                WithPerceptionTracking {
                    if drag == nil { accessory().frame(height: Self.timeRow).transition(.opacity) }
                }
            }
            .animation(.easeOut(duration: 0.15), value: drag == nil)
            .appOnChange(of: fineness) { UISelectionFeedbackGenerator().selectionChanged() }
        }
    }

    private func bar(_ position: Double) -> some View {
        let duration = clock.duration
        let value = min(max(0, position), duration)
        let held = drag != nil
        return HStack(spacing: 8) {
            Text(Self.format(value)).frame(minWidth: 40, alignment: .leading).accessibilityHidden(true)
            GeometryReader { viewport in
                let trackWidth = viewport.size.width
                let x = duration > 0 ? trackWidth * value / duration : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2)).frame(height: held ? 6 : 4)
                    Capsule().fill(.white.opacity(0.4)).frame(width: duration > 0 ? max(0, min(trackWidth, trackWidth * clock.bufferedPosition / duration)) : 0, height: held ? 6 : 4)
                    Capsule().fill(.white).frame(width: max(0, x), height: held ? 6 : 4)
                    Circle().fill(.white)
                        .frame(width: held ? 24 : 14, height: held ? 24 : 14)
                        .shadow(color: .black.opacity(0.35), radius: 3)
                        .offset(x: x - (held ? 12 : 7))
                }
                .frame(width: trackWidth, height: viewport.size.height)
                .overlay(alignment: .topLeading) {
                    WithPerceptionTracking {
                        if held, let preview = clock.preview {
                            let size = PlaybackThumbnailLayout.size(imageWidth: preview.width,
                                imageHeight: preview.height, availableWidth: trackWidth)
                            Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                                .frame(width: size.width, height: size.height).fixedSize()
                                .background(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.8), lineWidth: 1))
                                .shadow(color: .black.opacity(0.4), radius: 6)
                                .alignmentGuide(.top) { $0[.bottom] + 8 }
                                .offset(x: PlaybackThumbnailLayout.origin(trackWidth: trackWidth,
                                    imageWidth: size.width, progress: duration > 0 ? value / duration : 0))
                                .transition(.opacity)
                                .allowsHitTesting(false)
                                .accessibilityLabel("进度预览").accessibilityIdentifier("player.thumbnail")
                        }
                    }
                }
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay {
                PlayerSeekGestures(changed: { changed($0, value: value, duration: duration) },
                                   ended: { released($0, value: value, duration: duration) },
                                   tapped: { tapped($0, duration: duration) })
                    .accessibilityHidden(true)
            }
            .animation(.appSpring(duration: 0.3, bounce: 0.3), value: held)
            Text(Self.format(duration)).frame(minWidth: 40, alignment: .trailing).accessibilityHidden(true)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .animation(.easeOut(duration: 0.12), value: held && clock.preview != nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Playback Position"))
        .accessibilityValue(Self.format(value))
        .accessibilityIdentifier("player.seek")
        .accessibilityAdjustableAction { direction in
            clock.seek(to: min(max(0, value + (direction == .increment ? 10 : -10)), duration))
            sought()
        }
    }

    private func changed(_ gesture: PlayerSeekGestures.Value, value: Double, duration: Double) {
        guard duration > 0, width > 0 else { return }
        #if DEBUG
        Diagnostics.shared.record(.debug, "player.gesture", "stage=changed startX=\(gesture.startLocation.x) x=\(gesture.location.x) y=\(gesture.location.y) width=\(width) fineness=\(fineness) value=\(value)")
        #endif
        if drag == nil {
            // UIKit refuses a vertical start before it consumes scroll touches;
            // also protect this callback from a stale or misclassified sequence.
            let dx = abs(gesture.location.x - gesture.startLocation.x)
            let dy = abs(gesture.location.y - gesture.startLocation.y)
            guard dx > dy * 1.2 else { return }
            let handle = width * value / duration
            let start = abs(gesture.startLocation.x - handle) <= 30 ? value : duration * Double(min(max(0, gesture.startLocation.x / width), 1))
            drag = (start, gesture.startLocation)
            hold(true)
            clock.scrub(to: start)
        }
        guard let begin = drag else { return }
        // Sensitivity is measured from the original track, while `drag` may
        // move its anchor each time sensitivity changes to prevent a jump.
        let away = abs(gesture.location.y - gesture.startLocation.y)
        let wanted = away > 150 ? 0.1 : away > 100 ? 0.25 : away > 50 ? 0.5 : 1
        if wanted != fineness {
            // Carry on from here at the new speed, so the handle doesn't jump.
            fineness = wanted
            drag = (clock.scrubbing ?? begin.position, gesture.location)
            return
        }
        let moved = Double((gesture.location.x - begin.location.x) / width) * duration * fineness
        clock.scrub(to: min(max(0, begin.position + moved), duration))
    }

    private func released(_ gesture: PlayerSeekGestures.Value?, value: Double, duration: Double) {
        guard drag != nil else { return }
        if let gesture {
            // Coalesced moves can deliver the final position only on touch-up.
            changed(gesture, value: value, duration: duration)
            ended()
        } else {
            drag = nil
            fineness = 1
            hold(false)
            clock.cancelScrub()
        }
    }

    private func tapped(_ location: CGPoint, duration: Double) {
        guard drag == nil, duration > 0, width > 0 else { return }
        clock.seek(to: duration * Double(min(max(0, location.x / width), 1)))
        sought()
    }

    private func ended() {
        guard drag != nil else { return }
        drag = nil
        fineness = 1
        hold(false)
        clock.endScrub()
        sought()
    }

    private static func fineLabel(_ fineness: Double) -> String? {
        switch fineness {
        case 0.5: L10n.text("Half-Speed Scrubbing")
        case 0.25: L10n.text("Quarter-Speed Scrubbing")
        case ..<0.25: L10n.text("Fine Scrubbing")
        default: nil
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(0, seconds) : 0)
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// The top row's three parts: Back, the title and the buttons. All in one row while the title keeps `minimumTitle`;
/// otherwise Back and the buttons share the first row and the title has the next one to itself. On a screen too
/// narrow even for Back beside the buttons, the buttons take the first row alone and Back goes beside the title.
private struct PlayerTopBar: SwiftUI.Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 10
    var minimumTitle: CGFloat = 160

    private enum Arrangement { case oneRow, titleBelow, buttonsAlone }

    private func arrangement(_ width: CGFloat, back: CGSize, buttons: CGSize) -> Arrangement {
        if back.width + spacing + minimumTitle + spacing + buttons.width <= width { return .oneRow }
        return back.width + spacing + buttons.width <= width ? .titleBelow : .buttonsAlone
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let back = subviews[0].sizeThatFits(.unspecified), buttons = subviews[2].sizeThatFits(.unspecified)
        let width = proposal.width ?? back.width + subviews[1].sizeThatFits(.unspecified).width + buttons.width + 2 * spacing
        func title(_ room: CGFloat) -> CGSize { subviews[1].sizeThatFits(ProposedViewSize(width: room, height: nil)) }
        switch arrangement(width, back: back, buttons: buttons) {
        case .oneRow:
            let title = title(width - back.width - buttons.width - 2 * spacing)
            return CGSize(width: width, height: max(back.height, buttons.height, title.height))
        case .titleBelow:
            return CGSize(width: width, height: max(back.height, buttons.height) + rowSpacing + title(width).height)
        case .buttonsAlone:
            return CGSize(width: width, height: buttons.height + rowSpacing + max(back.height, title(width - back.width - spacing).height))
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let back = subviews[0].sizeThatFits(.unspecified), buttons = subviews[2].sizeThatFits(.unspecified)
        /// Places a subview with its vertical centre at `middle`; the title gets `room` and truncates to it.
        func place(_ index: Int, x: CGFloat, middle: CGFloat, room: CGFloat? = nil) {
            let size = room.map { subviews[index].sizeThatFits(ProposedViewSize(width: $0, height: nil)) } ?? subviews[index].sizeThatFits(.unspecified)
            subviews[index].place(at: CGPoint(x: x, y: middle - size.height / 2), proposal: ProposedViewSize(width: size.width, height: size.height))
        }
        switch arrangement(bounds.width, back: back, buttons: buttons) {
        case .oneRow:
            place(0, x: bounds.minX, middle: bounds.midY)
            place(1, x: bounds.minX + back.width + spacing, middle: bounds.midY, room: bounds.width - back.width - buttons.width - 2 * spacing)
            place(2, x: bounds.maxX - buttons.width, middle: bounds.midY)
        case .titleBelow:
            let row = max(back.height, buttons.height)
            place(0, x: bounds.minX, middle: bounds.minY + row / 2)
            place(2, x: bounds.maxX - buttons.width, middle: bounds.minY + row / 2)
            let title = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            place(1, x: bounds.minX, middle: bounds.minY + row + rowSpacing + title.height / 2, room: bounds.width)
        case .buttonsAlone:
            place(2, x: bounds.maxX - buttons.width, middle: bounds.minY + buttons.height / 2)
            let room = bounds.width - back.width - spacing
            let row = max(back.height, subviews[1].sizeThatFits(ProposedViewSize(width: room, height: nil)).height)
            let middle = bounds.minY + buttons.height + rowSpacing + row / 2
            place(0, x: bounds.minX, middle: middle)
            place(1, x: bounds.minX + back.width + spacing, middle: middle, room: room)
        }
    }
}

/// A round glass button of the given size, for play and skip in the middle of the picture.
private struct PlayerCircleStyle: ButtonStyle {
    var size: CGFloat
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        WithPerceptionTracking {
            configuration.label
                .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .glassSurface(.regular.interactive(), in: Circle())
                .contentShape(Circle())
                .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
                // Gives under the finger, so a tap shows before the player answers.
                .scaleEffect(configuration.isPressed && size >= 50 ? 0.9 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
        }
    }
}

/// The picture's own gestures, in UIKit: taps, a touch and hold followed while the finger moves, slides and a pinch.
/// SwiftUI's long press ends where a drag would begin, and a tap beside it can fire as the held finger lifts.
private struct PictureGestures: UIViewRepresentable {
    enum Hold { case began, moved(CGSize), ended }
    /// Sideways seeks; up or down sets the brightness in the left third, steps
    /// episodes in the middle third and sets the volume in the right third.
    enum Slide { case seek, brightness, volume, episode }
    enum Swipe { case began(Slide), moved(CGSize, in: CGSize), ended }
    /// Where the tap landed across the picture, and the picture's width.
    let tap: (CGFloat, CGFloat) -> Void
    let hold: (Hold) -> Void
    let swipe: (Swipe) -> Void
    /// Whether slides up or down set the brightness and the volume.
    var levels = true
    /// Pinched out (true) or in, as in YouTube: fill the screen or fit the picture.
    let pinch: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        press.minimumPressDuration = 0.35
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        // A touch that lifts before the hold begins is a tap, at once; each tap of a double tap comes on its own.
        tap.require(toFail: press)
        // A finger that moves before the hold begins slides instead.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        for recognizer in [press, tap, pan, pinch] { view.addGestureRecognizer(recognizer) }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PictureGestures?
        private var start = CGPoint.zero
        private var slide = Slide.seek

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let view = tap.view else { return }
            parent?.tap(tap.location(in: view).x, view.bounds.width)
        }

        @objc func pressed(_ press: UILongPressGestureRecognizer) {
            let location = press.location(in: press.view)
            switch press.state {
            case .began: start = location; parent?.hold(.began)
            case .changed: parent?.hold(.moved(CGSize(width: location.x - start.x, height: location.y - start.y)))
            case .ended, .cancelled, .failed: parent?.hold(.ended)
            default: break
            }
        }

        @objc func panned(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view else { return }
            switch pan.state {
            case .began: parent?.swipe(.began(slide))
            case .changed:
                let moved = pan.translation(in: view)
                parent?.swipe(.moved(CGSize(width: moved.x, height: moved.y), in: view.bounds.size))
            case .ended, .cancelled, .failed: parent?.swipe(.ended)
            default: break
            }
        }

        @objc func pinched(_ pinch: UIPinchGestureRecognizer) {
            guard pinch.state == .ended, abs(pinch.scale - 1) > 0.1 else { return }
            parent?.pinch(pinch.scale > 1)
        }

        /// Sideways anywhere; up or down only away from the edges that Notification Center, Control Center and the
        /// Home indicator use.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
            let velocity = pan.velocity(in: view)
            if abs(velocity.x) > abs(velocity.y) { slide = .seek; return true }
            let location = pan.location(in: view)
            guard parent?.levels == true, PictureLevel.slides(fromY: location.y, height: view.bounds.height) else { return false }
            // Thirds: brightness | episodes | volume. (This used to split the
            // width in half between brightness and volume; the middle third is
            // the episode zone Sam asked for.)
            let third = view.bounds.width / 3
            slide = location.x < third ? .brightness : location.x > third * 2 ? .volume : .episode
            return true
        }
    }
}

/// Mount the actual active KSPlayer picture. Ratio changes resize this one surface; audio stays in the session.
private struct KSPlayerSurface: UIViewRepresentable {
    let engine: KSPlaybackEngine
    let aspect: PlayerVideoAspect
    // iOS 16 Perception tracks the surrounding body, not updateUIView. A value
    // input makes asynchronous core/view replacement invalidate this host too.
    let revision: UUID
    final class Host: UIView {
        weak var engine: KSPlaybackEngine?
        var aspect = PlayerVideoAspect()
        private weak var picture: UIView?
        private var claimsPicture = false
        func update(engine: KSPlaybackEngine, aspect: PlayerVideoAspect) {
            if self.engine !== engine { claimsPicture = false }
            self.engine = engine; self.aspect = aspect
            let current = engine.renderView
            if picture !== current {
                if picture?.superview === self { picture?.removeFromSuperview() }
                picture = current
            }
            layoutPicture()
        }
        private func layoutPicture() {
            guard window != nil, bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width > 0, bounds.height > 0, let engine else { return }
            let current = engine.renderView
            if picture !== current {
                if picture?.superview === self { picture?.removeFromSuperview() }
                picture = current
            }
            guard let picture else { return }
            // Mounting a new host transfers ownership once. An older host that is
            // still mounted behind a presentation must not steal the view back.
            if picture.superview !== self {
                guard !claimsPicture || picture.superview == nil else { return }
                picture.removeFromSuperview(); addSubview(picture)
            }
            let newlyMounted = !claimsPicture
            claimsPicture = true
            if picture.contentMode != aspect.contentMode { engine.setContentMode(aspect.contentMode) }
            let frame = aspect.frame(in: bounds.size)
            PlayerSurfaceLayout.apply(frame: frame, to: picture)
            engine.attachPictureInPicture(to: self)
            if newlyMounted { PictureInPicture.shared.surfaceMounted(engine: engine) }
        }
        private func unmountPicture() {
            if picture?.superview === self { picture?.removeFromSuperview() }
            claimsPicture = false
        }
        func dismantle() {
            engine?.detachPictureInPicture(from: self)
            unmountPicture()
            picture = nil; engine = nil
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                unmountPicture()
            } else if let engine { update(engine: engine, aspect: aspect) }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            // Preparation legitimately has no native view yet. Layout may size
            // or mount an existing picture, but must never request another pass.
            layoutPicture()
        }
    }
    func makeUIView(context: Context) -> Host {
        let view = Host(); view.backgroundColor = .black; view.clipsToBounds = true
        // The sibling PictureGestures view owns interaction; native render
        // views (including replacement KS cores) must never take a control tap.
        view.isUserInteractionEnabled = false
        view.update(engine: engine, aspect: aspect); return view
    }
    func updateUIView(_ view: Host, context: Context) {
        view.update(engine: engine, aspect: aspect)
    }
    static func dismantleUIView(_ view: Host, coordinator: ()) {
        view.dismantle()
    }
}

/// Delegates PiP to the same KS core that owns the picture and playback clock.
@MainActor @Perceptible final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PictureInPicture()
    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    private(set) var possible = false
    private(set) var active = false
    private(set) var starting = false
    private(set) var transition = PlaybackPiPTransition()
    @PerceptionIgnored var onClose: (() -> Void)?
    var busy: Bool { starting || active || transition.preservesSessionOnDismiss || controller?.isPictureInPictureActive == true }
    var hidesPlayer: Bool { transition.hidesPlayer }
    var preservesSessionOnDismiss: Bool { transition.preservesSessionOnDismiss }
    let composited = true
    @PerceptionIgnored private weak var engine: KSPlaybackEngine?
    @PerceptionIgnored private weak var controller: AVPictureInPictureController?
    @PerceptionIgnored private var observation: NSKeyValueObservation?
    @PerceptionIgnored private var activeObservation: NSKeyValueObservation?
    @PerceptionIgnored private var attachment = UUID()
    @PerceptionIgnored private var restoreCompletion: ((Bool) -> Void)?
    func attach(engine: KSPlaybackEngine) {
        self.engine = engine
        guard let next = engine.pipController else {
            attachment = UUID(); observation = nil; activeObservation = nil
            controller?.delegate = nil; controller = nil
            possible = false; active = false; starting = false; transition.cancelled()
            restoreCompletion?(false); restoreCompletion = nil
            PlaybackSession.sharedLocal.pictureInPictureActive = false
            return
        }
        guard controller !== next else { return }
        let cancelledRestore = restoreCompletion
        restoreCompletion = nil
        starting = false; transition.cancelled()
        cancelledRestore?(false)
        controller?.delegate = nil
        controller = next
        let identity = UUID(); attachment = identity
        possible = next.isPictureInPicturePossible
        active = false
        engine.setPictureInPictureActive(next.isPictureInPictureActive)
        PlaybackSession.sharedLocal.pictureInPictureActive = next.isPictureInPictureActive
        next.canStartPictureInPictureAutomaticallyFromInline = false
        // Playback commands stay with the KS sample-buffer delegate; this delegate restores the screen.
        next.delegate = self
        observation = next.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] value, _ in
            let possible = value.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                guard let self, self.attachment == identity,
                      self.controller === self.engine?.pipController else { return }
                self.possible = possible
            }
        }
        activeObservation = next.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] value, _ in
            let active = value.isPictureInPictureActive
            Task { @MainActor [weak self] in
                guard let self, self.attachment == identity,
                      self.controller === self.engine?.pipController,
                      self.controller?.isPictureInPictureActive == active else { return }
                // KVO describes AVKit's internal state, including the start/stop
                // animations. Do not dismantle or restore a source from it.
                if active {
                    self.engine?.setPictureInPictureActive(true)
                    PlaybackSession.sharedLocal.pictureInPictureActive = true
                }
            }
        }
    }
    func toggle() {
        if let engine { attach(engine: engine) }
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            transition.beginRestore()
            // Explicit stop need not produce AVKit's restore delegate callback.
            // During startup the original picture may still own the window.
            if !transition.dismissalPending, let engine, engine.renderView?.window != nil {
                surfaceMounted(engine: engine)
            }
            controller.stopPictureInPicture()
        }
        else if controller.isPictureInPicturePossible, !starting, !active,
                !transition.preservesSessionOnDismiss {
            starting = true
            transition.prepareToStart()
            engine?.preparePictureInPicture()
            controller.startPictureInPicture()
        }
    }
    /// The playback owner outlives the SwiftUI cover. Media replacement must
    /// release presentation ownership before the old AVKit controller vanishes.
    func stop(engine: KSPlaybackEngine) {
        guard self.engine === engine else { return }
        onClose = nil
        stop()
    }
    func stop() {
        let previous = controller
        attachment = UUID(); observation = nil; activeObservation = nil; controller = nil
        previous?.delegate = nil; previous?.stopPictureInPicture()
        engine?.setPictureInPictureActive(false)
        active = false; starting = false; possible = false; transition.cancelled()
        restoreCompletion?(false); restoreCompletion = nil
        PlaybackSession.sharedLocal.pictureInPictureActive = false
    }
    func surfaceMounted(engine: KSPlaybackEngine) {
        guard self.engine === engine, engine.mediaID != nil,
              !transition.dismissalPending,
              transition.restoring || restoreCompletion != nil else { return }
        transition.surfaceMounted()
        engine.resumeAfterForeground()
        let completion = restoreCompletion; restoreCompletion = nil
        completion?(true)
    }
    func coverDismissed() { transition.coverDismissed() }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.controller === pictureInPictureController,
                  self.engine?.pipController === pictureInPictureController,
                  pictureInPictureController.isPictureInPictureActive, !self.transition.active else { return }
            self.active = true; self.starting = false
            self.engine?.setPictureInPictureActive(true)
            // AVKit has finished capturing the source for its start animation.
            // Retain it before publishing the cover dismissal to SwiftUI.
            if !self.transition.restoreRequested { self.engine?.retainPictureInPictureSource() }
            self.transition.started()
            PlaybackSession.sharedLocal.pictureInPictureActive = true
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        let reply = PlaybackPiPRestoreReply(completionHandler)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.controller === pictureInPictureController,
                  self.engine?.pipController === pictureInPictureController, self.engine?.mediaID != nil else {
                reply.complete(false); return
            }
            self.restoreCompletion?(false)
            self.restoreCompletion = { reply.complete($0) }
            self.transition.beginRestore()
            // With no dismissal in progress the existing mounted surface owns
            // the current cover (for example PiP stopped before its active KVO hop).
            if !self.transition.dismissalPending, let engine = self.engine, engine.renderView?.window != nil {
                self.surfaceMounted(engine: engine)
            }
        }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.controller === pictureInPictureController,
                  self.engine?.pipController === pictureInPictureController,
                  !pictureInPictureController.isPictureInPictureActive,
                  !self.starting || self.transition.restoreRequested else { return }
            // The system restore control calls the restore delegate first. Its
            // intent survives native mounting and KVO false until didStop.
            // X (or system dismissal) has no restore request and ends playback.
            if !self.transition.restoreRequested {
                let close = self.onClose, engine = self.engine
                self.onClose = nil
                self.stop()
                if let close { close() } else { engine?.shutdown() }
                return
            }
            self.active = false; self.starting = false; self.transition.stopped()
            self.engine?.setPictureInPictureActive(false)
            PlaybackSession.sharedLocal.pictureInPictureActive = false
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        let detail = Diagnostics.describe(error)
        Task { @MainActor [weak self] in
            guard self?.controller === pictureInPictureController,
                  self?.engine?.pipController === pictureInPictureController else { return }
            self?.active = false; self?.starting = false
            self?.engine?.setPictureInPictureActive(false)
            self?.transition.cancelled()
            self?.restoreCompletion?(false); self?.restoreCompletion = nil
            PlaybackSession.sharedLocal.pictureInPictureActive = false
            Diagnostics.shared.record(.warning, "player", "Picture in Picture failed: \(detail)")
        }
    }
}

/// Scrubbing drafts stay local; all times and seeks come from the single active playback engine.
@MainActor @Perceptible final class PlayerClock {
    @PerceptionIgnored private var operations = PlaybackOperationScope()
    @PerceptionIgnored private weak var engine: KSPlaybackEngine?
    private(set) var scrubbing: Double?
    var position: Double { engine?.position ?? 0 }
    var duration: Double { engine?.duration ?? 0 }
    var bufferedPosition: Double { engine?.bufferedPosition ?? 0 }
    var presentationSize: CGSize { engine?.presentationSize ?? .zero }
    var currentPosition: Double { engine?.position ?? 0 }
    private(set) var preview: CGImage?
    @PerceptionIgnored private var previewTask: Task<Void, Never>?
    @PerceptionIgnored private var previewScope = UUID()
    func attach(_ engine: KSPlaybackEngine) { detach(); self.engine = engine }
    func detach() { replaceMedia(); engine = nil }
    func replaceMedia() { operations.replaceMedia(); scrubbing = nil; cancelPreview() }
    func scrub(to seconds: Double) {
        // A previous submitted seek may complete while this draft is still held.
        // Its callback must not clear the newer target before the finger lifts.
        _ = operations.beginSeek()
        let target = min(max(0, seconds), duration)
        guard scrubbing != target else { return }
        scrubbing = target
        makePreview(at: target)
    }
    func endScrub() {
        cancelPreview()
        if let target = scrubbing { seek(to: target) }
    }
    func cancelScrub() {
        _ = operations.beginSeek()
        scrubbing = nil
        cancelPreview()
    }
    private func cancelPreview() {
        previewScope = UUID(); previewTask?.cancel(); previewTask = nil; preview = nil
    }
    private func makePreview(at target: Double) {
        previewTask?.cancel()
        previewScope = UUID()
        guard let engine else { previewTask = nil; return }
        let scope = previewScope, media = engine.mediaID
        previewTask = Task { [weak self, weak engine] in
            // Coalesce high-frequency drag updates before starting the bounded
            // decoder. Cancellation reaches its current IO immediately.
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, let engine, self.previewScope == scope, engine.mediaID == media else { return }
            let image = await engine.thumbnail(at: target)
            guard !Task.isCancelled, self.previewScope == scope, engine.mediaID == media,
                  self.scrubbing == target else { return }
            self.preview = image
            self.previewTask = nil
        }
    }
    func seek(to seconds: Double) {
        guard let engine else { scrubbing = nil; return }
        let ticket = operations.beginSeek(), media = engine.mediaID
        scrubbing = seconds
        engine.seek(to: seconds) { [weak self, weak engine] _ in
            guard let self, let engine, self.operations.accepts(ticket), engine.mediaID == media else { return }
            self.scrubbing = nil
        }
    }
}

private enum LocalPlayerPanel: String, Identifiable {
    case cast, aspect, speed, volume, information, episodes, quality, video, audio, subtitle, danmaku, chapters, skip, subtitleAddress, danmakuList, danmakuConfiguration
    var id: String { rawValue }
    var title: String { switch self { case .cast: "投屏"; case .aspect: "画面比例"; case .speed: "倍速"; case .volume: "音量"; case .information: "视频信息"; case .episodes: "选集"; case .quality: "画质"; case .video: "视轨"; case .audio: "音轨"; case .subtitle: "字幕"; case .danmaku: "弹幕"; case .chapters: "章节"; case .skip: "片头片尾"; case .subtitleAddress: "从网址添加字幕"; case .danmakuList: "弹幕列表"; case .danmakuConfiguration: "配置弹幕来源" } }
    var symbol: String { switch self { case .cast: "airplayvideo"; case .aspect: "aspectratio"; case .speed: "speedometer"; case .volume: "speaker.wave.2"; case .information: "info.circle"; case .episodes: "rectangle.stack"; case .quality: "slider.horizontal.3"; case .video: "film"; case .audio: "speaker.wave.2"; case .subtitle, .subtitleAddress: "captions.bubble"; case .danmaku, .danmakuList: "text.bubble"; case .chapters: "book"; case .skip: "forward.end"; case .danmakuConfiguration: "globe" } }
}

/// The video on the Lock Screen, in Control Center and on headphones, with play, pause, skip and scrub: AVKit's
/// own player published these by itself. Music holds Now Playing only while no video plays (MusicRemoteControl).
@MainActor final class VideoNowPlaying {
    private var targets: [(MPRemoteCommand, Any)] = []

    func start(_ session: PlaybackSession) {
        guard targets.isEmpty else { return }
        let commands = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlaybackSession, MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self, weak session] event in
                MainActor.assumeIsolated {
                    guard let session else { return .noActionableNowPlayingItem }
                    action(session, event)
                    self?.update(title: nil, session: session)
                    return .success
                }
            }
            targets.append((command, target))
        }
        on(commands.playCommand) { session, _ in if session.paused { session.togglePlayback() } }
        on(commands.pauseCommand) { session, _ in session.engine.pause() }
        on(commands.togglePlayPauseCommand) { session, _ in session.togglePlayback() }
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.preferredIntervals = [10]
        on(commands.skipForwardCommand) { session, _ in session.skip(10) }
        on(commands.skipBackwardCommand) { session, _ in session.skip(-10) }
        on(commands.changePlaybackPositionCommand) { session, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            session.engine.seek(to: event.positionTime)
        }
    }

    private var title = ""
    private var artworkSource: PlaybackArtwork?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    /// The video's poster beside its title, loaded once per poster; none until it has loaded.
    func show(_ source: PlaybackArtwork, session: PlaybackSession) {
        guard source != artworkSource else { return }
        artworkSource = source; artwork = nil
        artworkTask?.cancel()
        guard let url = source.poster else { return }
        artworkTask = Task { [weak self, weak session] in
            guard let bitmap = await PosterPalette.image(url, headers: source.headers), !Task.isCancelled,
                  let self, let session, self.artworkSource == source else { return }
            self.artwork = Self.artwork(UIImage(cgImage: bitmap))
            self.update(title: nil, session: session)
        }
    }

    /// MediaPlayer asks for the image on its own queue: a closure made on the main actor would
    /// trap there, checking it runs on the main thread.
    private nonisolated static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// `title` nil keeps the one shown.
    func update(title: String?, session: PlaybackSession) {
        guard !targets.isEmpty else { return }
        if let title { self.title = title }
        let engine = session.engine, seekable = session.hasTimeline && !session.isLive
        let commands = MPRemoteCommandCenter.shared()
        for command in [commands.skipForwardCommand, commands.skipBackwardCommand, commands.changePlaybackPositionCommand] {
            command.isEnabled = seekable
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: self.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: session.isLive,
            MPNowPlayingInfoPropertyPlaybackRate: session.paused ? 0.0 : Double(session.boost ?? engine.speed),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(session.preferredSpeed),
        ]
        let elapsed = engine.position
        if elapsed.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        if seekable, engine.duration.isFinite {
            let duration = engine.duration
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = session.paused ? .paused : .playing
    }

    func stop() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        artworkTask?.cancel(); artworkTask = nil; artworkSource = nil; artwork = nil
        // Music may already have taken Now Playing back as the player closed.
        let center = MPNowPlayingInfoCenter.default()
        if center.nowPlayingInfo?[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.video.rawValue {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
    }
}

/// The heads-up line itself: one quiet line over the picture, rebuilt once a second. Every value is state
/// the session and its engine already keep — the position and duration off the engine's clock, the picture
/// size it samples, the frame rate its PlaybackInfo carries (the source's rate, the display rate behind it),
/// and the download rate the session's transfer ticker already samples from the engine's byte count for the
/// top row. Nothing here reaches into the player core.
private struct PlayerOSD: View {
    let session: PlaybackSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            WithPerceptionTracking {
                if let line = line(at: context.date) {
                    Text(line)
                        .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        // A plain tint, not a material, like the info panel: it sits over moving video.
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1) }
                        .environment(\.colorScheme, .dark)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("player.osd")
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// "12:34 / 45:06 · 1920×1080 · 25 fps · 21:47:05 · 1.3 MB/s" — a part with no value yet drops out.
    private func line(at date: Date) -> String? {
        let engine = session.engine
        var parts: [String] = []
        if engine.duration > 0 && !session.isLive {
            parts.append(Self.time(engine.position) + " / " + Self.time(engine.duration))
        } else if engine.position > 0 {
            parts.append(Self.time(engine.position))
        }
        let size = engine.presentationSize
        if size.width > 0, size.height > 0 {
            parts.append("\(Int(size.width.rounded()))×\(Int(size.height.rounded()))")
        }
        let rate = engine.playbackInfo.frameRate ?? (engine.frameRate > 0 ? engine.frameRate : nil)
        if let rate, rate.isFinite, rate > 0 { parts.append(Self.rate(rate) + " fps") }
        parts.append(Self.clock.string(from: date))
        if let speed = session.transfer.bytesPerSecond, speed.isFinite, speed >= 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed.rounded()), countStyle: .file) + "/s")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The same wording as the seek bar's clock: "12:34", or "1:02:03" past an hour.
    private static func time(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(0, seconds) : 0)
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// At most two decimals, trailing zeros dropped: 25, 23.98, 29.97.
    private static func rate(_ value: Double) -> String {
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}


#endif
