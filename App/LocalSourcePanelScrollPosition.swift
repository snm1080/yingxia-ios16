#if os(iOS)
import SwiftUI
import UIKit

/// Saves the native viewport, including a partially visible row, on iOS 16 and later.
/// Initial layout and programmatic restoration never replace the saved user position.
struct LocalSourcePanelScrollPosition: UIViewRepresentable {
    let storageKey: String
    let enabled: Bool

    static func hasSavedPosition(for key: String) -> Bool {
        guard let saved = UserDefaults.standard.object(forKey: key + ".offset") as? NSNumber else { return false }
        return saved.doubleValue.isFinite
    }

    static func clearPosition(for key: String) {
        UserDefaults.standard.removeObject(forKey: key + ".offset")
    }

    func makeUIView(context: Context) -> ObserverView { ObserverView() }
    func updateUIView(_ view: ObserverView, context: Context) { view.configure(key: storageKey, enabled: enabled) }
    static func dismantleUIView(_ view: ObserverView, coordinator: ()) { view.save() }

    final class ObserverView: UIView {
        private weak var scrollView: UIScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var pendingSave: DispatchWorkItem?
        private var pendingRestore: DispatchWorkItem?
        private var key = ""
        private var enabled = false
        private var target: CGFloat?
        private var restoring = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(key: String, enabled: Bool) {
            if self.key != key || (!self.enabled && enabled) {
                pendingSave?.cancel()
                pendingRestore?.cancel(); pendingRestore = nil
                self.key = key
                let saved = UserDefaults.standard.object(forKey: key + ".offset") as? NSNumber
                target = saved.flatMap { $0.doubleValue.isFinite ? CGFloat(max(0, $0.doubleValue)) : nil }
            }
            self.enabled = enabled
            observeScrollView()
        }

        override func didMoveToSuperview() { super.didMoveToSuperview(); observeScrollView() }
        override func didMoveToWindow() { super.didMoveToWindow(); observeScrollView() }
        override func layoutSubviews() { super.layoutSubviews(); observeScrollView() }
        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil { save() }
            super.willMove(toWindow: newWindow)
        }

        private func observeScrollView() {
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            let enclosing = ancestor as? UIScrollView
            if enclosing !== scrollView {
                observations.removeAll()
                scrollView = enclosing
                if let enclosing {
                    observations = [
                        enclosing.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.offsetChanged() }
                        },
                        enclosing.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.restore() }
                        },
                        enclosing.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.restore() }
                        }
                    ]
                }
            }
            restore()
        }

        private func restore(allowClamping: Bool = false) {
            guard enabled, !restoring, let target, let scrollView, scrollView.window != nil else { return }
            // Tracking starts before dragging and need not produce an offset event. Once
            // the viewer touches the list, a delayed layout must never reclaim the viewport.
            if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                self.target = nil
                pendingRestore?.cancel(); pendingRestore = nil
                scheduleSave()
                return
            }
            guard scrollView.bounds.height > 0, scrollView.contentSize.height > 0 else { return }
            let top = scrollView.adjustedContentInset.top
            let maximum = max(0, scrollView.contentSize.height - scrollView.bounds.height + top + scrollView.adjustedContentInset.bottom)
            if target > maximum + 0.5, !allowClamping {
                // A lazy grid initially reports only part of its height. Wait for content;
                // a genuinely shorter replacement list clamps once its layout settles.
                pendingRestore?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.restore(allowClamping: true) }
                pendingRestore = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                return
            }
            pendingRestore?.cancel(); pendingRestore = nil
            let offset = min(target, maximum) - top
            // Restoration is one-shot. Later VoiceOver/keyboard/system offsets are normal scrolling.
            self.target = nil
            restoring = true
            if abs(scrollView.contentOffset.y - offset) > 0.5 {
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offset), animated: false)
            }
            restoring = false
            scheduleSave()
        }

        private func offsetChanged() {
            guard enabled, !restoring, let scrollView else { return }
            if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                target = nil
                pendingRestore?.cancel(); pendingRestore = nil
            }
            guard target == nil else { return }
            scheduleSave()
        }

        private func scheduleSave() {
            // KVO carries no SwiftUI state. Every scrolling method persists its final settled offset.
            pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.save() }
            pendingSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }

        func save() {
            pendingSave?.cancel(); pendingSave = nil
            guard enabled, !key.isEmpty, let scrollView else { return }
            // An unfinished initial layout keeps its target; completed restoration saves the actual viewport.
            let value = target ?? max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            guard value.isFinite else { return }
            UserDefaults.standard.set(Double(value), forKey: key + ".offset")
        }
    }
}
#endif
