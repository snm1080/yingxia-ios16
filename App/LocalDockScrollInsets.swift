import SwiftUI

#if os(iOS)
import UIKit
import WebKit

private struct LocalDockScrollInsets: ViewModifier {
    @Environment(\.usesLocalDock) private var usesDock
    @Environment(\.isLocalPageActive) private var active
    @Environment(\.localDockInset) private var inset
    @Environment(\.localDockScrollEnabled) private var scrollEnabled
    @Environment(\.localDockActivity) private var activity
    func body(content: Content) -> some View {
        content.background {
            LocalDockInsetObserver(inset: usesDock ? inset : 0, enabled: usesDock && active)
                .allowsHitTesting(false)
            LocalDockScrollObserver(enabled: usesDock && active && scrollEnabled) { id, scrolling in activity?(id, scrolling) }
                .allowsHitTesting(false)
        }
    }
}

/// Insets the scrollable content, never the viewport. Scope is the current page's
/// hosting controller, so retained tabs, pushed pages and modal lists cannot leak insets.
private struct LocalDockInsetObserver: UIViewRepresentable {
    let inset: CGFloat
    let enabled: Bool
    func makeUIView(context: Context) -> ObserverView { ObserverView() }
    func updateUIView(_ view: ObserverView, context: Context) { view.configure(inset: inset, enabled: enabled) }
    static func dismantleUIView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: UIView {
        private var inset: CGFloat = 0
        private var enabled = false
        private var records: [ObjectIdentifier: InsetRecord] = [:]
        private var pending: DispatchWorkItem?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(inset: CGFloat, enabled: Bool) {
            self.inset = max(0, inset)
            self.enabled = enabled
            schedule()
        }
        override func didMoveToSuperview() { super.didMoveToSuperview(); schedule() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { suspend() } else { schedule() }
        }
        override func layoutSubviews() { super.layoutSubviews(); schedule() }

        private func schedule(after delay: TimeInterval = 0) {
            guard pending == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.reconcile()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func reconcile() {
            guard enabled, inset > 0, window != nil else { suspend(); return }
            var responder: UIResponder? = self
            while let next = responder, !(next is UIViewController) { responder = next.next }
            guard let controller = responder as? UIViewController, controller.view.window != nil else { return }
            var candidates: [UIScrollView] = []
            func collect(_ view: UIView) {
                guard !view.isHidden, !(view is WKWebView), !(view is UITextView) else { return }
                if let scroll = view as? UIScrollView,
                   scroll.bounds.width > 0, scroll.bounds.height > 0,
                   !scroll.alwaysBounceHorizontal,
                   scroll.alwaysBounceVertical || scroll.contentSize.width <= scroll.bounds.width + 1 {
                    candidates.append(scroll)
                    return // Nested carousels keep their own insets.
                }
                // Never walk into a child controller (navigation, presentation or another page).
                for child in view.subviews {
                    if let owner = child.next as? UIViewController, owner !== controller { continue }
                    collect(child)
                }
            }
            collect(controller.view)
            let current = Set(candidates.map(ObjectIdentifier.init))
            for id in records.keys.filter({ !current.contains($0) }) { records.removeValue(forKey: id)?.restoreWhenIdle() }
            var deferred = false
            for scroll in candidates {
                let id = ObjectIdentifier(scroll)
                let record: InsetRecord
                if let existing = records[id] { record = existing }
                else {
                    record = InsetRecord(scroll)
                    records[id] = record
                }
                if record.observation == nil {
                    record.observation = scroll.observe(\.contentInset, options: [.new]) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.schedule() }
                    }
                }
                if !record.apply(inset) { deferred = true }
            }
            // Only an actual pending change polls, and only until UIKit finishes the gesture.
            if deferred { schedule(after: 0.08) }
        }

        private func suspend() {
            pending?.cancel(); pending = nil
            // Retain ownership if the same page is reactivated before inertia settles.
            for record in records.values { record.restoreWhenIdle() }
        }

        func detach() {
            pending?.cancel(); pending = nil
            let values = Array(records.values)
            records.removeAll()
            for record in values { record.restoreWhenIdle() }
        }

        @MainActor final class InsetRecord {
            private weak var scroll: UIScrollView?
            private var base: CGFloat
            private var indicatorBase: CGFloat
            private var applied: CGFloat
            private var indicatorApplied: CGFloat
            var observation: NSKeyValueObservation?
            private var pendingRemoval: DispatchWorkItem?
            init(_ scroll: UIScrollView) {
                self.scroll = scroll
                base = scroll.contentInset.bottom
                indicatorBase = scroll.verticalScrollIndicatorInsets.bottom
                applied = base
                indicatorApplied = indicatorBase
            }
            @discardableResult func apply(_ extra: CGFloat) -> Bool {
                pendingRemoval?.cancel(); pendingRemoval = nil
                guard let scroll else { return true }
                synchronize(scroll)
                let next = base + extra, indicatorNext = indicatorBase + extra
                guard abs(scroll.contentInset.bottom - next) > 0.5
                        || abs(scroll.verticalScrollIndicatorInsets.bottom - indicatorNext) > 0.5 else { return true }
                guard !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else { return false }
                applied = next
                indicatorApplied = indicatorNext
                var content = scroll.contentInset
                content.bottom = next
                scroll.contentInset = content
                var indicator = scroll.verticalScrollIndicatorInsets
                indicator.bottom = indicatorNext
                scroll.verticalScrollIndicatorInsets = indicator
                return true
            }
            func restore() {
                pendingRemoval?.cancel(); pendingRemoval = nil
                observation = nil
                guard let scroll else { return }
                synchronize(scroll)
                // A retained, hidden page can receive repeated layout callbacks.
                // Assigning an unchanged inset still asks UIKit to lay out again.
                if abs(scroll.contentInset.bottom - base) > 0.5 {
                    var content = scroll.contentInset
                    content.bottom = base
                    scroll.contentInset = content
                }
                if abs(scroll.verticalScrollIndicatorInsets.bottom - indicatorBase) > 0.5 {
                    var indicator = scroll.verticalScrollIndicatorInsets
                    indicator.bottom = indicatorBase
                    scroll.verticalScrollIndicatorInsets = indicator
                }
                applied = base; indicatorApplied = indicatorBase
            }
            func restoreWhenIdle() {
                observation = nil
                guard let scroll, scroll.window != nil,
                      scroll.isTracking || scroll.isDragging || scroll.isDecelerating else { restore(); return }
                pendingRemoval?.cancel()
                let work = DispatchWorkItem { [self] in
                    pendingRemoval = nil
                    restoreWhenIdle()
                }
                pendingRemoval = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            }
            private func synchronize(_ scroll: UIScrollView) {
                // contentInset is raw; UIKit adds safe areas in adjustedContentInset.
                // Preserve raw changes made while our contribution is present. A reset
                // below that contribution replaces the baseline instead.
                let current = scroll.contentInset.bottom
                if abs(current - applied) > 0.5 {
                    let contribution = applied - base
                    base = current < contribution ? current : current - contribution
                    applied = current
                }
                let indicator = scroll.verticalScrollIndicatorInsets.bottom
                if abs(indicator - indicatorApplied) > 0.5 {
                    let contribution = indicatorApplied - indicatorBase
                    indicatorBase = indicator < contribution ? indicator : indicator - contribution
                    indicatorApplied = indicator
                }
            }
        }
    }
}
#endif

extension View {
    @ViewBuilder func localDockScrollInsets() -> some View {
        #if os(iOS)
        modifier(LocalDockScrollInsets())
        #else
        self
        #endif
    }
}
