import Foundation

/// Detect a decoder that consumes video input without presenting its first
/// picture. Network stalls keep their own transport deadline.
public struct PlaybackPictureWatchdog {
    private var began: TimeInterval?
    private var lastActivity: TimeInterval?
    private var previousBytes: Int64 = 0
    private var previousPosition = 0.0
    public init() {}

    public mutating func update(now: TimeInterval, ready: Bool, selectedVideo: Bool, picture: Bool,
                                playing: Bool, seeking: Bool, decoderStarted: Bool, bytes: Int64,
                                position: Double, inputEnded: Bool) -> Bool {
        defer { previousBytes = bytes; previousPosition = position }
        guard ready, selectedVideo, !picture, playing, !seeking, decoderStarted else {
            began = nil; lastActivity = nil
            return false
        }
        // A connection that resumes after a stall needs its own decoding window;
        // wall time spent waiting for input is not evidence of decoder failure.
        if !inputEnded, let lastActivity, now - lastActivity > 5 { began = nil }
        if began == nil { began = now; lastActivity = now }
        if bytes > previousBytes || position > previousPosition + 0.001 { lastActivity = now }
        guard let began, now - began >= 20 else { return false }
        return inputEnded || lastActivity.map { now - $0 <= 5 } == true
    }
}
