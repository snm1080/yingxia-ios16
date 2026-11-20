#if os(iOS)
import CoreGraphics
import KSPlayer

struct KSPlaybackSelections: Sendable {
    var video: String?
    var audio: String?
    var subtitle: String?
    var secondarySubtitle: String?
}

/// Reopening the same input keeps its selected streams from the first decoded
/// packet, without a second track-switch seek racing the resume seek.
final class KSPlaybackOptions: KSOptions {
    var selections: KSPlaybackSelections?

    override init() {
        super.init()
        // Some HLS hosts serve valid MPEG-TS under image suffixes. Probe the
        // segment bytes while retaining FFmpeg's file/protocol access gates.
        formatContextOptions["extension_picky"] = 0
    }

    /// The Vendor default queues 16 decoded frames at any size: a 4K 10-bit
    /// P010 frame is ~24.9 MB, so a full queue alone approaches 400 MB and
    /// gets the app memory-killed, while a 1080p frame (~6 MB) stays near
    /// 100 MB. Scale the count to a bounded byte budget instead. The hook
    /// receives no bit depth, so estimate the stored frame at 3 bytes per
    /// pixel (biplanar 4:2:0 with 16-bit sample storage — the P010 worst
    /// case) and divide a 150 MiB budget by it: 3840×2160 → 6 frames,
    /// while 1920×1080 and below still clamp to the full 16. Live keeps
    /// the Vendor value untouched.
    override func videoFrameMaxCount(fps: Float, naturalSize: CGSize, isLive: Bool) -> UInt8 {
        if isLive { return super.videoFrameMaxCount(fps: fps, naturalSize: naturalSize, isLive: isLive) }
        let width = Int(naturalSize.width.rounded()), height = Int(naturalSize.height.rounded())
        guard width > 0, height > 0 else { return super.videoFrameMaxCount(fps: fps, naturalSize: naturalSize, isLive: isLive) }
        let frameBytes = width * height * 3
        let count = (150 * 1024 * 1024) / frameBytes
        return UInt8(min(16, max(4, count)))
    }

    override func wantedVideo(tracks: [MediaPlayerTrack]) -> Int? {
        guard let selection = selections?.video else { return nil }
        return tracks.firstIndex { String($0.trackID) == selection }
    }

    override func wantedAudio(tracks: [MediaPlayerTrack]) -> Int? {
        guard let selection = selections?.audio else { return nil }
        return tracks.firstIndex { String($0.trackID) == selection }
    }
}
#endif
