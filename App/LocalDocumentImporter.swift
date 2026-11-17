#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import TVCore

extension View {
    /// The presenting controller belongs to this view's window, including a nested settings modal.
    /// Files owns its dismissal; the retained session delivers exactly one outcome after it finishes.
    func localDocumentImporter(isPresented: Binding<Bool>, kind: LocalDocumentSelectionKind,
                               completion: @escaping (Result<LocalDocumentSelection, Error>) -> Void,
                               cancelled: @escaping () -> Void = {}) -> some View {
        background {
            LocalDocumentImporter(isPresented: isPresented, kind: kind, completion: completion, cancelled: cancelled)
                .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private struct LocalDocumentImporter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let kind: LocalDocumentSelectionKind
    let completion: (Result<LocalDocumentSelection, Error>) -> Void
    let cancelled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> AnchorController {
        let controller = AnchorController()
        controller.lifecycle = { [weak coordinator = context.coordinator] in coordinator?.presentWhenReady() }
        context.coordinator.anchor = controller
        return controller
    }
    func updateUIViewController(_ controller: AnchorController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.requestPresentation()
    }
    static func dismantleUIViewController(_ controller: AnchorController, coordinator: Coordinator) {
        controller.lifecycle = nil
        coordinator.invalidate()
    }

    @MainActor final class AnchorController: UIViewController {
        var lifecycle: (() -> Void)?
        override func loadView() {
            let anchor = AnchorView()
            anchor.backgroundColor = .clear; anchor.isUserInteractionEnabled = false
            anchor.lifecycle = { [weak self] in self?.lifecycle?() }
            view = anchor
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); lifecycle?() }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); lifecycle?() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); lifecycle?() }
    }
    @MainActor final class AnchorView: UIView {
        var lifecycle: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); lifecycle?() }
    }

    @MainActor final class Coordinator {
        var parent: LocalDocumentImporter
        weak var anchor: AnchorController?
        private var session: PickerSession?
        private var waitingForTransition = false
        private var scheduled = false
        private var invalidated = false
        init(_ parent: LocalDocumentImporter) { self.parent = parent }

        func requestPresentation() {
            // Defer state updates out of SwiftUI's representable update, without a timed retry.
            guard !scheduled, !invalidated else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                if !self.parent.isPresented { self.session?.cancel(); return }
                self.presentWhenReady()
            }
        }
        func presentWhenReady() {
            guard !invalidated, parent.isPresented, session == nil, !waitingForTransition,
                  let anchor, let window = anchor.viewIfLoaded?.window else { return }
            var presenter: UIViewController = anchor
            while let owner = presenter.parent { presenter = owner }
            // iOS 16 Form rows may use UIHostingConfiguration without controller containment.
            // Their UIView is still in a window: locate its actual presented settings owner there.
            if presenter === anchor {
                guard let root = window.rootViewController else {
                    failPresentation("当前页面尚未就绪，请重新选择文件")
                    return
                }
                presenter = root
            }
            while let presented = presenter.presentedViewController,
                  let presentedView = presented.viewIfLoaded,
                  anchor.view.isDescendant(of: presentedView) {
                presenter = presented
            }

            // A Menu action or the previous picker can still be ending its presentation.
            // Continue from its actual transition completion, never a guessed time interval.
            let transition = presenter.presentedViewController?.transitionCoordinator ?? presenter.transitionCoordinator
            if let transition {
                waitingForTransition = true
                let accepted = transition.animate(alongsideTransition: nil) { [weak self] _ in
                    guard let self else { return }
                    self.waitingForTransition = false
                    self.requestPresentation()
                }
                if accepted { return }
                waitingForTransition = false
            }
            guard presenter.presentedViewController == nil, !presenter.isBeingDismissed,
                  presenter.viewIfLoaded?.window === window else {
                failPresentation("当前面板尚未关闭，请关闭它后重新选择文件")
                return
            }
            let request = parent
            let active = PickerSession(kind: request.kind) { [weak self] active, outcome in
                self?.finish(active, outcome: outcome, request: request)
            }
            session = active
            Diagnostics.shared.record(.info, "imports", "picker present kind=\(parent.kind.rawValue) copy=\(parent.kind.importsCopy)")
            presenter.present(active.controller, animated: true) { [weak self, active] in
                // Keep the session through this transition even if SwiftUI removes its owner.
                // An invalidated session closes Files now that UIKit can accept a dismissal.
                active.presentationFinished()
                guard let self, self.session === active else { return }
                active.controller.presentationController?.delegate = active
                if !self.parent.isPresented { active.cancel() }
            }
        }
        private func failPresentation(_ message: String) {
            // Lifecycle callbacks can run during a layout pass. Publish the error after that pass.
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.invalidated else { return }
                self.scheduled = false
                guard self.parent.isPresented, self.session == nil else { return }
                self.parent.isPresented = false
                let error = NSError(domain: "LocalDocumentImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                Diagnostics.shared.record(.warning, "imports", "picker presentation unavailable kind=\(self.parent.kind.rawValue)")
                self.parent.completion(.failure(error))
            }
        }
        private func finish(_ active: PickerSession, outcome: PickerSession.Outcome, request: LocalDocumentImporter) {
            guard !invalidated, session === active else {
                if case .selected(.success(let selection)) = outcome { selection.release() }
                return
            }
            session = nil
            request.isPresented = false
            switch outcome {
            case .selected(let result): request.completion(result)
            case .cancelled: request.cancelled()
            }
        }
        func invalidate() {
            invalidated = true
            session?.invalidate(); session = nil
        }
    }
}

