import Foundation

/// Decode PTS decides whether a frame is due. The display link samples that
/// clock at supported VSync intervals rather than rounding fractional film FPS
/// into an unrelated display request (23.976 -> 24, 29.97 -> 30).
struct VideoDisplayCadence: Equatable {
    let framesPerSecond: Int

    init(sourceFPS: Float, playbackRate: Float, screenMaximum: Int) {
        let maximum = screenMaximum > 0 ? screenMaximum : 60
        let source = sourceFPS.isFinite && sourceFPS > 0 ? sourceFPS : 60
        let rate = playbackRate.isFinite && playbackRate > 0 ? playbackRate : 1
        framesPerSecond = source * rate > 60 ? maximum : min(60, maximum)
    }
}
