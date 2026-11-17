#if os(iOS)
import SwiftUI
import UIKit

/// Only the progress track owns these gestures. A vertical pan fails before
/// recognition so an enclosing scroll view can keep the touch sequence.
struct PlayerSeekGestures: UIViewRepresentable {
    struct Value {
        let startLocation: CGPoint
        let location: CGPoint
    }
    let changed: (Value) -> Void
    /// Nil means the touch was cancelled; a draft must then be discarded.
    let ended: (Value?) -> Void
    let tapped: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.require(toFail: pan)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        context.coordinator.parent = self
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.cancel()
        coordinator.parent = nil
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerSeekGestures?
        private var start: CGPoint?

        @objc func panned(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view else { return }
            let location = pan.location(in: view)
            switch pan.state {
            case .began:
                let translation = pan.translation(in: view)
                start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
                if let start { parent?.changed(Value(startLocation: start, location: location)) }
            case .changed:
                if let start { parent?.changed(Value(startLocation: start, location: location)) }
            case .ended:
                guard let start else { return }
                self.start = nil
                parent?.ended(Value(startLocation: start, location: location))
            case .cancelled, .failed: cancel()
            default: break
            }
        }
        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard tap.state == .ended, let view = tap.view else { return }
            parent?.tapped(tap.location(in: view))
        }
        func cancel() {
            guard start != nil else { return }
            start = nil
            parent?.ended(nil)
        }
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
            let translation = pan.translation(in: view)
            return translation.x.isFinite && translation.y.isFinite && abs(translation.x) > abs(translation.y) * 1.2
        }
    }
}
#endif
