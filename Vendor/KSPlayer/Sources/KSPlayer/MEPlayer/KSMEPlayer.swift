//
//  KSMEPlayer.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import AVKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public class KSMEPlayer: NSObject {
    private var loopCount = 1
    private var playerItem: MEPlaybackSource
    private var sourceID = UUID()
    private var sourceDelegate: SourceDelegate?
    private var retiringSource: MEPlaybackSource?
    private var pendingReplacement: (URL, KSOptions)?
    private var prepareAfterReplacement = false
    public let audioOutput: AudioOutput
    private var options: KSOptions
    private var bufferingCountDownTimer: Timer?
    private var seekPictureRevision = 0
    private var pendingSeekPicture: Int?
    private var outputsPaused = true
    private var failedSource = false
    public private(set) var videoOutput: (VideoOutput & UIView)? {
        didSet {
            oldValue?.invalidate()
            runOnMainThread {
                oldValue?.removeFromSuperview()
            }
        }
    }

    public private(set) var bufferingProgress = 0 {
        willSet {
            runOnMainThread { [weak self] in
                guard let self else { return }
                delegate?.changeBuffering(player: self, progress: newValue)
            }
        }
    }

    private lazy var _pipController: Any? = {
        if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *), let videoOutput {
            let contentSource = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: videoOutput.displayLayer, playbackDelegate: self)
            let pip = KSPictureInPictureController(contentSource: contentSource)
            return pip
        } else {
            return nil
        }
    }()

    @available(tvOS 14.0, *)
    public var pipController: KSPictureInPictureController? {
        _pipController as? KSPictureInPictureController
    }

    private lazy var _playbackCoordinator: Any? = {
        if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
            let coordinator = AVDelegatingPlaybackCoordinator(playbackControlDelegate: self)
            coordinator.suspensionReasonsThatTriggerWaiting = [.stallRecovery]
            return coordinator
        } else {
            return nil
        }
    }()

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
    public var playbackCoordinator: AVPlaybackCoordinator {
        // swiftlint:disable force_cast
        _playbackCoordinator as! AVPlaybackCoordinator
        // swiftlint:enable force_cast
    }

    public private(set) var playableTime = TimeInterval(0)
    public weak var delegate: MediaPlayerDelegate?
    /// Route system transport controls through the application playback state machine.
    public var playbackCommand: ((Bool) -> Void)?
    public var seekCommand: ((Double) -> Void)?
    /// The app may supply a composited subtitle layer while retaining this playback delegate.
    public weak var applicationPictureInPictureController: AVPictureInPictureController?
    public private(set) var isReadyToPlay = false
    public var allowsExternalPlayback: Bool = false
    public var usesExternalPlaybackWhileExternalScreenIsActive: Bool = false

    public var playbackRate: Float = 1 {
        didSet {
            videoOutput?.playbackRate = playbackRate
            if playbackRate != audioOutput.playbackRate {
                audioOutput.playbackRate = playbackRate
                if audioOutput is AudioUnitPlayer {
                    var audioFilters = options.audioFilters.filter {
                        !$0.hasPrefix("atempo=")
                    }
                    if playbackRate != 1 {
                        audioFilters.append("atempo=\(playbackRate)")
                    }
                    options.audioFilters = audioFilters
                }
            }
            options.updateVideoClockPlayback(isPlaying: playbackState == .playing && loadState == .playable,
                                             rate: Double(audioOutput.playbackRate))
            playerItem.updateAudioClockPlayback(isPlaying: playbackState == .playing && loadState == .playable,
                                               rate: Double(audioOutput.playbackRate))
        }
    }

    public private(set) var loadState = MediaLoadState.idle {
        didSet {
            if loadState != oldValue {
                playOrPause()
            }
        }
    }

    public private(set) var playbackState = MediaPlaybackState.idle {
        didSet {
            if playbackState != oldValue {
                playOrPause()
                if playbackState == .finished {
                    runOnMainThread { [weak self] in
                        guard let self else { return }
                        delegate?.finish(player: self, error: nil)
                    }
                }
            }
        }
    }

    public required init(url: URL, options: KSOptions) {
        KSOptions.setAudioSession()
        audioOutput = KSOptions.audioPlayerType.init()
        playerItem = MEPlaybackSource(url: url, options: options)
        if options.videoDisable {
            videoOutput = nil
        } else {
            videoOutput = KSOptions.videoPlayerType.init(options: options)
        }
        self.options = options
        super.init()
        let sourceDelegate = SourceDelegate(owner: self, sourceID: sourceID)
        self.sourceDelegate = sourceDelegate
        playerItem.delegate = sourceDelegate
        audioOutput.renderSource = playerItem
        videoOutput?.renderSource = playerItem
        videoOutput?.displayLayerDelegate = self
        #if !os(macOS)
        NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChange), name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance())
        if #available(tvOS 15.0, iOS 15.0, *) {
            NotificationCenter.default.addObserver(self, selector: #selector(spatialCapabilityChange), name: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification, object: nil)
        }
        #endif
    }

    deinit {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(2)
        #endif
        NotificationCenter.default.removeObserver(self)
        videoOutput?.invalidate()
        playerItem.shutdown()
    }
}

