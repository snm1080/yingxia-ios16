import Foundation
import CoreGraphics
import SwiftUI

/// Shared with the native hit surface: spacing belongs to one adjacent action,
/// while only the painted capsule participates in hit testing.
enum MusicMiniPlayerLayout {
    enum Action: CaseIterable { case open, transport, next, stop }
    struct Region {
        let action: Action
        let frame: CGRect
    }

    static let buttonWidth: CGFloat = 44
    static func spacing(inline: Bool) -> CGFloat { inline ? 0 : 2 }
    static func trailing(inline: Bool) -> CGFloat { inline ? 4 : 8 }

    static func regions(size: CGSize, inline: Bool, rightToLeft: Bool = false) -> [Region] {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return [] }
        let actions: [Action] = inline ? [.transport] : [.transport, .next, .stop]
        let gap = spacing(inline: inline)
        let tail = trailing(inline: inline)
        let ideal = CGFloat(actions.count) * buttonWidth + CGFloat(actions.count - 1) * gap + tail
        let scale = min(1, size.width / ideal)
        let width = buttonWidth * scale, spacing = gap * scale
        var x = max(0, size.width - ideal)
        var result = [Region(action: .open, frame: CGRect(x: 0, y: 0, width: x, height: size.height))]
        for (index, action) in actions.enumerated() {
            let end = index == actions.count - 1 ? size.width : x + width + spacing
            result.append(Region(action: action, frame: CGRect(x: x, y: 0, width: end - x, height: size.height)))
            x = end
        }
        if rightToLeft {
            result = result.map { Region(action: $0.action,
                frame: CGRect(x: size.width - $0.frame.maxX, y: 0, width: $0.frame.width, height: size.height)) }
        }
        return result
    }

    static func contains(_ point: CGPoint, size: CGSize) -> Bool {
        guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height else { return false }
        // The visible glass and progress use SwiftUI's continuous capsule. A
        // circle equation differs at its shoulder and leaves small painted gaps.
        return Capsule().path(in: CGRect(origin: .zero, size: size)).contains(point)
    }

    static func action(at point: CGPoint, size: CGSize, inline: Bool, rightToLeft: Bool = false) -> Action? {
        guard contains(point, size: size) else { return nil }
        return regions(size: size, inline: inline, rightToLeft: rightToLeft).first { $0.frame.contains(point) }?.action
    }

    static func progress(position: Double, duration: Double?) -> Double {
        guard position.isFinite, let duration, duration.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }
}
