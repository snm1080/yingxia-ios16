import Foundation
import CoreGraphics

/// Concrete preview geometry keeps a short control-row proposal from squeezing
/// an image. The origin is measured in the progress track's own coordinates.
public enum PlaybackThumbnailLayout {
    public static func size(imageWidth: Int, imageHeight: Int, availableWidth: CGFloat,
                            maximumWidth: CGFloat = 196, maximumHeight: CGFloat = 132) -> CGSize {
        guard availableWidth.isFinite, availableWidth > 0, maximumWidth.isFinite, maximumWidth > 0,
              maximumHeight.isFinite, maximumHeight > 0 else { return .zero }
        let aspect = imageWidth > 0 && imageHeight > 0 ? CGFloat(imageWidth) / CGFloat(imageHeight) : 16 / 9
        let width = min(availableWidth, maximumWidth, maximumHeight * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    public static func origin(trackWidth: CGFloat, imageWidth: CGFloat, progress: Double) -> CGFloat {
        guard trackWidth.isFinite, imageWidth.isFinite, progress.isFinite, trackWidth > 0, imageWidth > 0 else { return 0 }
        let x = trackWidth * CGFloat(min(1, max(0, progress)))
        return min(max(0, x - imageWidth / 2), max(0, trackWidth - imageWidth))
    }
}