// MARK: - private functions

private extension KSMEPlayer {
    func playOrPause() {
        runOnMainThread { [weak self] in
            guard let self else { return }
            let isPaused = !(self.playbackState == .playing && self.loadState == .playable)
            self.options.updateVideoClockPlayback(isPlaying: !isPaused, rate: Double(self.audioOutput.playbackRate))
            self.playerItem.updateAudioClockPlayback(isPlaying: !isPaused, rate: Double(self.audioOutput.playbackRate))
            // loadState and transport can publish in the same run-loop turn.
            // AudioRendererPlayer installs an observer on each play, so only
            // an actual output transition may start/stop either output.
            if self.outputsPaused != isPaused {
                self.outputsPaused = isPaused
                if isPaused {
                    self.audioOutput.pause()
                    self.videoOutput?.pause()
                } else {
                    self.audioOutput.play()
                    self.videoOutput?.play()
                }
            }
            self.delegate?.changeLoadState(player: self)
        }
    }

    @objc private func spatialCapabilityChange(notification _: Notification) {
        KSLog("[audio] spatialCapabilityChange")
        for track in tracks(mediaType: .audio) {
            (track as? FFmpegAssetTrack)?.audioDescriptor?.updateAudioFormat()
        }
    }

    #if !os(macOS)
    @objc private func audioRouteChange(notification: Notification) {
        KSLog("[audio] audioRouteChange")
        guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else {
            return
        }
//        let routeChangeReason = AVAudioSession.RouteChangeReason(rawValue: reason)
//        guard [AVAudioSession.RouteChangeReason.newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange].contains(routeChangeReason) else {
//            return
//        }
        for track in tracks(mediaType: .audio) {
            (track as? FFmpegAssetTrack)?.audioDescriptor?.updateAudioFormat()
        }
        audioOutput.flush()
        // A route change (e.g. wired headphones plugged in mid-playback) stops
        // the AVAudioEngine behind the default AudioEnginePlayer: iOS reconfigures
        // the hardware and the engine stops rendering, while the video path keeps
        // going — picture with no sound. updateAudioFormat() above only re-prepares
        // the format (prepare() restarts the engine only when it was still running)
        // and flush() only clears queued renders, so nothing brings the engine back.
        // Restart the output the same way play()/enterForeground() already do:
        // AudioEnginePlayer.play() starts the engine only when it is not running,
        // so this is a no-op for route changes that did not stop it.
        if playbackState == .playing {
            KSOptions.activateAudioSession()
            audioOutput.play()
        }
    }
    #endif
}

extension KSMEPlayer: MEPlayerDelegate {
    func sourceDidOpened() {
        isReadyToPlay = true
        options.readyTime = CACurrentMediaTime()
        let vidoeTracks = tracks(mediaType: .video)
        if vidoeTracks.isEmpty {
            videoOutput = nil
        }
        let audioDescriptor = tracks(mediaType: .audio).first { $0.isEnabled }.flatMap {
            $0 as? FFmpegAssetTrack
        }?.audioDescriptor
        runOnMainThread { [weak self] in
            guard let self else { return }
            if let audioDescriptor {
                KSLog("[audio] audio type: \(audioOutput) prepare audioFormat )")
                audioOutput.prepare(audioFormat: audioDescriptor.audioFormat)
            }
            if let controlTimebase = videoOutput?.displayLayer.controlTimebase, options.startPlayTime > 1 {
                CMTimebaseSetTime(controlTimebase, time: CMTimeMake(value: Int64(options.startPlayTime), timescale: 1))
            }
            delegate?.readyToPlay(player: self)
        }
    }