/// A system picker may disappear before didPickDocumentsAt, and may self-dismiss before its
/// delegate runs. Keep the delegate alive and accept either event order without a second modal.
@MainActor private final class PickerSession: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    enum Outcome { case selected(Result<LocalDocumentSelection, Error>), cancelled }
    let controller: PickerController
    private let kind: LocalDocumentSelectionKind
    private var presented = false
    private var invalidated = false
    private var completionGate = LocalDocumentCompletionGate()
    private var deliveryGate = LocalDocumentImportGate()
    private var outcome: Outcome?
    private var deliver: ((PickerSession, Outcome) -> Void)?

    init(kind: LocalDocumentSelectionKind, deliver: @escaping (PickerSession, Outcome) -> Void) {
        self.kind = kind
        self.deliver = deliver
        controller = PickerController(forOpeningContentTypes: [.item], asCopy: kind.importsCopy)
        super.init()
        controller.allowsMultipleSelection = kind.allowsMultipleSelection
        controller.shouldShowFileExtensions = true
        // Keep the playback/settings owner in the appearance hierarchy while Files is above it.
        controller.modalPresentationStyle = .overFullScreen
        // Only Files' Cancel delegate ends a request without URLs. This also prevents a swipe
        // dismissal from being ambiguous with Files dismissing before its selection callback.
        controller.isModalInPresentation = true
        controller.delegate = self
        controller.didDismiss = { [weak self] in self?.dismissed() }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard completionGate.accept() else { return }
        Diagnostics.shared.record(.info, "imports", "picker selected kind=\(kind.rawValue) count=\(urls.count)")
        let result = Result { try LocalDocumentSelection(urls: urls, kind: kind, ownsImportedCopy: kind.importsCopy) }
        complete(.selected(result))
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancel() }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        // A native dismissal can precede didPickDocumentsAt. It is not a cancellation result.
        dismissed()
    }
    func cancel() {
        guard completionGate.accept() else { return }
        Diagnostics.shared.record(.info, "imports", "picker cancelled kind=\(kind.rawValue)")
        complete(.cancelled)
    }
    func presentationFinished() {
        presented = true
        if invalidated || outcome != nil { dismissWhenReady() }
    }
    private func complete(_ next: Outcome) {
        guard deliver != nil else {
            if case .selected(.success(let selection)) = next { selection.release() }
            return
        }
        outcome = next
        if deliveryGate.selectionReceived() { deliverOutcome(); return }
        dismissWhenReady()
    }
    private func dismissWhenReady() {
        // A media change can cancel during the presentation animation; its completion calls us
        // again once UIKit can accept the dismissal, instead of overlapping two transitions.
        guard presented else { return }
        if controller.isBeingDismissed {
            controller.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in self?.dismissed() }
        } else if controller.presentingViewController != nil {
            controller.dismiss(animated: !invalidated) { [weak self] in self?.dismissed() }
        } else {
            dismissed()
        }
    }
    private func dismissed() {
        if deliveryGate.pickerDismissed() { deliverOutcome() }
    }
    private func deliverOutcome() {
        guard let outcome, let deliver else { return }
        self.outcome = nil; self.deliver = nil
        controller.didDismiss = nil
        deliver(self, outcome)
    }
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        deliver = nil
        if case .selected(.success(let selection)) = outcome { selection.release() }
        outcome = nil
        controller.didDismiss = nil; controller.delegate = nil
        dismissWhenReady()
    }
}

@MainActor private final class PickerController: UIDocumentPickerViewController {
    var didDismiss: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Authentication or another child panel covering Files is not a completed dismissal.
        if isBeingDismissed || presentingViewController == nil { didDismiss?() }
    }
}
#endif
