import AVFoundation
import Foundation

/// One transport/seek lifetime around the original video and optional original
/// audio input. Each MEPlayerItem keeps its own FFmpeg demuxer and decode queue;
/// a companion never owns another audio output or UI player.
final class MEPlaybackSource: OutputRenderSourceDelegate {
    private let primary: MEPlayerItem
    private let companion: MEPlayerItem?
    private let options: KSOptions
    private let primaryDelegate = InputDelegate()
    private let companionDelegate = InputDelegate()
    private let lock = NSLock()
    private var opened = Set<Int>()
    private var ended = Set<Int>()
    private var loads: [Int: LoadingState] = [:]
    private var closed = false
    private var failed = false
    private var seekGeneration: UInt64 = 0
    private var seekPending = Set<Int>()
    private var seekSucceeded = true
    private var requestedSeekTime: TimeInterval?
    private var failedPlaybackTime: TimeInterval?
    private var seekCompletion: ((Bool) -> Void)?
    weak var delegate: MEPlayerDelegate?

    init(url: URL, options: KSOptions) {
        self.options = options
        primary = MEPlayerItem(url: url, options: options)
        primary.suppressEmbeddedAudio = options.companionAudioURL != nil
        if let audioURL = options.companionAudioURL {
            companion = MEPlayerItem(url: audioURL, options: options.companionAudioOptions())
        } else {
            companion = nil
        }
        primaryDelegate.owner = self; primaryDelegate.index = 0
        companionDelegate.owner = self; companionDelegate.index = 1
        primary.delegate = primaryDelegate; companion?.delegate = companionDelegate
        if let companion {
            // Relative audio time is shifted to the video's PTS epoch inside
            // its reader, keeping each source's original timestamps intact.
            primary.externalAudioClock = { [weak companion] in companion?.relativeAudioClock() }
        }
    }

    private var inputCount: Int { companion == nil ? 1 : 2 }
    var duration: TimeInterval { primary.duration }
    var naturalSize: CGSize { primary.naturalSize }
    var chapters: [Chapter] { primary.chapters }
    var fileSize: Double { primary.fileSize + (companion?.fileSize ?? 0) }
    var cacheTimeline: [PlaybackCacheTimeline] {
        let primaryIndex = primary.cacheTimeline
        guard let companion else { return primaryIndex }
        let audioIndex = companion.cacheTimeline
        // An unindexed companion must not inherit the primary video's coverage.
        guard !primaryIndex.isEmpty, !audioIndex.isEmpty else { return [] }
        return primaryIndex + audioIndex
    }
    var currentPlaybackTime: TimeInterval {
        if let failedTime = lock.withLock({ failedPlaybackTime }) { return failedTime }
        if let companion, !lock.withLock({ ended.contains(1) }) { return companion.currentPlaybackTime }
        return primary.currentPlaybackTime
    }
    var displayedVideoTime: TimeInterval { primary.displayedVideoTime }
    func relativeVideoTime(for timestamp: CMTime) -> TimeInterval { primary.relativeVideoTime(for: timestamp) }
    var hasReachedEndOfInput: Bool { primary.hasReachedEndOfInput && (companion?.hasReachedEndOfInput ?? true) }
    var seekable: Bool { primary.seekable && (companion?.seekable ?? true) }
    var assetTracks: [FFmpegAssetTrack] {
        guard let companion else { return primary.assetTracks }
        return primary.assetTracks.filter { $0.mediaType != .audio } + companion.assetTracks.filter { $0.mediaType == .audio }
    }
    #if DEBUG
    var renderDiagnostic: String { primary.renderDiagnostic + (companion.map { " companion=[\($0.renderDiagnostic)]" } ?? "") }
    var subtitleDiagnostic: String { primary.subtitleDiagnostic }
    #endif

