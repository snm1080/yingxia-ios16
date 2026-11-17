import Foundation
import CoreGraphics

/// Measured subtitle boxes shared by the inline player and the system PiP compositor.
public enum SubtitlePairGeometry {
    public static let secondaryScale: CGFloat = 0.88

    public struct Rectangles {
        public let primary: CGRect
        public let secondary: CGRect
    }

    public static func rectangles(primarySize: CGSize, secondarySize: CGSize, normalLineHeight: CGFloat,
                                  style: SubtitleStyle, picture: CGRect, viewportHeight: CGFloat,
                                  bottomInset: CGFloat, padding: CGFloat = 6, gap: CGFloat = 2) -> Rectangles {
        let primaryHeight = max(0, primarySize.height), secondaryHeight = max(0, secondarySize.height)
        let centerX = picture.minX + picture.width * style.x
        let normal = CGFloat(SubtitleStyle.safeVerticalOrigin(position: style.y, textHeight: primaryHeight,
            pictureTop: picture.minY, pictureHeight: picture.height, viewportHeight: viewportHeight,
            bottomInset: bottomInset, padding: padding))
        let secondaryNormal = CGFloat(SubtitleStyle.safeVerticalOrigin(position: style.y, textHeight: secondaryHeight,
            pictureTop: picture.minY, pictureHeight: picture.height, viewportHeight: viewportHeight,
            bottomInset: bottomInset, padding: padding))
        guard primaryHeight > 0, secondaryHeight > 0 else {
            return Rectangles(primary: CGRect(x: centerX - primarySize.width / 2, y: normal, width: primarySize.width, height: primaryHeight),
                secondary: CGRect(x: centerX - secondarySize.width / 2, y: secondaryNormal, width: secondarySize.width, height: secondaryHeight))
        }
        let separation = max(0, gap)
        let groupHeight = primaryHeight + separation + secondaryHeight
        let safeBottom = min(picture.maxY, viewportHeight - max(0, bottomInset) - max(0, padding))
        // A half-line rise is exact wherever both measured boxes fit. Near the bottom, move
        // the whole group farther up to protect the secondary and preserve its separation.
        let requested = normal - max(0, normalLineHeight) * 0.5
        let origin = max(picture.minY, min(requested, safeBottom - groupHeight))
        return Rectangles(primary: CGRect(x: centerX - primarySize.width / 2, y: origin, width: primarySize.width, height: primaryHeight),
            secondary: CGRect(x: centerX - secondarySize.width / 2, y: origin + primaryHeight + separation, width: secondarySize.width, height: secondaryHeight))
    }
}

public enum SubtitleBitmapGeometry {
    public static func rectangle(origin: CGPoint, imageSize: CGSize, canvasSize: CGSize, picture: CGRect) -> CGRect? {
        guard canvasSize.width > 0, canvasSize.height > 0, imageSize.width > 0, imageSize.height > 0,
              [origin.x, origin.y, imageSize.width, imageSize.height, canvasSize.width, canvasSize.height,
               picture.minX, picture.minY, picture.width, picture.height].allSatisfy(\.isFinite) else { return nil }
        return CGRect(x: picture.minX + origin.x * picture.width / canvasSize.width,
            y: picture.minY + origin.y * picture.height / canvasSize.height,
            width: imageSize.width * picture.width / canvasSize.width, height: imageSize.height * picture.height / canvasSize.height)
    }

    /// Bitmap coordinates are authored. Only centered cues in the conventional bottom band
    /// participate in dual-dialogue layout; signs elsewhere retain their original rectangle.
    public static func isBottomDialogue(_ rectangle: CGRect, in picture: CGRect) -> Bool {
        rectangle.minY >= picture.minY + picture.height * 0.65 &&
            abs(rectangle.midX - picture.midX) <= picture.width * 0.2 && rectangle.height <= picture.height * 0.3
    }
}
