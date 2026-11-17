/// The first known picture chooses the full-screen orientation; an explicit rotation belongs to the viewer
/// until another episode opens. A quality switch may replace the AVPlayerItem, but is still the same media.
public struct PlaybackOrientationPolicy: Sendable {
    public enum Direction: Equatable, Sendable { case portrait, landscape }
    private var mediaID: String?
    /// Shared playback keeps this when its full-screen view is dismissed into Picture in Picture.
    public private(set) var currentDirection: Direction?
    public init() {}
    public mutating func begin(mediaID: String) {
        guard self.mediaID != mediaID else { return }
        self.mediaID = mediaID
        currentDirection = nil
    }
    public mutating func picture(width: Double, height: Double) -> Direction? {
        guard currentDirection == nil, width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let direction: Direction = width > height ? .landscape : .portrait
        currentDirection = direction
        return direction
    }
    public mutating func rotate(currentlyLandscape: Bool) -> Direction {
        // A second tap can arrive while UIKit still reports the pre-rotation
        // orientation. Toggle our chosen direction rather than that stale value.
        let wasLandscape = currentDirection.map { $0 == .landscape } ?? currentlyLandscape
        let direction: Direction = wasLandscape ? .portrait : .landscape
        currentDirection = direction
        return direction
    }
}
