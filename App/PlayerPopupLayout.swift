import Foundation

/// The panel fits the current picture viewport, including an on-screen keyboard.
/// A minimum panel height must never become a minimum height for the viewport.
enum PlayerPopupLayout {
    static func size(viewport: CGSize, keyboardOverlap: CGFloat, preferred: CGSize) -> CGSize {
        let width = viewport.width.isFinite ? max(0, viewport.width - 24) : 0
        let height = viewport.height.isFinite ? max(0, viewport.height) : 0
        let overlap = keyboardOverlap.isFinite ? min(height, max(0, keyboardOverlap)) : height
        return CGSize(width: min(max(0, preferred.width), width),
                      height: min(max(0, preferred.height), max(0, height - overlap - 24)))
    }
}
