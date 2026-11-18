import Foundation

/// Layout values shared by the dock and accessories whose container may extend
/// beyond the dock's safe area (HTML) or start inside a navigation stack (actors).
public enum LocalDockLayout {
    public static let horizontalPadding: CGFloat = 12
    public static let topPadding: CGFloat = 8
    public static let bottomPadding: CGFloat = 6
    public static let musicHeight: CGFloat = 56
    public static let musicSpacing: CGFloat = 8
    public static let controlHeight: CGFloat = 52
    public static let groupPadding: CGFloat = 5
    public static var dockHeight: CGFloat { controlHeight + 2 * groupPadding }

    public struct Metrics: Equatable, Sendable {
        public let buttonWidth: CGFloat
        public let buttonSpacing: CGFloat
        public let groupSpacing: CGFloat
    }

    public static func metrics(availableWidth: CGFloat) -> Metrics {
        let compact = availableWidth < 336
        let buttonSpacing: CGFloat = compact ? 2 : 4
        let groupSpacing: CGFloat = compact ? 8 : 12
        let width = (availableWidth - 16 - buttonSpacing * 4 - groupSpacing) / 6
        return Metrics(buttonWidth: max(48, min(56, width)), buttonSpacing: buttonSpacing, groupSpacing: groupSpacing)
    }

    public static func inset(showsMusic: Bool) -> CGFloat {
        topPadding + dockHeight + bottomPadding + (showsMusic ? musicHeight + musicSpacing : 0)
    }

    /// The dock has fixed control sizes; its touch regions can be resolved in the
    /// same layout pass. Feeding measured anchors back through @State leaves the
    /// first music-strip frame empty, and can animate old hit frames after scrolling.
    public static func touchFrames(containerWidth: CGFloat, showsMusic: Bool) -> [CGRect] {
        let availableWidth = max(0, containerWidth - 2 * horizontalPadding)
        let metrics = metrics(availableWidth: availableWidth)
        let leftWidth = 4 * metrics.buttonWidth + 3 * metrics.buttonSpacing + 2 * groupPadding
        let rightWidth = 2 * metrics.buttonWidth + metrics.buttonSpacing + 2 * groupPadding
        let occupied = leftWidth + metrics.groupSpacing + rightWidth
        let left = horizontalPadding + max(0, (availableWidth - occupied) / 2)
        let top = topPadding + (showsMusic ? musicHeight + musicSpacing : 0)
        var frames: [CGRect] = []
        if showsMusic {
            frames.append(CGRect(x: horizontalPadding, y: topPadding, width: availableWidth, height: musicHeight))
        }
        frames.append(CGRect(x: left, y: top, width: leftWidth, height: dockHeight))
        frames.append(CGRect(x: left + leftWidth + metrics.groupSpacing, y: top, width: rightWidth, height: dockHeight))
        return frames
    }

    public static func accessoryBottom(containerBottom: CGFloat, safeAreaBottom: CGFloat,
                                       dockTop: CGFloat?, fallbackInset: CGFloat, gap: CGFloat = 12) -> CGFloat {
        if let dockTop, dockTop.isFinite, containerBottom.isFinite {
            return max(gap, containerBottom - dockTop + gap)
        }
        return max(0, safeAreaBottom) + max(0, fallbackInset) + gap
    }
}
