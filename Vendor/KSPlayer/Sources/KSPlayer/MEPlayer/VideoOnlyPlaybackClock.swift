import Foundation

/// A video-only timeline must not restart at the quantized presentation time
/// of every frame. Doing so repeatedly rounds 24 fps to 30 fps on a 60 Hz link.
/// Keep one wall/media anchor until transport, seek or a loop changes epoch.
struct VideoOnlyPlaybackClock {
    private var anchorMedia: Double?
    private var anchorHost = 0.0
    private var running = false
    private var rate = 1.0
    private var lastSampledPicture: Double?

    mutating func updatePlayback(isPlaying: Bool, rate newRate: Double, now: Double) {
        let nextRate = newRate.isFinite && newRate > 0 ? newRate : 1
        guard isPlaying != running || nextRate != rate else { return }
        if let current = currentTime(now: now) { anchorMedia = current }
        anchorHost = now; running = isPlaying; rate = nextRate
    }

    mutating func reset() {
        anchorMedia = nil; lastSampledPicture = nil
    }

    mutating func time(pictureTime: Double, nextVideoTime: Double, now: Double) -> Double {
        // A loop can swap native queues without asking KSMEPlayer to seek.
        // A discontinuity is an epoch change, not a new anchor for every frame.
        if let previous = lastSampledPicture, pictureTime < previous - 0.5 { reset() }
        if let previous = lastSampledPicture, nextVideoTime < previous - 0.5 { reset() }
        if anchorMedia == nil {
            anchorMedia = nextVideoTime.isFinite ? nextVideoTime : pictureTime
            anchorHost = now
        }
        lastSampledPicture = pictureTime
        return currentTime(now: now) ?? pictureTime
    }

    private func currentTime(now: Double) -> Double? {
        anchorMedia.map { $0 + (running ? max(0, now - anchorHost) * rate : 0) }
    }
}
