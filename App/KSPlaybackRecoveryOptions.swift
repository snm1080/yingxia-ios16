#if os(iOS)
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
