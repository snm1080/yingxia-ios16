#if os(iOS)
import UIKit
import QuartzCore

/// Settle the native renderer's constrained display views in the same layout
/// pass as the viewport, including a surface returning from Picture in Picture.
@MainActor enum PlayerSurfaceLayout {
    static func apply(frame: CGRect, to picture: UIView) {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return }
        let bounds = CGRect(origin: .zero, size: frame.size)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            // UIKit's frame setter is undefined while a view has a transform.
            // The renderer owns that transform; update its local geometry only.
            if picture.bounds != bounds { picture.bounds = bounds }
            if picture.center != center { picture.center = center }
            // MetalPlayView pins its Metal/display-layer children with AutoLayout.
            // A resized parent alone leaves those children at the previous size.
            picture.layoutIfNeeded()
        }
    }
}
#endif