    private lazy var combinedInfo = DynamicInfo { [weak self] in
        self?.primary.dynamicInfo.metadata ?? [:]
    } bytesRead: { [weak self] in
        (self?.primary.dynamicInfo.bytesRead ?? 0) + (self?.companion?.dynamicInfo.bytesRead ?? 0)
    } audioBitrate: { [weak self] in
        self?.companion?.dynamicInfo.audioBitrate ?? self?.primary.dynamicInfo.audioBitrate ?? 0
    } videoBitrate: { [weak self] in
        self?.primary.dynamicInfo.videoBitrate ?? 0
    }
    var dynamicInfo: DynamicInfo {
        guard companion != nil else { return primary.dynamicInfo }
        let source = primary.dynamicInfo
        combinedInfo.displayFPS = source.displayFPS
        combinedInfo.audioVideoSyncDiff = source.audioVideoSyncDiff
        combinedInfo.droppedVideoFrameCount = source.droppedVideoFrameCount
        combinedInfo.droppedVideoPacketCount = source.droppedVideoPacketCount
        return combinedInfo
    }

    func prepareToPlay() { primary.prepareToPlay(); companion?.prepareToPlay() }

    func whenClosed(_ completion: @escaping () -> Void) {
        let group = DispatchGroup()
        group.enter()
        primary.whenClosed { group.leave() }
        if let companion {
            group.enter()
            companion.whenClosed { group.leave() }
        }
        group.notify(queue: .global(qos: .userInitiated), execute: completion)
    }

    func shutdown() {
        let closing: (((Bool) -> Void)?)? = lock.withLock {
            guard !closed else { return nil }
            closed = true; seekGeneration &+= 1
            let completion = seekCompletion; seekCompletion = nil; seekPending.removeAll()
            return .some(completion)
        }
        guard let completion = closing else { return }
        primary.delegate = nil; companion?.delegate = nil
        primary.shutdown(); companion?.shutdown()
        completion?(false)
    }

    func seek(time: TimeInterval, completion: @escaping (Bool) -> Void) {
        let state: (UInt64, ((Bool) -> Void)?)? = lock.withLock {
            guard !closed else { return nil }
            let previous = seekCompletion
            seekGeneration &+= 1; seekPending = Set(0..<inputCount)
            seekSucceeded = true; seekCompletion = completion
            requestedSeekTime = time
            ended.removeAll(); loads.removeAll()
            return (seekGeneration, previous)
        }
        guard let (generation, previous) = state else { completion(false); return }
        previous?(false)
        primary.seek(time: time) { [weak self] success in self?.didSeek(index: 0, generation: generation, success: success) }
        companion?.seek(time: time) { [weak self] success in self?.didSeek(index: 1, generation: generation, success: success) }
    }