    func sourceDidFailed(error: NSError?) {
        runOnMainThread { [weak self] in
            guard let self else { return }
            self.failedSource = true
            self.playbackState = .paused
            self.audioOutput.pause()
            self.audioOutput.flush()
            self.videoOutput?.pause()
            self.videoOutput?.discardPendingFrame()
            self.outputsPaused = true
            self.pendingSeekPicture = nil
            self.delegate?.finish(player: self, error: error)
        }
    }

    func sourceDidFinished() {
        runOnMainThread { [weak self] in
            guard let self else { return }
            if self.options.isLoopPlay {
                self.loopCount += 1
                self.delegate?.playBack(player: self, loopCount: self.loopCount)
                self.options.resetVideoClock()
                self.videoOutput?.discardPendingFrame()
                // Re-prime audio at the new loop PTS, removing its previous
                // periodic observer before starting a replacement.
                if !self.outputsPaused {
                    self.audioOutput.pause()
                    self.videoOutput?.pause()
                    self.outputsPaused = true
                }
                self.playOrPause()
            } else {
                self.playbackState = .finished
            }
        }
    }

    func sourceDidChange(loadingState: LoadingState) {
        // A paused output has no display-link ticks. Retry until the seek's
        // decoded video queue supplies one replacement picture, without audio.
        // The aggregate frame count is the minimum across audio/video queues;
        // an ended audio track must not prevent a remaining video frame drawing.
        if let pending = pendingSeekPicture {
            runOnMainThread { [weak self] in
                guard let self, self.pendingSeekPicture == pending,
                      self.playbackState == .paused || self.playbackState == .seeking else { return }
                if self.videoOutput?.readNextFrame() == true { self.pendingSeekPicture = nil }
            }
        }
        if loadingState.isEndOfFile {
            playableTime = duration
        } else {
            playableTime = currentPlaybackTime + loadingState.loadedTime
        }
        if loadState == .playable {
            if !loadingState.isEndOfFile, loadingState.frameCount == 0, loadingState.packetCount == 0, options.preferredForwardBufferDuration != 0 {
                loadState = .loading
                if playbackState == .playing {
                    runOnMainThread { [weak self] in
                        // 在主线程更新进度
                        self?.bufferingProgress = 0
                    }
                }
            }
        } else {
            if loadingState.isFirst {
                if videoOutput?.pixelBuffer == nil {
                    videoOutput?.readNextFrame()
                }
            }
            var progress = 100
            if loadingState.isPlayable {
                loadState = .playable
            } else {
                if loadingState.progress.isInfinite {
                    progress = 100
                } else if loadingState.progress.isNaN {
                    progress = 0
                } else {
                    progress = min(100, Int(loadingState.progress))
                }
            }
            if playbackState == .playing {
                runOnMainThread { [weak self] in
                    // 在主线程更新进度
                    self?.bufferingProgress = progress
                }
            }
        }
        if duration == 0, playbackState == .playing, loadState == .playable {
            if let rate = options.liveAdaptivePlaybackRate(loadingState: loadingState) {
                playbackRate = rate
            }
        }
    }

    func sourceDidChange(oldBitRate: Int64, newBitrate: Int64) {
        KSLog("oldBitRate \(oldBitRate) change to newBitrate \(newBitrate)")
    }
}

extension KSMEPlayer: MediaPlayerProtocol {
    public var chapters: [Chapter] {
        sourceDelegate == nil ? [] : playerItem.chapters
    }

    public var subtitleDataSouce: SubtitleDataSouce? { self }
    public var playbackVolume: Float {
        get {
            audioOutput.volume
        }
        set {
            audioOutput.volume = newValue
        }
    }

    public var isPlaying: Bool { playbackState == .playing }

    @MainActor
    public var naturalSize: CGSize {
        sourceDelegate == nil ? .zero : (options.display == .plane ? playerItem.naturalSize : KSOptions.sceneSize)
    }

    public var isExternalPlaybackActive: Bool { false }

    public var view: UIView? { videoOutput }

    public func replace(url: URL, options: KSOptions) {
        shutdown()
        pendingReplacement = (url, options)
        // A standby reader may already be fully closed. Its completion runs
        // synchronously on main, before the new descriptor is installed.
        if retiringSource == nil { activateReplacement() }
    }

