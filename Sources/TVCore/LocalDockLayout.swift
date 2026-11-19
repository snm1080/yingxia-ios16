import Foundation

/// Layout values shared by the dock and accessories whose container may extend
/// beyond the dock's safe area (HTML) or start inside a navigation stack (actors).
public enum LocalDockLayout {
    public static let horizontalPadding: CGFloat = 12
    public static let topPadding: CGFloat = 8
    public static let bottomPadding: CGFloat = 6
    public static let musicHeight: CGFloat = 56
    public static let musicSpacing: CGFloat = 8
    public static let controlHeight: CGFloat = 60
    public static let groupPadding: CGFloat = 5
    public static var dockHeight: CGFloat { controlHeight + 2 * groupPadding }

    public struct Metrics: Equatable, Sendable {
        public let buttonWidth: CGFloat
        public let buttonSpacing: CGFloat
        public let groupSpacing: CGFloat
        /// Inset from each end of the capsule to the nearest button. It is the
        /// group padding until the capsule spreads; then it grows to half the
        /// gap, so the buttons rest on even centres across the whole capsule.
        public let capsulePadding: CGFloat
        /// Width of the selected button's highlight capsule. The highlight is
        /// as tall as the button (controlHeight) with fully round ends; at the
        /// natural button width (<= 56) against that 60pt height it read as a
        /// circle, so the capsule reaches into the gap toward the neighbours
        /// and stays a few points short of the next button's centre pitch.
        public let selectionWidth: CGFloat
    }

    private static func selectionWidth(buttonWidth: CGFloat, buttonSpacing: CGFloat) -> CGFloat {
        let pitch = buttonWidth + buttonSpacing
        return max(buttonWidth, min(pitch - 6, buttonWidth + buttonSpacing * 0.65))
    }

    /// The centre-to-centre pitch the capsule aims for once it may spread
    /// (MiraPlay's bar, measured: a 510pt capsule on a 768pt iPad — two thirds
    /// of the screen — with its buttons on even centres, ≈102pt apart at the
    /// five buttons this app usually shows).
    public static let spreadPitch: CGFloat = 102
    /// The widest share of the screen the capsule may take while spreading.
    public static let spreadWidthFraction: CGFloat = 0.66

    public static func metrics(availableWidth: CGFloat, buttonCount: Int) -> Metrics {
        let compact = availableWidth < 336
        let buttonSpacing: CGFloat = compact ? 6 : 12
        let groupSpacing: CGFloat = compact ? 8 : 12
        // One capsule holds every button now; its width follows the visible count.
        // The width floor sits below the 44pt touch ideal so a full row of buttons
        // with the wider gaps still fits a narrow phone instead of spilling the
        // capsule past the padded width (and its touch frame off the screen edge).
        let count = max(1, buttonCount)
        let width = (availableWidth - 2 * groupPadding - buttonSpacing * CGFloat(count - 1)) / CGFloat(count)
        let buttonWidth = max(36, min(56, width))
        let natural = Metrics(buttonWidth: buttonWidth, buttonSpacing: buttonSpacing,
                              groupSpacing: groupSpacing, capsulePadding: groupPadding,
                              selectionWidth: selectionWidth(buttonWidth: buttonWidth, buttonSpacing: buttonSpacing))
        guard !compact, count > 1 else { return natural }
        // Spread the buttons evenly across a wider capsule, MiraPlay-style: the
        // capsule grows with the button count toward the pitch above, capped at
        // two thirds of the screen width, and never past the padded width. Where
        // the natural capsule already reaches the target (narrow screens, full
        // rows), the layout above stands unchanged, so nothing can overflow.
        let screenWidth = availableWidth + 2 * horizontalPadding
        let naturalCapsule = naturalWidth(buttonWidth: buttonWidth, spacing: buttonSpacing, count: count)
        let target = min(availableWidth, max(naturalCapsule,
                                             min(CGFloat(count) * spreadPitch, spreadWidthFraction * screenWidth)))
        guard target > naturalCapsule + 0.5 else { return natural }
        let pitch = target / CGFloat(count)
        let spacing = pitch - buttonWidth
        return Metrics(buttonWidth: buttonWidth, buttonSpacing: spacing,
                       groupSpacing: groupSpacing, capsulePadding: spacing / 2,
                       selectionWidth: selectionWidth(buttonWidth: buttonWidth, buttonSpacing: spacing))
    }

    private static func naturalWidth(buttonWidth: CGFloat, spacing: CGFloat, count: Int) -> CGFloat {
        CGFloat(count) * buttonWidth + CGFloat(count - 1) * spacing + 2 * groupPadding
    }

    public static func inset(showsMusic: Bool) -> CGFloat {
        topPadding + dockHeight + bottomPadding + (showsMusic ? musicHeight + musicSpacing : 0)
    }

    /// The dock has fixed control sizes; its touch regions can be resolved in the
    /// same layout pass. Feeding measured anchors back through @State leaves the
    /// first music-strip frame empty, and can animate old hit frames after scrolling.
    public static func touchFrames(containerWidth: CGFloat, showsMusic: Bool, buttonCount: Int) -> [CGRect] {
        let availableWidth = max(0, containerWidth - 2 * horizontalPadding)
        let metrics = metrics(availableWidth: availableWidth, buttonCount: buttonCount)
        let count = max(1, buttonCount)
        // The whole capsule is one hit region: gaps and padding inside it absorb
        // touches instead of passing them through to the content underneath.
        let capsuleWidth = CGFloat(count) * metrics.buttonWidth + CGFloat(count - 1) * metrics.buttonSpacing + 2 * metrics.capsulePadding
        let left = horizontalPadding + max(0, (availableWidth - capsuleWidth) / 2)
        let top = topPadding + (showsMusic ? musicHeight + musicSpacing : 0)
        var frames: [CGRect] = []
        if showsMusic {
            frames.append(CGRect(x: horizontalPadding, y: topPadding, width: availableWidth, height: musicHeight))
        }
        frames.append(CGRect(x: left, y: top, width: capsuleWidth, height: dockHeight))
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