    private func didSeek(index: Int, generation: UInt64, success: Bool) {
        let finished: (((Bool) -> Void), Bool)? = lock.withLock {
            guard !closed, generation == seekGeneration, seekPending.remove(index) != nil else { return nil }
            seekSucceeded = seekSucceeded && success
            guard seekPending.isEmpty, let completion = seekCompletion else { return nil }
            seekCompletion = nil
            if !seekSucceeded, companion != nil { failed = true; failedPlaybackTime = requestedSeekTime }
            return (completion, seekSucceeded)
        }
        if let (completion, result) = finished {
            if !result, companion != nil {
                // One demuxer may already be on the new position while its
                // partner failed. Never resume those different PTS epochs.
                // The app's existing failure recovery reopens both originals.
                shutdown()
                delegate?.sourceDidFailed(error: NSError(domain: "KSPlayer.CompanionInput", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "独立音视频定位未能同时完成，请重新准备播放。"]))
            }
            completion(result)
        }
    }

    @discardableResult func select(track: some MediaPlayerTrack, performSeek: Bool = true) -> Bool {
        let reader = track.mediaType == .audio ? companion ?? primary : primary
        let requiresSeek = reader.select(track: track, performSeek: false)
        if requiresSeek, performSeek { seek(time: currentPlaybackTime) { _ in } }
        return requiresSeek
    }
    func updateAudioClockPlayback(isPlaying: Bool, rate: Double) {
        primary.updateAudioClockPlayback(isPlaying: isPlaying, rate: rate)
        companion?.updateAudioClockPlayback(isPlaying: isPlaying, rate: rate)
    }
    func getVideoOutputRender(force: Bool) -> VideoVTBFrame? {
        guard !lock.withLock({ closed || failed }) else { return nil }
        return primary.getVideoOutputRender(force: force)
    }
    func setVideo(time: CMTime, position: Int64) { primary.setVideo(time: time, position: position) }
    func getAudioOutputRender() -> AudioFrame? {
        guard !lock.withLock({ closed || failed }) else { return nil }
        return (companion ?? primary).getAudioOutputRender()
    }
    func setAudio(time: CMTime, position: Int64) { (companion ?? primary).setAudio(time: time, position: position) }
    func startRecord(url: URL) { primary.startRecord(url: url) }
    func stopRecord() { primary.stopRecord() }

    private func didOpen(index: Int) {
        let ready = lock.withLock { () -> Bool in
            guard !closed, !failed, opened.insert(index).inserted else { return false }
            return opened.count == inputCount
        }
        if ready { delegate?.sourceDidOpened() }
    }
    private func didLoad(index: Int, loading: LoadingState) {
        let merged: LoadingState? = lock.withLock {
            guard !closed, !failed else { return nil }
            loads[index] = loading
            guard loads.count == inputCount else { return nil }
            let values = Array(loads.values)
            // An exhausted shorter track must not keep the remaining video
            // permanently buffering. Pending tracks still gate common readiness.
            let active = loads.filter { !ended.contains($0.key) }.map(\.value)
            let buffering = active.isEmpty ? values : active
            return LoadingState(loadedTime: buffering.map(\.loadedTime).min() ?? 0,
                progress: buffering.map(\.progress).min() ?? 0,
                packetCount: buffering.map(\.packetCount).min() ?? 0,
                frameCount: buffering.map(\.frameCount).min() ?? 0,
                isEndOfFile: values.allSatisfy(\.isEndOfFile), isPlayable: buffering.allSatisfy(\.isPlayable),
                isFirst: values.contains(where: \.isFirst), isSeek: values.contains(where: \.isSeek))
        }
        if let merged { delegate?.sourceDidChange(loadingState: merged) }
    }
    private func didFinish(index: Int) {
        guard companion != nil else {
            if !lock.withLock({ closed || failed }) { delegate?.sourceDidFinished() }
            return
        }
        let finished = lock.withLock { () -> Bool in
            guard !closed, !failed, ended.insert(index).inserted else { return false }
            return ended.count == inputCount
        }
        if finished { delegate?.sourceDidFinished() }
    }
    private func didFail(error: NSError?) {
        let notify = lock.withLock { () -> Bool in
            guard !closed, !failed else { return false }
            failed = true
            if seekCompletion != nil { failedPlaybackTime = requestedSeekTime }
            return true
        }
        if notify {
            shutdown()
            delegate?.sourceDidFailed(error: error)
        }
    }
    private final class InputDelegate: MEPlayerDelegate {
        weak var owner: MEPlaybackSource?
        var index = 0
        func sourceDidOpened() { owner?.didOpen(index: index) }
        func sourceDidChange(loadingState: LoadingState) { owner?.didLoad(index: index, loading: loadingState) }
        func sourceDidFinished() { owner?.didFinish(index: index) }
        func sourceDidFailed(error: NSError?) { owner?.didFail(error: error) }
        func sourceDidChange(oldBitRate: Int64, newBitrate: Int64) { owner?.delegate?.sourceDidChange(oldBitRate: oldBitRate, newBitrate: newBitrate) }
    }
}