    private func finishReplacement(retired: MEPlaybackSource) {
        guard retiringSource === retired else { return }
        retiringSource = nil
        activateReplacement()
    }

    private func activateReplacement() {
        guard let (url, options) = pendingReplacement else { return }
        pendingReplacement = nil
        let prepare = prepareAfterReplacement
        prepareAfterReplacement = false
        sourceID = UUID()
        playerItem = MEPlaybackSource(url: url, options: options)
        self.options = options
        if audioOutput is AudioUnitPlayer, playbackRate != 1 {
            options.audioFilters = options.audioFilters.filter { !$0.hasPrefix("atempo=") }
                + ["atempo=\(playbackRate)"]
        }
        let delegate = SourceDelegate(owner: self, sourceID: sourceID)
        sourceDelegate = delegate
        playerItem.delegate = delegate
        if options.videoDisable {
            videoOutput = nil
        } else if videoOutput == nil {
            videoOutput = KSOptions.videoPlayerType.init(options: options)
            videoOutput?.displayLayerDelegate = self
        }
        audioOutput.renderSource = playerItem
        videoOutput?.options = options
        videoOutput?.renderSource = playerItem
        if prepare { prepareToPlay() }
    }

    public var currentPlaybackTime: TimeInterval {
        get {
            sourceDelegate == nil ? 0 : playerItem.currentPlaybackTime
        }
        set {
            seek(time: newValue) { _ in }
        }
    }

    /// 见 `MEPlayerItem.displayedVideoTime`——最近一帧绘制到 display layer 的 PTS，
    /// 适合驱动需要与画面严格同步的视图（audioClock 因 buffer prefill 跑在画面之前不适用）。
    public var displayedVideoTime: TimeInterval { sourceDelegate == nil ? 0 : playerItem.displayedVideoTime }
    public func relativeVideoTime(for timestamp: CMTime) -> TimeInterval { playerItem.relativeVideoTime(for: timestamp) }
    public var hasReachedEndOfInput: Bool { playerItem.hasReachedEndOfInput }
    #if DEBUG
    public var renderDiagnostic: String { playerItem.renderDiagnostic }
    public var subtitleDiagnostic: String { playerItem.subtitleDiagnostic }
    #endif

    public var duration: TimeInterval { sourceDelegate == nil ? 0 : playerItem.duration }

    public var fileSize: Double { sourceDelegate == nil ? 0 : playerItem.fileSize }
    public var cacheTimeline: [PlaybackCacheTimeline] { sourceDelegate == nil ? [] : playerItem.cacheTimeline }

    public var seekable: Bool { sourceDelegate != nil && playerItem.seekable }

    public var dynamicInfo: DynamicInfo? {
        guard sourceDelegate != nil else { return nil }
        return playerItem.dynamicInfo
    }

    public func seek(time: TimeInterval, completion: @escaping ((Bool) -> Void)) {
        let time = max(time, 0)
        seekPictureRevision &+= 1
        let pictureRevision = seekPictureRevision
        pendingSeekPicture = nil
        playbackState = .seeking
        runOnMainThread { [weak self] in
            guard let self, self.seekPictureRevision == pictureRevision else { return }
            self.bufferingProgress = 0
            self.videoOutput?.discardPendingFrame()
            self.options.resetVideoClock()
        }
        let seekTime: TimeInterval
        if time >= duration, options.isLoopPlay {
            seekTime = 0
        } else {
            seekTime = time
        }
        playerItem.seek(time: seekTime) { [weak self] result in
            guard let self else { return }
            if result {
                self.audioOutput.flush()
                runOnMainThread { [weak self] in
                    guard let self, self.seekPictureRevision == pictureRevision else { return }
                    self.pendingSeekPicture = pictureRevision
                    if let controlTimebase = self.videoOutput?.displayLayer.controlTimebase {
                        CMTimebaseSetTime(controlTimebase, time: CMTimeMake(value: Int64(self.currentPlaybackTime), timescale: 1))
                    }
                }
            }
            completion(result)
        }
    }

    public func prepareToPlay() {
        KSLog("prepareToPlay \(self)")
        failedSource = false
        if retiringSource != nil || pendingReplacement != nil {
            prepareAfterReplacement = true
            return
        }
        options.prepareTime = CACurrentMediaTime()
        playerItem.prepareToPlay()
        bufferingProgress = 0
    }

