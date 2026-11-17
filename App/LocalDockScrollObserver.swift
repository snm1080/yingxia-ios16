#if os(iOS)
import SwiftUI
import UIKit
import WebKit

/// Watches the scroll view already handling the touch. It never replaces its delegate
/// or consumes the gesture, and keeps observing during native inertial scrolling.
struct LocalDockScrollObserver: UIViewRepresentable {
    let enabled: Bool
    let activity: (UUID, Bool) -> Void
    func makeUIView(context: Context) -> ObserverView { ObserverView() }
    func updateUIView(_ view: ObserverView, context: Context) {
        view.activity = activity
        view.enabled = enabled
        view.attach()
    }
    static func dismantleUIView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: UIView {
        var enabled = true {
            didSet { if !enabled { detach() } }
        }
        var activity: ((UUID, Bool) -> Void)?
        private let observerID = UUID()
        private weak var observedView: UIView?
        private weak var scroll: UIScrollView?
        private var frameLink: CADisplayLink?
        private var previousOffset: CGFloat = 0
        private var quietFrames = 0
        private var active = false
        private struct ScrollTarget { weak var view: UIScrollView? }
        private var targets: [ObjectIdentifier: ScrollTarget] = [:]

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }
        override func didMoveToSuperview() { super.didMoveToSuperview(); attach() }
        override func layoutSubviews() { super.layoutSubviews(); attach() }
        func attach() {
            guard enabled, window != nil else { detach(); return }
            var responder: UIResponder? = self
            while let next = responder, !(next is UIViewController) { responder = next.next }
            guard let controller = responder as? UIViewController else { return }
            if controller.view !== observedView {
                detach()
                observedView = controller.view
            }
            var candidates: [UIScrollView] = []
            func collect(_ view: UIView) {
                guard !view.isHidden, !(view is WKWebView), !(view is UITextView) else { return }
                if let candidate = view as? UIScrollView,
                   candidate.bounds.width > 0, candidate.bounds.height > 0,
                   !candidate.alwaysBounceHorizontal,
                   candidate.alwaysBounceVertical || candidate.contentSize.width <= candidate.bounds.width + 1 {
                    candidates.append(candidate)
                    return // Nested horizontal history rows keep UIKit's own gesture arbitration.
                }
                for child in view.subviews {
                    if let owner = child.next as? UIViewController, owner !== controller { continue }
                    collect(child)
                }
            }
            collect(controller.view)
            let current = Set(candidates.map(ObjectIdentifier.init))
            for id in targets.keys.filter({ !current.contains($0) }) {
                if let previous = targets.removeValue(forKey: id)?.view {
                    previous.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
                    if scroll === previous { stop() }
                }
            }
            for candidate in candidates where targets[ObjectIdentifier(candidate)]?.view !== candidate {
                targets[ObjectIdentifier(candidate)] = ScrollTarget(view: candidate)
                candidate.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
            }
        }
        func detach() {
            stop()
            for target in targets.values { target.view?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:))) }
            targets.removeAll()
            observedView = nil; scroll = nil
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            guard enabled, let candidate = recognizer.view as? UIScrollView,
                  targets[ObjectIdentifier(candidate)] != nil else { return }
            if recognizer.state == .began || recognizer.state == .changed {
                let velocity = recognizer.velocity(in: window)
                guard scroll === candidate || abs(velocity.y) > abs(velocity.x) else { return }
                if scroll !== candidate { previousOffset = candidate.contentOffset.y }
                scroll = candidate
                setActive(true)
                quietFrames = 0
                if frameLink == nil {
                    let link = CADisplayLink(target: self, selector: #selector(tick))
                    link.preferredFramesPerSecond = 30
                    link.add(to: .main, forMode: .common)
                    frameLink = link
                }
            }
            if (recognizer.state == .cancelled || recognizer.state == .failed), scroll === candidate { stop() }
        }

        @objc private func tick() {
            guard enabled, let scroll, scroll.window != nil else { stop(); return }
            let moved = abs(scroll.contentOffset.y - previousOffset) > 0.25
            previousOffset = scroll.contentOffset.y
            if moved || scroll.isTracking || scroll.isDragging || scroll.isDecelerating {
                quietFrames = 0
                setActive(true)
            } else {
                quietFrames += 1
                // Let UIKit transition from ending the drag to deceleration before stopping.
                if quietFrames >= 2 { stop() }
            }
        }
        private func setActive(_ value: Bool) {
            guard active != value else { return }
            active = value
            // updateUIView/detach can run during SwiftUI layout. Publish only after it
            // finishes, and discard an end notification overtaken by another gesture.
            let callback = activity, id = observerID
            DispatchQueue.main.async { [weak self] in
                if let self {
                    guard self.active == value else { return }
                } else if value { return }
                // A dismantled observer still releases its active identity. It cannot
                // accidentally reveal the dock while a different page is scrolling.
                callback?(id, value)
            }
        }
        private func stop() {
            frameLink?.invalidate(); frameLink = nil; scroll = nil
            quietFrames = 0
            setActive(false)
        }
    }
}
#endif