    public func play() {
        guard !failedSource else { return }
        KSLog("play \(self)")
        // Same reason as `KSAVPlayer.play()`: iOS deactivates the session on an
        // interruption or a suspension, and only construction re-activated it.
        KSOptions.activateAudioSession()
        pendingSeekPicture = nil
        playbackState = .playing
        if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) {
            (applicationPictureInPictureController ?? pipController)?.invalidatePlaybackState()
        }
    }

    public func pause() {
        KSLog("pause \(self)")
        playbackState = .paused
        if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) {
            (applicationPictureInPictureController ?? pipController)?.invalidatePlaybackState()
        }
    }

    public func shutdown() {
        KSLog("shutdown \(self)")
        pendingReplacement = nil
        prepareAfterReplacement = false
        sourceID = UUID()
        sourceDelegate = nil
        playerItem.delegate = nil
        seekPictureRevision &+= 1; pendingSeekPicture = nil
        playbackState = .stopped
        loadState = .idle
        runOnMainThread { [weak self] in
            guard let self else { return }
            self.audioOutput.pause()
            self.audioOutput.flush()
            self.videoOutput?.pause()
            self.videoOutput?.flush()
            self.audioOutput.renderSource = nil
            self.videoOutput?.renderSource = nil
            self.outputsPaused = true
            self.options.resetVideoClock()
        }
        isReadyToPlay = false
        playableTime = 0
        loopCount = 0
        if retiringSource == nil {
            let retiring = playerItem
            retiringSource = retiring
            retiring.shutdown()
            retiring.whenClosed { [weak self, weak retiring] in
                guard let retiring else { return }
                runOnMainThread { [weak self] in self?.finishReplacement(retired: retiring) }
            }
        }
        options.prepareTime = 0
        options.dnsStartTime = 0
        options.tcpStartTime = 0
        options.tcpConnectedTime = 0
        options.openTime = 0
        options.findTime = 0
        options.readyTime = 0
        options.readAudioTime = 0
        options.readVideoTime = 0
        options.decodeAudioTime = 0
        options.decodeVideoTime = 0
        if KSOptions.isClearVideoWhereReplace {
            videoOutput?.flush()
        }
    }

    @MainActor
    public var contentMode: UIViewContentMode {
        get {
            view?.contentMode ?? .center
        }
        set {
            view?.contentMode = newValue
        }
    }

    public func thumbnailImageAtCurrentTime() async -> CGImage? {
        videoOutput?.pixelBuffer?.cgImage()
    }

    public func enterBackground() {}

    public func enterForeground() {
        // A PiP/foreground transition can suspend the display link while the
        // demuxer and decoded queues remain valid. Refresh only the output.
        runOnMainThread { [weak self] in
            guard let self else { return }
            if #available(iOS 14.0, tvOS 14.0, macOS 11.0, *),
               self.videoOutput?.displayLayer.requiresFlushToResumeDecoding == true {
                self.videoOutput?.displayLayer.flush()
            }
            if self.playbackState == .playing && self.loadState == .playable {
                KSOptions.activateAudioSession()
                // PiP already owns a running audio output. Repeating play()
                // installs another periodic observer and loses the old token.
                // Only a genuinely paused output needs its audio restarted.
                if self.outputsPaused {
                    self.outputsPaused = false
                    self.audioOutput.play()
                }
                self.videoOutput?.play()
            }
        }
    }

    public var isMuted: Bool {
        get {
            audioOutput.isMuted
        }
        set {
            audioOutput.isMuted = newValue
        }
    }

    public func tracks(mediaType: AVFoundation.AVMediaType) -> [MediaPlayerTrack] {
        // During standby/close the old AVStream storage may already be freed.
        // No caller may discover a retired track through the reused facade.
        guard sourceDelegate != nil else { return [] }
        return playerItem.assetTracks.compactMap { track -> MediaPlayerTrack? in
            if track.mediaType == mediaType {
                return track
            } else if mediaType == .subtitle {
                return track.closedCaptionsTrack
            }
            return nil
        }
    }

    public func select(track: some MediaPlayerTrack) {
        let isSeek = playerItem.select(track: track)
        if isSeek {
            audioOutput.flush()
        }
    }

    /// Select a track while the application serializes the required seek itself.
    @discardableResult
    public func selectTrackWithoutSeeking(track: some MediaPlayerTrack) -> Bool {
        let requiresSeek = playerItem.select(track: track, performSeek: false)
        if requiresSeek { audioOutput.flush() }
        return requiresSeek
    }
}

@available(tvOS 14.0, *)
extension KSMEPlayer: AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(_: AVPictureInPictureController, setPlaying playing: Bool) {
        if let playbackCommand { playbackCommand(playing) }
        else { playing ? play() : pause() }
    }

    public func pictureInPictureControllerTimeRangeForPlayback(_: AVPictureInPictureController) -> CMTimeRange {
        // Handle live streams.
        if duration == 0 {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(start: 0, end: duration)
    }

    public func pictureInPictureControllerIsPlaybackPaused(_: AVPictureInPictureController) -> Bool {
        !isPlaying
    }

    public func pictureInPictureController(_: AVPictureInPictureController, didTransitionToRenderSize _: CMVideoDimensions) {}
    public func pictureInPictureController(_: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {
        let target = currentPlaybackTime + skipInterval.seconds
        if let seekCommand { seekCommand(target) }
        else { seek(time: target) { _ in } }
    }

    public func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_: AVPictureInPictureController) -> Bool {
        false
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
extension KSMEPlayer: AVPlaybackCoordinatorPlaybackControlDelegate {
    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue playCommand: AVDelegatingPlaybackCoordinatorPlayCommand, completionHandler: @escaping () -> Void) {
        guard playCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            completionHandler()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if self.playbackState != .playing {
                self.play()
            }
            completionHandler()
        }
    }

    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue pauseCommand: AVDelegatingPlaybackCoordinatorPauseCommand, completionHandler: @escaping () -> Void) {
        guard pauseCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            completionHandler()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if self.playbackState != .paused {
                self.pause()
            }
            completionHandler()
        }
    }

    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue seekCommand: AVDelegatingPlaybackCoordinatorSeekCommand) async {
        guard seekCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            return
        }
        let seekTime = fmod(seekCommand.itemTime.seconds, duration)
        if abs(currentPlaybackTime - seekTime) < CGFLOAT_EPSILON {
            return
        }
        seek(time: seekTime) { _ in }
    }

    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue bufferingCommand: AVDelegatingPlaybackCoordinatorBufferingCommand, completionHandler: @escaping () -> Void) {
        guard bufferingCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            completionHandler()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.loadState != .playable, let countDown = bufferingCommand.completionDueDate?.timeIntervalSinceNow else {
                completionHandler()
                return
            }
            self.bufferingCountDownTimer?.invalidate()
            self.bufferingCountDownTimer = nil
            self.bufferingCountDownTimer = Timer(timeInterval: countDown, repeats: false) { _ in
                completionHandler()
            }
        }
    }
}

extension KSMEPlayer: DisplayLayerDelegate {
    public func change(displayLayer: AVSampleBufferDisplayLayer) {
        if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) {
            let contentSource = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
            _pipController = KSPictureInPictureController(contentSource: contentSource)
            // 更改contentSource会直接crash
//            pipController?.contentSource = contentSource
        }
    }
}

public extension KSMEPlayer {
    func startRecord(url: URL) {
        playerItem.startRecord(url: url)
    }

    func stoptRecord() {
        playerItem.stopRecord()
    }
}

private final class SourceDelegate: MEPlayerDelegate {
    weak var owner: KSMEPlayer?
    let sourceID: UUID
    init(owner: KSMEPlayer, sourceID: UUID) { self.owner = owner; self.sourceID = sourceID }
    private func send(_ body: @escaping (KSMEPlayer) -> Void) {
        runOnMainThread { [weak self] in
            guard let self, let owner = self.owner, owner.accepts(sourceID: self.sourceID) else { return }
            body(owner)
        }
    }
    func sourceDidOpened() { send { $0.sourceDidOpened() } }
    func sourceDidFailed(error: NSError?) { send { $0.sourceDidFailed(error: error) } }
    func sourceDidFinished() { send { $0.sourceDidFinished() } }
    func sourceDidChange(loadingState: LoadingState) { send { $0.sourceDidChange(loadingState: loadingState) } }
    func sourceDidChange(oldBitRate: Int64, newBitrate: Int64) { send { $0.sourceDidChange(oldBitRate: oldBitRate, newBitrate: newBitrate) } }
}

extension KSMEPlayer {
    fileprivate func accepts(sourceID: UUID) -> Bool { self.sourceID == sourceID && retiringSource == nil }
}
